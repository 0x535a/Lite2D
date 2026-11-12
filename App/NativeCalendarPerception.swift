import Foundation
import EventKit

struct CompanionCalendarOccurrence: Equatable {
    var id: String
    var source: String
    var due: Date
    var allDay: Bool = false
    var end: Date?
    var completed = false
}

// A missing item proves only that it left this authorized query window, never cancellation.
struct CompanionCalendarSnapshot {
    private var previous: [String: [String: CompanionCalendarOccurrence]] = [:]
    mutating func reset() { previous = [:] }
    mutating func clear(_ source: String) { previous[source] = nil }
    var values: [CompanionCalendarOccurrence] { previous.values.flatMap { $0.values } }
    mutating func replace(_ values: [CompanionCalendarOccurrence], source: String, succeeded: Bool) -> [(CompanionCalendarOccurrence, String)] {
        guard succeeded else { return [] }
        let next = Dictionary(values.prefix(1024).map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let old = previous.updateValue(next, forKey: source)
        guard let old else { return [] }
        var changes: [(CompanionCalendarOccurrence, String)] = []
        for (id, value) in next.sorted(by: { $0.key < $1.key }) {
            guard let before = old[id] else { changes.append((value, "first_seen")); continue }
            if before != value { changes.append((value, !before.completed && value.completed ? "completed" : "updated")) }
        }
        for (id, value) in old.sorted(by: { $0.key < $1.key }) where next[id] == nil { changes.append((value, "no_longer_visible")) }
        return changes
    }
}

// Time boundaries describe the schedule, never proof that a real meeting or task happened.
struct CompanionCalendarTimeline {
    private(set) var occurrences: [CompanionCalendarOccurrence] = []
    private(set) var checkedAt: Date?
    private var emitted = Set<String>()
    mutating func reset() { occurrences = []; checkedAt = nil; emitted = [] }
    mutating func replace(_ values: [CompanionCalendarOccurrence], at now: Date) {
        occurrences = Array(values.filter { !$0.completed }.sorted { $0.due < $1.due }.prefix(1024))
        let current = Set(occurrences.flatMap { item in boundaries(item).map { key(item, phase: $0.1) } })
        emitted.formIntersection(current)
        // Initial enumeration does not replay old alarms. Future time boundaries are still scheduled.
        if checkedAt == nil { checkedAt = now }
    }
    func nextBoundary(after now: Date) -> Date? {
        occurrences.filter { !$0.allDay }.flatMap { boundaries($0).map(\.0) }.filter { $0 > now }.min()
    }
    mutating func advance(to now: Date) -> [(CompanionCalendarOccurrence, String)] {
        guard let previous = checkedAt else { checkedAt = now; return [] }
        checkedAt = now
        // Clock rollback and long sleep establish a new baseline rather than bursting old reminders.
        guard now > previous, now.timeIntervalSince(previous) <= 120 else { return [] }
        var result: [(CompanionCalendarOccurrence, String)] = []
        for occurrence in occurrences where !occurrence.allDay {
            for (boundary, phase) in boundaries(occurrence) {
                if boundary > previous && boundary <= now && emitted.insert(key(occurrence, phase: phase)).inserted { result.append((occurrence, phase)) }
            }
        }
        return result
    }
    private func key(_ item: CompanionCalendarOccurrence, phase: String) -> String {
        item.source + ":" + item.id + ":" + NativeCompanionData.iso(phase == "scheduled_end" ? item.end ?? item.due : item.due) + ":" + phase
    }
    private func boundaries(_ item: CompanionCalendarOccurrence) -> [(Date, String)] {
        var values = [(item.due.addingTimeInterval(-1800), "upcoming_30m"), (item.due.addingTimeInterval(-600), "upcoming_10m"), (item.due, "scheduled_time")]
        if let end = item.end, end >= item.due { values.append((end, "scheduled_end")) }
        return values
    }
}

struct CompanionCalendarSignal {
    var source: String
    var epoch: Int
    var health: String
    var occurrenceId: String?
    var phase: String?
    var due: Date?
}

@MainActor final class NativeCalendarPerception {
    private var eventStore: EKEventStore?
    private var enabled: [String: Int] = [:]
    private var generation = 0
    private var changeObserver: NSObjectProtocol?
    private var timer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var timeline = CompanionCalendarTimeline()
    private var snapshot = CompanionCalendarSnapshot()
    private var reminderFetch: Any?
    private var fetchWatchdog: Task<Void, Never>?
    private var fetchRevision = UUID()
    private var healthySources = Set<String>()
    private var lastRefresh = Date.distantPast
    private var permissionStates: [String: String] = [:]
    private var fetching = false
    private var refreshAgain = false
    private let sink: (CompanionCalendarSignal) -> Void
    init(sink: @escaping (CompanionCalendarSignal) -> Void) { self.sink = sink }
    static func permission(_ source: String) -> String {
        let status = EKEventStore.authorizationStatus(for: source == "macos.calendar" ? .event : .reminder)
        switch status {
        case .fullAccess: return "available"
        case .notDetermined: return "not_authorized"
        case .denied, .restricted, .writeOnly: return "permission_denied"
        default: return "permission_denied"
        }
    }
    func configure(epochs: [String: Int], sleeping: Bool) {
        let selected = epochs.filter { ["macos.calendar", "macos.reminders"].contains($0.key) }
        if enabled == selected && !sleeping && timer != nil { return }
        stop(); enabled = sleeping ? [:] : selected
        guard !enabled.isEmpty else { return }
        if eventStore == nil { eventStore = EKEventStore() }
        let expected = generation
        changeObserver = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: eventStore, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == expected else { return }
                self.refreshTask?.cancel()
                self.refreshTask = Task { @MainActor in
                    do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                    guard self.generation == expected else { return }; self.refresh()
                }
            }
        }
        refresh()
    }
    // Called only by an explicit Settings button, never by configure or a background callback.
    func requestAccess(source: String) async {
        guard enabled[source] != nil else { return }
        if eventStore == nil { eventStore = EKEventStore() }
        let expected = generation
        do {
            if source == "macos.calendar" { _ = try await eventStore?.requestFullAccessToEvents() }
            else if source == "macos.reminders" { _ = try await eventStore?.requestFullAccessToReminders() }
        } catch {
            if let epoch = enabled[source], expected == generation { sink(.init(source: source, epoch: epoch, health: "permission_denied")) }
        }
        if expected == generation { refresh() }
    }
    private func refresh() {
        guard !enabled.isEmpty, let eventStore else { return }
        if fetching { refreshAgain = true; return }
        fetching = true
        let now = Date(), expected = generation
        let fetchID = UUID(); fetchRevision = fetchID
        let from = now.addingTimeInterval(-86400), to = now.addingTimeInterval(7 * 86400)
        for (source, epoch) in enabled {
            let state = Self.permission(source); permissionStates[source] = state
            sink(.init(source: source, epoch: epoch, health: state))
            if state != "available" { snapshot.clear(source); healthySources.remove(source) }
        }
        if enabled["macos.calendar"] != nil, Self.permission("macos.calendar") == "available" {
            let predicate = eventStore.predicateForEvents(withStart: from, end: to, calendars: nil)
            // Do not access titles, notes, URLs, attendees or locations.
            let values: [CompanionCalendarOccurrence] = eventStore.events(matching: predicate).prefix(512).map {
                .init(id: NativeCompanionData.hash($0.calendarItemIdentifier + ":" + NativeCompanionData.iso($0.occurrenceDate ?? $0.startDate)), source: "macos.calendar", due: $0.startDate, allDay: $0.isAllDay, end: $0.endDate)
            }
            accept(values, source: "macos.calendar", succeeded: true)
        }
        if enabled["macos.reminders"] != nil, Self.permission("macos.reminders") == "available" {
            fetchWatchdog?.cancel()
            fetchWatchdog = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
                guard let self, self.generation == expected, self.fetchRevision == fetchID, self.fetching else { return }
                if let token = self.reminderFetch { eventStore.cancelFetchRequest(token) }; self.reminderFetch = nil
                self.accept([], source: "macos.reminders", succeeded: false); self.finish(at: Date())
            }
            let predicate = eventStore.predicateForIncompleteReminders(withDueDateStarting: from, ending: to, calendars: nil)
            reminderFetch = eventStore.fetchReminders(matching: predicate) { [weak self] reminders in
                let items = Self.reminderValues(reminders ?? [])
                Task { @MainActor in
                    guard let self, self.generation == expected, self.fetchRevision == fetchID else { return }
                    guard reminders != nil, Self.permission("macos.reminders") == "available" else {
                        self.accept([], source: "macos.reminders", succeeded: false); self.finish(at: now); return
                    }
                    let completed = eventStore.predicateForCompletedReminders(withCompletionDateStarting: from, ending: now, calendars: nil)
                    self.reminderFetch = eventStore.fetchReminders(matching: completed) { [weak self] reminders in
                        let completedItems = Self.reminderValues(reminders ?? [])
                        Task { @MainActor in
                            guard let self, self.generation == expected, self.fetchRevision == fetchID else { return }
                            self.reminderFetch = nil
                            self.accept(items + completedItems, source: "macos.reminders", succeeded: reminders != nil && Self.permission("macos.reminders") == "available")
                            self.finish(at: now)
                        }
                    }
                }
            }
        } else { finish(at: now) }
    }
    nonisolated private static func reminderValues(_ reminders: [EKReminder]) -> [CompanionCalendarOccurrence] {
        reminders.prefix(512).compactMap { reminder in
            guard let components = reminder.dueDateComponents, let due = (components.calendar ?? Calendar.current).date(from: components) else { return nil }
            return .init(id: NativeCompanionData.hash(reminder.calendarItemIdentifier), source: "macos.reminders", due: due, allDay: components.hour == nil, completed: reminder.isCompleted)
        }
    }
    private func accept(_ values: [CompanionCalendarOccurrence], source: String, succeeded: Bool) {
        guard let epoch = enabled[source] else { return }
        if !succeeded { healthySources.remove(source); sink(.init(source: source, epoch: epoch, health: "unavailable")); return }
        healthySources.insert(source)
        for (item, phase) in snapshot.replace(values, source: source, succeeded: true) {
            sink(.init(source: source, epoch: epoch, health: "available", occurrenceId: item.id, phase: phase, due: item.due))
        }
    }
    private func finish(at now: Date) {
        fetchRevision = UUID(); fetchWatchdog?.cancel(); fetchWatchdog = nil
        fetching = false; lastRefresh = now
        timeline.replace(snapshot.values.filter { healthySources.contains($0.source) }, at: now)
        schedule()
        if refreshAgain { refreshAgain = false; refresh() }
    }
    private func schedule() {
        timer?.invalidate()
        let now = Date()
        // A bounded maintenance check detects revoked TCC and refreshes the rolling window.
        let next = min(timeline.nextBoundary(after: now) ?? now.addingTimeInterval(60), now.addingTimeInterval(60))
        let expected = generation
        timer = Timer.scheduledTimer(withTimeInterval: max(0.05, next.timeIntervalSince(now)), repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == expected else { return }
                let now = Date()
                for (item, phase) in self.timeline.advance(to: now) {
                    guard let epoch = self.enabled[item.source], self.healthySources.contains(item.source), Self.permission(item.source) == "available" else { continue }
                    self.sink(.init(source: item.source, epoch: epoch, health: "available", occurrenceId: item.id, phase: phase, due: item.due))
                }
                if now.timeIntervalSince(self.lastRefresh) >= 3600 || self.enabled.keys.contains(where: { Self.permission($0) != self.permissionStates[$0] || (Self.permission($0) == "available" && !self.healthySources.contains($0)) }) {
                    self.refresh()
                } else { self.schedule() }
            }
        }
        timer?.tolerance = 0.5
    }
    func stop() {
        generation += 1; enabled = [:]
        fetchRevision = UUID(); fetchWatchdog?.cancel(); fetchWatchdog = nil
        if let reminderFetch { eventStore?.cancelFetchRequest(reminderFetch) }; reminderFetch = nil
        timer?.invalidate(); timer = nil; refreshTask?.cancel(); refreshTask = nil
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }; changeObserver = nil
        timeline.reset(); snapshot.reset(); healthySources = []; fetching = false; refreshAgain = false; eventStore = nil
    }
}
