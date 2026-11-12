import Foundation
import EventKit

struct CompanionCalendarOccurrence: Equatable {
    var id: String
    var source: String
    var due: Date
    var allDay: Bool = false
}

// Time boundaries describe the schedule, never proof that a real meeting or task happened.
struct CompanionCalendarTimeline {
    private(set) var occurrences: [CompanionCalendarOccurrence] = []
    private(set) var checkedAt: Date?
    private var emitted = Set<String>()
    mutating func reset() { occurrences = []; checkedAt = nil; emitted = [] }
    mutating func replace(_ values: [CompanionCalendarOccurrence], at now: Date) {
        occurrences = Array(values.sorted { $0.due < $1.due }.prefix(512))
        let current = Set(occurrences.flatMap { item in ["upcoming_30m", "upcoming_10m", "scheduled_time"].map { key(item, phase: $0) } })
        emitted.formIntersection(current)
        // Initial enumeration does not replay old alarms. Future time boundaries are still scheduled.
        if checkedAt == nil { checkedAt = now }
    }
    func nextBoundary(after now: Date) -> Date? {
        occurrences.filter { !$0.allDay }.flatMap { item in [1800.0, 600.0, 0.0].map { item.due.addingTimeInterval(-$0) } }.filter { $0 > now }.min()
    }
    mutating func advance(to now: Date) -> [(CompanionCalendarOccurrence, String)] {
        guard let previous = checkedAt else { checkedAt = now; return [] }
        checkedAt = now
        // Clock rollback and long sleep establish a new baseline rather than bursting old reminders.
        guard now > previous, now.timeIntervalSince(previous) <= 120 else { return [] }
        var result: [(CompanionCalendarOccurrence, String)] = []
        for occurrence in occurrences where !occurrence.allDay {
            for (seconds, phase) in [(1800.0, "upcoming_30m"), (600.0, "upcoming_10m"), (0.0, "scheduled_time")] {
                let boundary = occurrence.due.addingTimeInterval(-seconds)
                if boundary > previous && boundary <= now && emitted.insert(key(occurrence, phase: phase)).inserted { result.append((occurrence, phase)) }
            }
        }
        return result
    }
    private func key(_ item: CompanionCalendarOccurrence, phase: String) -> String {
        item.source + ":" + item.id + ":" + NativeCompanionData.iso(item.due) + ":" + phase
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
        var values: [CompanionCalendarOccurrence] = []
        let from = now.addingTimeInterval(-86400), to = now.addingTimeInterval(7 * 86400)
        for (source, epoch) in enabled {
            let state = Self.permission(source); permissionStates[source] = state
            sink(.init(source: source, epoch: epoch, health: state))
        }
        if enabled["macos.calendar"] != nil, Self.permission("macos.calendar") == "available" {
            let predicate = eventStore.predicateForEvents(withStart: from, end: to, calendars: nil)
            // Do not access titles, notes, URLs, attendees or locations.
            values = eventStore.events(matching: predicate).prefix(512).map {
                .init(id: NativeCompanionData.hash(($0.eventIdentifier ?? $0.calendarItemIdentifier) + ":" + NativeCompanionData.iso($0.startDate)), source: "macos.calendar", due: $0.startDate, allDay: $0.isAllDay)
            }
        }
        if enabled["macos.reminders"] != nil, Self.permission("macos.reminders") == "available" {
            let predicate = eventStore.predicateForIncompleteReminders(withDueDateStarting: from, ending: to, calendars: nil)
            eventStore.fetchReminders(matching: predicate) { [weak self] reminders in
                let items: [CompanionCalendarOccurrence] = (reminders ?? []).prefix(512).compactMap { reminder in
                    guard let components = reminder.dueDateComponents, let due = (components.calendar ?? Calendar.current).date(from: components) else { return nil }
                    return .init(id: NativeCompanionData.hash(reminder.calendarItemIdentifier), source: "macos.reminders", due: due, allDay: components.hour == nil)
                }
                Task { @MainActor in
                    guard let self, self.generation == expected else { return }
                    self.finish(values + items, at: now)
                }
            }
        } else { finish(values, at: now) }
    }
    private func finish(_ values: [CompanionCalendarOccurrence], at now: Date) {
        fetching = false; lastRefresh = now
        timeline.replace(values, at: now)
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
                    guard let epoch = self.enabled[item.source], Self.permission(item.source) == "available" else { continue }
                    self.sink(.init(source: item.source, epoch: epoch, health: "available", occurrenceId: item.id, phase: phase, due: item.due))
                }
                if now.timeIntervalSince(self.lastRefresh) >= 3600 || self.enabled.keys.contains(where: { Self.permission($0) != self.permissionStates[$0] }) {
                    self.refresh()
                } else { self.schedule() }
            }
        }
        timer?.tolerance = 0.5
    }
    func stop() {
        generation += 1; enabled = [:]
        timer?.invalidate(); timer = nil; refreshTask?.cancel(); refreshTask = nil
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }; changeObserver = nil
        timeline.reset(); fetching = false; refreshAgain = false; eventStore = nil
    }
}
