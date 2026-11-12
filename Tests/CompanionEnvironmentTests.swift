import Foundation

private final class EnvironmentSignals {
    private let lock = NSLock()
    private var values: [CompanionMacSignal] = []
    func add(_ value: CompanionMacSignal) { lock.withLock { values.append(value) } }
    func all() -> [CompanionMacSignal] { lock.withLock { values } }
}
enum CompanionEnvironmentTests {
    static func directories(root: URL, check: (Bool, String) throws -> Void) async throws {
        let directory = root.appendingPathComponent("directory-perception"), own = directory.appendingPathComponent("controller")
        let watched = directory.appendingPathComponent("explicit-project")
        try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
        let item = CompanionWatchedDirectory(path: watched.path)
        try check(CompanionWatchedDirectory.permitted(watched, ownDataRoot: own) && !CompanionWatchedDirectory.permitted(FileManager.default.homeDirectoryForCurrentUser, ownDataRoot: own), "Directory authorization permits a specific root while rejecting the whole home directory")
        try check(!CompanionWatchedDirectory.permitted(directory, ownDataRoot: own) && !CompanionWatchedDirectory.permitted(own.appendingPathComponent("child"), ownDataRoot: own), "Directory observation excludes Lite2D data and ancestors to avoid self-triggering and private store access")
        let signals = EnvironmentSignals(), sensor = NativeDirectoryPerception(ownDataRoot: own, sink: signals.add)
        await sensor.configure(epoch: 3, directories: [item], sleeping: true)
        try await Task.sleep(nanoseconds: 100_000_000)
        try check(signals.all().isEmpty, "Sleeping directory sensors do not open or enumerate authorized roots")
        await sensor.configure(epoch: 3, directories: [item], sleeping: false)
        try check(signals.all().contains { $0.type == "filesystem.baseline" && $0.initial }, "Directory enable establishes a silent baseline without enumerating files")
        try "PRIVATE_FILE_BODY".write(to: watched.appendingPathComponent("PRIVATE_FILENAME.txt"), atomically: true, encoding: .utf8)
        let deadline = Date().addingTimeInterval(8)
        while !signals.all().contains(where: { ["filesystem.changed", "filesystem.reconcile_needed"].contains($0.type) }), Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        try check(signals.all().contains { ["filesystem.changed", "filesystem.reconcile_needed"].contains($0.type) } && signals.all().allSatisfy { !$0.subject.contains("PRIVATE_") && !$0.subject.contains(watched.path) }, "Native directory changes produce only opaque-root signals, never file names or contents")
        await sensor.stop(); let count = signals.all().count
        try "Another private body".write(to: watched.appendingPathComponent("other.txt"), atomically: true, encoding: .utf8)
        try await Task.sleep(nanoseconds: 2_500_000_000)
        try check(signals.all().count == count, "Directory source removal cancels file callbacks and pending debounce work")
    }
    @MainActor static func environment(check: (Bool, String) throws -> Void) async throws {
        try check(CompanionPowerSnapshot.classify(thermal: 2, lowPower: false, percent: 90, charging: true, acPower: true).constrained, "Thermal pressure takes precedence over charging and battery level")
        try check(CompanionPowerSnapshot.classify(thermal: 0, lowPower: false, percent: 10, charging: false, acPower: false).subject == "battery_low", "Low battery is a coarse resource signal rather than an exact personal state")
        try check(!CompanionPowerSnapshot.classify(thermal: 0, lowPower: false, percent: 10, charging: true, acPower: true).constrained, "AC charging does not create a false low-resource gate from remaining capacity alone")
        let now = Date(), owner = UUID().uuidString
        var opportunity = CompanionOpportunity(ownerCharacterId: owner, kind: "intrinsic_interest", sourceEventIds: [], topicKey: "interest", priority: 0.9, intrusionCost: 0.2, notBefore: now, expiresAt: now.addingTimeInterval(60))
        var context = CompanionInterruptContext(); context.idleSeconds = 30; context.energyConstrained = true
        try check(CompanionArbiter.decide(opportunity, context: context, mode: .live, at: now).reasonCodes.contains("resource_pressure"), "Resource pressure suppresses optional intrinsic inference")
        opportunity.kind = "schedule.upcoming"
        try check(CompanionArbiter.decide(opportunity, context: context, mode: .live, at: now).action == "admit", "Resource pressure does not automatically silence a worthwhile scheduled reminder")
        context.energyConstrained = false; context.audioActive = true
        let audioDecision = CompanionArbiter.decide(opportunity, context: context, mode: .live, at: now)
        try check(audioDecision.action == "admit" && (audioDecision.scores["cost"] ?? 0) > opportunity.intrusionCost, "Audio activity raises interruption cost without claiming a meeting or forcing a hard mute")
        var values: [CompanionMacSignal] = []
        let source = NativeAudioPerception { values.append($0) }
        source.configure(epoch: 9, sleeping: false)
        try check(values.first?.source == "macos.audio" && values.allSatisfy { ["audio_route_builtin", "audio_route_external", "audio_route_unknown"].contains($0.subject) }, "CoreAudio initial query exposes only route class and optional running state, not names or samples")
        source.stop(); let count = values.count
        try await Task.sleep(nanoseconds: 100_000_000)
        try check(values.count == count, "Audio source teardown removes listeners and rejects queued callbacks")
    }
}
