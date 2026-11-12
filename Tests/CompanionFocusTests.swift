import Foundation

private actor FocusFixture {
    var quiet = false
    var failing = false
    var calls = 0
    func current() throws -> CompanionFocusResult {
        calls += 1
        if failing { throw CompanionNotificationError.temporarilyUnavailable }
        return .init(quiet: quiet, state: "available")
    }
    func set(quiet: Bool, failing: Bool = false) { self.quiet = quiet; self.failing = failing }
}
@MainActor enum CompanionFocusTests {
    static func run(check: (Bool, String) throws -> Void) async throws {
        let suite = "Lite2D.FocusFixture." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = FocusFixture()
        var signals: [CompanionMacSignal] = []
        let sensor = NativeFocusPerception(defaults: defaults, provider: { try await fixture.current() }) { signals.append($0) }
        sensor.configure(epochs: ["macos.focus": 4, "macos.explicit_activity": 5])
        try await Task.sleep(nanoseconds: 100_000_000)
        try check(signals.first?.focusQuiet == true && signals.last?.focusQuiet == false, "Focus starts conservatively unknown, then applies only the scoped App filter result")
        defaults.set(["id": UUID().uuidString, "category": "writing", "at": Date().timeIntervalSince1970], forKey: "CompanionExplicitActivity")
        NotificationCenter.default.post(name: Notification.Name("Lite2D.CompanionActivityChanged"), object: nil)
        try await Task.sleep(nanoseconds: 100_000_000)
        let activities = signals.filter { $0.source == "macos.explicit_activity" }
        try check(activities.count == 1 && activities[0].category == .writing && activities[0].sourceAt != nil, "Explicit activity input carries only a validated enum and its original timestamp")
        NotificationCenter.default.post(name: Notification.Name("Lite2D.CompanionActivityChanged"), object: nil)
        try await Task.sleep(nanoseconds: 100_000_000)
        try check(signals.filter { $0.source == "macos.explicit_activity" }.count == 1, "Repeated explicit activity notifications cannot replay the same input")
        defaults.set(["id": UUID().uuidString, "category": "execute-shell-prompt", "at": Date().timeIntervalSince1970], forKey: "CompanionExplicitActivity")
        NotificationCenter.default.post(name: Notification.Name("Lite2D.CompanionActivityChanged"), object: nil)
        try await Task.sleep(nanoseconds: 100_000_000)
        try check(signals.filter { $0.source == "macos.explicit_activity" }.count == 1, "The explicit bridge rejects arbitrary commands or activity strings")
        await fixture.set(quiet: true)
        NotificationCenter.default.post(name: Notification.Name("Lite2D.CompanionFocusChanged"), object: nil)
        try await Task.sleep(nanoseconds: 900_000_000)
        try check(signals.last?.focusQuiet == true && signals.last?.health == "available", "A configured quiet App filter suppresses proactive expression after settling")
        await fixture.set(quiet: false, failing: true)
        NotificationCenter.default.post(name: Notification.Name("Lite2D.CompanionFocusChanged"), object: nil)
        try await Task.sleep(nanoseconds: 900_000_000)
        try check(signals.last?.focusQuiet == true && signals.last?.health == "temporarily_unavailable", "An unavailable Focus service is unknown and quiet, never falsely reported as inactive")
        defaults.set(["id": UUID().uuidString, "category": "media", "at": Date().addingTimeInterval(-301).timeIntervalSince1970], forKey: "CompanionExplicitActivity")
        CompanionActivityIntent.purgeExpiredInput(defaults: defaults)
        try check(defaults.dictionary(forKey: "CompanionExplicitActivity") == nil, "Expired explicit activity is physically cleared from the short-term App cache")
        var settings = CompanionPerceptionSettings(); settings.focus = true
        try check(settings.enabled("macos.focus") && !settings.enabled("macos.workspace"), "The scoped Focus gate can remain enabled independently of activity collection")
        sensor.stop(); let count = signals.count
        NotificationCenter.default.post(name: Notification.Name("Lite2D.CompanionFocusChanged"), object: nil)
        try await Task.sleep(nanoseconds: 100_000_000)
        try check(signals.count == count, "Stopping the Focus source removes listeners and rejects late state")
    }
}
