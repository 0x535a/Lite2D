import Foundation

@MainActor enum CompanionWindowTests {
    static func run(check: (Bool, String) throws -> Void) async throws {
        try check(CompanionWindowClassifier.classify("PRIVATE_PROJECT.swift — Editor").category == .programming, "A synthetic code window yields a broad category rather than its project name")
        try check(CompanionWindowClassifier.classify("An interesting video - YouTube").category == .media, "An allowed synthetic media window can refine the ambiguous browser category")
        try check(CompanionWindowClassifier.classify("Overleaf - PRIVATE_MANUSCRIPT").category == .writing && CompanionWindowClassifier.classify("arXiv research search").category == .research, "Window classification separates writing and reading research without returning content")
        try check(CompanionWindowClassifier.classify("password verification code - PRIVATE_PROJECT.py").category == .unknown && CompanionWindowClassifier.sensitiveApp("com.example.password-manager"), "Sensitive patterns and password-manager Apps never become window activity evidence")
        try check(CompanionWindowClassifier.classify(String(repeating: "x", count: 5000)).category == .unknown, "Oversized window titles are rejected instead of entering model context")
        var settings = CompanionPerceptionSettings()
        settings.mode = .shadow; settings.windowApps = "com.example.none, com.example.none\n com.example.other"
        try check(!settings.enabled("macos.window") && settings.windowAllowlist.count == 2, "Window sensing remains opt-in with an explicit deduplicated App allowlist")
        var values: [CompanionMacSignal] = []
        let sensor = NativeWindowPerception { values.append($0) }
        sensor.configure(epoch: 3, apps: [], sleeping: false)
        try check(values.last?.health == "needs_allowlist", "An empty window allowlist does not inspect the current user window")
        sensor.configure(epoch: 4, apps: ["com.example.nonexistent-fixture"], sleeping: false)
        try await Task.sleep(nanoseconds: 100_000_000)
        try check(values.last?.category == .unknown && values.last?.subject == "no_allowed_window", "An unselected foreground App is rejected before Accessibility content access")
        sensor.stop(); let count = values.count
        try await Task.sleep(nanoseconds: 100_000_000)
        try check(values.count == count, "Stopping window perception removes observers and suppresses late query results")
        let context = CompanionActivityContext(category: .media, confidence: 0.75, observedAt: Date(), expiresAt: Date().addingTimeInterval(30), source: "macos.window", consentEpoch: 1, contextScope: "PRIVATE_SCOPE_ID")
        let projection = NativeCompanionData.string(context.roleProjection(at: Date()) ?? [:])
        try check(!projection.contains("PRIVATE_SCOPE_ID") && !projection.contains("title"), "Window scope identifiers and titles are omitted from the role activity projection")
    }
}
