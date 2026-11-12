import Foundation

@MainActor enum CompanionMacPerceptionTests {
    static func run(check: (Bool, String) throws -> Void) async throws {
        try check(CompanionActivityClassifier.classify(bundleID: "com.apple.dt.Xcode").0 == .programming, "A known development app maps only to a broad programming category")
        try check(CompanionActivityClassifier.classify(bundleID: "com.apple.Terminal").0 == .unknown, "An ambiguous terminal does not imply programming or experiment activity")
        try check(CompanionActivityClassifier.classify(bundleID: "com.apple.Safari").0 == .browsing, "A browser does not reveal whether a page contains video, papers, or private content")
        try check(CompanionActivityClassifier.classify(bundleID: "custom.app", overrides: ["custom.app": .experiment]).0 == .experiment, "User app classification overrides are supported without window content")
        let defaults = try CompanionProactiveCoding.decode(CompanionPerceptionSettings.self, "{}")
        try check(defaults.mode == .off && !defaults.workspace && !defaults.idle && !defaults.shareActivity, "Existing installations migrate with new sensors and model sharing disabled")
        var settings = defaults; settings.mode = .shadow; settings.workspace = true; settings.idle = true; settings.power = true; settings.network = true
        let epochs = Dictionary(uniqueKeysWithValues: CompanionPerceptionSettings.sourceNames.map { ($0, 7) })
        var signals: [CompanionMacSignal] = []
        let sensor = NativeMacPerception { signals.append($0) }
        sensor.configure(settings, epochs: epochs, suspended: false)
        try await Task.sleep(nanoseconds: 150_000_000)
        try check(Set(signals.map(\.source)).isSuperset(of: ["macos.session", "macos.workspace", "macos.idle", "macos.power"]), "Native sensors produce initial permission-free snapshots without application content")
        try check(signals.allSatisfy { $0.epoch == 7 && $0.initial }, "Initial sensor samples establish a baseline with the configured consent epoch")
        try check(signals.first(where: { $0.source == "macos.idle" })?.idleSeconds.map { $0.isFinite && $0 >= 0 } == true, "Idle sensor queries any input event rather than the null-event timer")
        sensor.stop(); let count = signals.count
        try await Task.sleep(nanoseconds: 150_000_000)
        try check(signals.count == count, "Stopping sensors rejects queued native callbacks and cancels monitoring")
        sensor.configure(settings, epochs: epochs.mapValues { $0 + 1 }, suspended: true)
        let suspendedSignals = Array(signals.dropFirst(count))
        try check(suspendedSignals.count == 1 && suspendedSignals.first?.source == "macos.session" && suspendedSignals.first?.sleeping == true, "Sleep leaves only lifecycle monitoring, not activity sampling")
        sensor.stop()
    }
}
