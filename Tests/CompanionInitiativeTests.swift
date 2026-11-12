import Foundation

private actor InitiativeRoles: NativeCompanionRoleClient {
    var calls = 0
    func generate(id: String, context: CompanionObject, model: String, reserve: @escaping () async throws -> Bool) async throws -> String { calls += 1; return "{\"text\":\"A gentle movie thought.\",\"emotion\":\"neutral\"}" }
    func receive(id: String, from: String, text: String, messageID: String, model: String) async throws -> String { "receipt" }
    func reserveContinuation(_ id: String) async throws {}
    func forget(_ id: String) async {}
    func interrupt() async {}
    func reapStale() async {}
    func close() async {}
    func consolidate(id: String, job: CompanionObject, model: String, hourlyLimit: Int) async throws -> CompanionObject { ["summary": "", "items": [], "resolved": []] }
    func rotate(id: String, jobID: String, model: String) async throws -> String { "new-session" }
}
private final class InitiativeEvents {
    private let lock = NSLock()
    private var values: [CompanionObject] = []
    func add(_ value: CompanionObject) { lock.withLock { values.append(value) } }
    func utterance() -> CompanionObject? { lock.withLock { values.last { $0["type"] as? String == "utterance" } } }
}
enum CompanionInitiativeTests {
    static func run(root: URL, prompt: URL, helper: URL, node: String, executable: String, check: (Bool, String) throws -> Void) async throws {
        let owner = "11111111-1111-4111-8111-111111111111", other = "22222222-2222-4222-8222-222222222222"
        let directory = root.appendingPathComponent("live-initiative"), store = try NativeCompanionStore(root: directory)
        let personaDir = directory.appendingPathComponent("characters/\(owner)")
        try FileManager.default.createDirectory(at: personaDir, withIntermediateDirectories: true)
        try "Warm life companion.".write(to: personaDir.appendingPathComponent("persona.md"), atomically: true, encoding: .utf8)
        let memory = try store.recordDirectMemory(owner: owner, source: "experienced", eventID: "agreement", content: "Share a movie thought later.")
        let goal = CompanionIntention(ownerCharacterId: owner, goal: "Share a movie thought later", origin: .conversationMemory, topicKey: "film", sourceMemoryId: memory["memoryId"] as? String, evidenceIds: [memory["memoryId"] as! String], priority: 0.9, expiresAt: Date().addingTimeInterval(600))
        _ = try store.proposeIntention(goal)
        let roles = InitiativeRoles(), events = InitiativeEvents()
        let runtime = NativeCompanionRuntime(root: directory, promptFile: prompt, opencode: "/missing", codex: "/missing", node: node, helperScript: helper, executable: executable,
            roles: roles, manageOpenCodeService: false, managePerceptionSensors: false, interruptibility: { var value = CompanionInterruptContext(); value.idleSeconds = 30; return value }, emit: events.add)
        try await runtime.start(automatic: false)
        var config: CompanionObject = ["enabled": true, "intervalMinutes": 0, "hourlyRequests": 12, "perception": ["mode": "shadow"], "characters": [["id": owner, "enabled": true, "visible": true]]]
        config["perception"] = ["mode": "shadow", "workspace": true, "shareActivity": true, "sourceCharacterIds": ["macos.workspace": []]]
        await runtime.configure(config)
        try check(try store.perceptionPolicy("macos.workspace")?.permits(owner, use: .activityContext, remote: true) == false, "Runtime consent enforces explicit empty recipient scopes before model projection")
        config["perception"] = ["mode": "shadow"]
        await runtime.configure(config); await runtime.tick()
        try check(await roles.calls == 0 && (try store.proactiveReplay()).contains { $0.action == "admit" && $0.mode == .shadow }, "Shadow evaluates real pending goals without invoking the character model")
        config["perception"] = ["mode": "live"]
        await runtime.configure(config)
        try await Task.sleep(nanoseconds: 5_100_000_000)
        await runtime.tick(); await runtime.waitForTopic()
        guard let output = events.utterance(), let id = output["outputId"] as? String else { throw NativeCompanionData.error("Initiative did not emit a tracked output") }
        try check(await roles.calls == 1 && (try store.intentions(owner: owner)).first?.state == .executing, "Live arbitration admits one character and keeps its goal executing while the output is queued")
        let before = try store.dailyDialogue(owner: owner, from: .distantPast, to: .distantFuture)
        try check(before.isEmpty, "A queued but unseen expression is excluded from daily memory evidence")
        await runtime.command(["type": "output_receipt", "outputId": id, "characterId": other, "status": "presented"])
        try check(try store.intentions(owner: owner).first?.state == .executing, "A wrong character cannot acknowledge another character's output")
        await runtime.command(["type": "output_receipt", "outputId": id, "characterId": owner, "status": "presented"])
        try check(try store.intentions(owner: owner, includeTerminal: true).first?.state == .completed && store.dailyDialogue(owner: owner, from: .distantPast, to: .distantFuture).count == 1, "Actual host presentation completes the future expression and admits it as conversation evidence")
        await runtime.command(["type": "output_receipt", "outputId": id, "characterId": owner, "status": "completed"])
        await runtime.close()
        var socialGoal = goal; socialGoal.id = UUID().uuidString; socialGoal.topicKey = "peer-film"; socialGoal.targetCharacterId = other
        let socialID = try store.proposeIntention(socialGoal)
        try store.transitionIntention(socialID, owner: owner, to: .ready, reason: "test")
        try store.transitionIntention(socialID, owner: owner, to: .executing, reason: "test")
        let delivery = UUID().uuidString
        try store.execute("INSERT INTO deliveries VALUES (?,?,?,?,?,'queued',NULL,?)", [delivery, UUID().uuidString, owner, other, "A movie thought", NativeCompanionData.iso()])
        let receipt = CompanionOutputReceipt(characterId: owner, topicId: UUID().uuidString, modality: .socialMessage, text: "A movie thought", relatedIntentionIds: [socialID], deliveryId: delivery)
        try store.saveOutputCandidate(receipt)
        try store.acknowledgeOutput(receipt.id, owner: owner, status: .admitted)
        try store.acknowledgeOutput(receipt.id, owner: owner, status: .queued)
        try store.acknowledgeOutput(receipt.id, owner: owner, status: .presented)
        try store.acknowledgeOutput(receipt.id, owner: owner, status: .completed)
        try check(try store.intentions(owner: owner).first?.state == .executing, "Finishing a social bubble does not claim that the recipient consumed its message")
        try store.execute("UPDATE deliveries SET status='delivered' WHERE id=?", [delivery])
        try store.finishSocialDelivery(delivery)
        try check(try store.intentions(owner: owner, includeTerminal: true).first?.state == .completed, "Confirmed peer consumption completes a send intention independently of UI typing")
    }
}
