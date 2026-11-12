import Foundation

enum CompanionCalendarTests {
    static func run(check: (Bool, String) throws -> Void) throws {
        let now = Date(timeIntervalSince1970: 1794448800)
        var timeline = CompanionCalendarTimeline()
        let item = CompanionCalendarOccurrence(id: "synthetic-occurrence", source: "macos.calendar", due: now.addingTimeInterval(2000))
        timeline.replace([item], at: now)
        try check(timeline.advance(to: now).isEmpty && timeline.nextBoundary(after: now) == now.addingTimeInterval(200), "Initial calendar enumeration is silent and schedules the next future boundary")
        _ = timeline.advance(to: now.addingTimeInterval(100))
        let boundary = timeline.advance(to: now.addingTimeInterval(201))
        try check(boundary.count == 1 && boundary.first?.1 == "upcoming_30m", "Calendar threshold crossings use occurrence times without event text")
        try check(timeline.advance(to: now.addingTimeInterval(201)).isEmpty, "Repeated timer delivery does not replay a calendar boundary")
        try check(timeline.advance(to: now.addingTimeInterval(200)).isEmpty, "Wall-clock rollback establishes a new time baseline")
        try check(timeline.advance(to: now.addingTimeInterval(202)).isEmpty, "Crossing a boundary again after clock rollback cannot duplicate an alarm")
        timeline.replace([.init(id: item.id, source: item.source, due: now.addingTimeInterval(5000))], at: now.addingTimeInterval(201))
        try check(timeline.nextBoundary(after: now.addingTimeInterval(201)) == now.addingTimeInterval(3200), "Rescheduling removes stale upcoming alarms")
        timeline.replace([], at: now.addingTimeInterval(202))
        try check(timeline.nextBoundary(after: now) == nil, "Removing a fetched occurrence removes its queued time boundaries")
        timeline.reset(); timeline.replace([item], at: now)
        try check(timeline.advance(to: now.addingTimeInterval(500)).isEmpty, "A long sleep never bursts old schedule reminders")
        timeline.reset(); timeline.replace([.init(id: "all-day", source: "macos.calendar", due: now.addingTimeInterval(1000), allDay: true)], at: now)
        try check(timeline.nextBoundary(after: now) == nil, "All-day schedules do not manufacture midnight timed reminders")
        var settings = CompanionPerceptionSettings(); settings.mode = .shadow
        try check(!settings.enabled("macos.calendar") && !settings.enabled("macos.reminders"), "Calendar and reminders remain separately opt-in")
        settings.calendar = true
        try check(settings.enabled("macos.calendar") && !settings.enabled("macos.reminders"), "Enabling calendar never grants reminder access")
        var snapshot = CompanionCalendarSnapshot()
        var reminder = CompanionCalendarOccurrence(id: "reminder-one", source: "macos.reminders", due: now.addingTimeInterval(600))
        try check(snapshot.replace([reminder], source: reminder.source, succeeded: true).isEmpty, "A new authorized schedule snapshot establishes a silent differential baseline")
        try check(snapshot.replace([], source: reminder.source, succeeded: false).isEmpty && snapshot.values == [reminder], "A failed reminder fetch retains evidence without manufacturing disappearance or completion")
        reminder.completed = true
        var staleReminder = reminder; staleReminder.completed = false
        let completion = snapshot.replace([staleReminder, reminder], source: reminder.source, succeeded: true)
        try check(completion.count == 1 && completion.first?.1 == "completed", "Only an observed incomplete-to-complete transition reports reminder completion")
        try check(snapshot.values.first?.completed == true, "A reminder completed between the two fetches supersedes its earlier incomplete snapshot")
        timeline.reset(); timeline.replace([reminder], at: now)
        try check(timeline.nextBoundary(after: now) == nil, "Completed reminders cannot retain queued time alarms")
        let removed = snapshot.replace([], source: reminder.source, succeeded: true)
        try check(removed.first?.1 == "no_longer_visible", "Leaving the bounded query window is not reported as deletion or cancellation")
        _ = snapshot.replace([item], source: item.source, succeeded: true)
        var moved = item; moved.due = now.addingTimeInterval(3000)
        try check(snapshot.replace([moved], source: item.source, succeeded: true).first?.1 == "updated", "A stable recurring occurrence reports rescheduling as an update")
        var second = moved; second.id = "another-occurrence"
        try check(snapshot.replace([moved, second], source: item.source, succeeded: true).first?.1 == "first_seen", "New occurrences are first-seen observations without claiming creation")
        snapshot.clear(item.source)
        try check(snapshot.replace([item], source: item.source, succeeded: true).isEmpty, "Authorization scope reset establishes a fresh baseline instead of replaying old changes")
        timeline.reset()
        let ending = CompanionCalendarOccurrence(id: "ending", source: item.source, due: now.addingTimeInterval(-300), end: now.addingTimeInterval(30))
        timeline.replace([ending], at: now)
        try check(timeline.advance(to: now.addingTimeInterval(31)).first?.1 == "scheduled_end", "Calendar end is a scheduled time boundary without asserting real-world attendance")
    }
}
