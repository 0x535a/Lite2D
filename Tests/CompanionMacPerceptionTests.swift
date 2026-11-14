import Foundation

@MainActor enum CompanionMacPerceptionTests {
    static func run(check: (Bool, String) throws -> Void) async throws {
        try check(CompanionActivityClassifier.classify(bundleID: "com.apple.dt.Xcode").0 == .programming, "A known development app maps only to a broad programming category")
        try check(CompanionActivityClassifier.classify(bundleID: "com.apple.Terminal").0 == .unknown, "An ambiguous terminal does not imply programming or experiment activity")
        try check(CompanionActivityClassifier.classify(bundleID: "com.apple.Safari").0 == .browsing, "A browser does not reveal whether a page contains video, papers, or private content")
        try check(CompanionActivityClassifier.classify(bundleID: "custom.app", overrides: ["custom.app": .experiment]).0 == .experiment, "User app classification overrides are supported without window content")
        let defaults = try CompanionProactiveCoding.decode(CompanionPerceptionSettings.self, "{}")
        try check(defaults.mode == .off && !defaults.workspace && !defaults.idle && !defaults.shareActivity, "Existing installations migrate with new sensors and model sharing disabled")
        let owner = "11111111-1111-4111-8111-111111111111", other = "22222222-2222-4222-8222-222222222222"
        let scoped = try CompanionProactiveCoding.decode(CompanionPerceptionSettings.self, "{\"sourceCharacterIds\":{\"macos.workspace\":[\"\(owner)\"],\"macos.calendar\":[]},\"auditRetentionHours\":999}")
        try check(scoped.recipients(for: "macos.workspace", enabled: [owner, other]) == [owner] && scoped.recipients(for: "macos.calendar", enabled: [owner, other]).isEmpty && scoped.auditRetentionHours == 168, "Per-source recipient scopes distinguish one character from an explicit deny-all and bound audit retention")
        let malformed = try CompanionProactiveCoding.decode(CompanionPerceptionSettings.self, "{\"sourceCharacterIds\":false}")
        try check(malformed.recipients(for: "macos.workspace", enabled: [owner]).isEmpty, "Malformed recipient consent fails closed instead of allowing all characters")
        var settings = defaults; settings.mode = .shadow; settings.workspace = true; settings.idle = true; settings.power = true; settings.network = true
        let epochs = Dictionary(uniqueKeysWithValues: CompanionPerceptionSettings.sourceNames.map { ($0, 7) })
        var signals: [CompanionMacSignal] = []
        let sensor = NativeMacPerception { signals.append($0) }
        sensor.configure(settings, epochs: epochs, suspended: false)
        try await Task.sleep(nanoseconds: 150_000_000)
        let sleeping = signals.first(where: { $0.source == "macos.session" })?.sleeping == true
        let expected = sleeping ? ["macos.session"] : ["macos.session", "macos.workspace", "macos.idle", "macos.power"]
        try check(Set(signals.map(\.source)).isSuperset(of: expected) && (!sleeping || signals.allSatisfy { $0.source == "macos.session" }), "Native sensors establish permission-free snapshots, or only lifecycle state when the real display is asleep")
        try check(signals.allSatisfy { $0.epoch == 7 } && expected.allSatisfy { source in signals.first(where: { $0.source == source })?.initial == true }, "Initial sensor samples establish a baseline with the configured consent epoch")
        try check(sleeping ? !signals.contains { $0.source == "macos.idle" } : signals.first(where: { $0.source == "macos.idle" })?.idleSeconds.map { $0.isFinite && $0 >= 0 } == true, "Idle sampling uses the any-input timer while respecting actual display sleep")
        sensor.stop(); let count = signals.count
        try await Task.sleep(nanoseconds: 150_000_000)
        try check(signals.count == count, "Stopping sensors rejects queued native callbacks and cancels monitoring")
        sensor.configure(settings, epochs: epochs.mapValues { $0 + 1 }, suspended: true)
        let suspendedSignals = Array(signals.dropFirst(count))
        try check(suspendedSignals.count == 1 && suspendedSignals.first?.source == "macos.session" && suspendedSignals.first?.sleeping == true, "Sleep leaves only lifecycle monitoring, not activity sampling")
        sensor.stop()
    }
}
