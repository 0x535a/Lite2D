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
    }
}
