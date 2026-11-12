import Foundation

enum CompanionContextTests {
    static func run(root: URL, check: (Bool, String) throws -> Void) throws {
        let owner = "11111111-1111-4111-8111-111111111111", other = "22222222-2222-4222-8222-222222222222"
        let session = NativeObservedSession(backend: "codex", id: "private-session-id", project: "/private/project", title: "SECRET_PROJECT_AND_CODE", updated: 123)
        let projection = NativeCompanionData.string(session.roleObject)
        try check(!projection.contains("SECRET_PROJECT") && !projection.contains("/private/") && !projection.contains("private-session-id") && session.roleReference.hasPrefix("activity_"), "Observer role projection contains no title, project path, content or source session ID")
        try check(session.roleObject["state"] as? String == "unknown" && session.roleObject["activityCategory"] as? String == "unknown", "Agent metadata never proves current human activity or a specific task")
        let store = try NativeCompanionStore(root: root.appendingPathComponent("initiative-context"))
        let ownEvent = try store.event("utterance", ["characterId": owner, "text": "A real movie conversation."])
        _ = try store.event("utterance", ["characterId": other, "text": "PRIVATE_OTHER_SPEECH"])
        _ = try store.memoryWrite(owner: owner, type: "fact", provenance: "observed", content: "SECRET_OLD_WORK_CONTEXT")
        _ = try store.memoryWrite(owner: owner, type: "diary", provenance: "legacy_import", content: "SECRET_OLD_DIARY")
        _ = try store.memoryWrite(owner: owner, type: "opinion", provenance: "inferred", content: "I enjoy movies.")
        let dialogue = try store.recentRoleDialogue(owner: owner)
        let selected = try store.initiativeMemories(owner: owner, intentions: [])
        let wire = NativeCompanionData.string(dialogue) + NativeCompanionData.string(selected)
        try check(!wire.contains("SECRET_") && !wire.contains("PRIVATE_OTHER") && wire.contains("movies"), "Automatic context excludes old work observations, legacy diaries and another character's unreceived speech")
        try check(dialogue.first?["id"] as? String == "dialogue:\(ownEvent["sequence"]!)", "Own actual conversation is supplied with usable intention evidence IDs")
        let loop = try store.memoryWrite(owner: owner, type: "event", provenance: "inferred", content: "Share a movie thought later.", evidenceIDs: ["dialogue:\(ownEvent["sequence"]!)"])
        let memoryID = loop["memoryId"] as! String
        try store.execute("INSERT INTO daily_open_loops VALUES (?,?,'open')", [memoryID, owner])
        try store.syncOpenLoopIntentions(owner: owner)
        let intention = try store.intentions(owner: owner)[0]
        try store.syncOpenLoopIntentions(owner: owner)
        try check(try store.intentions(owner: owner).count == 1 && intention.sourceMemoryId == memoryID, "Daily open-loop handoff creates exactly one evidence-backed future goal")
        try store.transitionIntention(intention.id, owner: owner, to: .ready, reason: "test")
        try store.transitionIntention(intention.id, owner: owner, to: .executing, reason: "test")
        try store.transitionIntention(intention.id, owner: owner, to: .completed, reason: "presented")
        try store.syncOpenLoopIntentions(owner: owner)
        try check(try store.intentions(owner: owner, includeTerminal: true).count == 1 && store.dailyLoops(owner).count == 1, "Finishing a follow-up does not claim the underlying promise fulfilled or recreate the same goal")
        var goal = intention; goal.id = UUID().uuidString; goal.topicKey = "new-topic"; goal.state = .pending; goal.attemptCount = 0
        _ = try store.proposeIntention(goal)
        try store.reviewIntentionPersona(owner: owner, revision: 1)
        try store.reviewIntentionPersona(owner: owner, revision: 2)
        try check(try store.intentions(owner: owner).first?.state == .needsReview, "Persona edits require future goals to be reviewed under the current identity")
        try store.execute("UPDATE daily_open_loops SET status='resolved' WHERE memory_id=?", [memoryID])
        _ = try store.forgetMemory(memoryID, owner: owner)
        try check(try store.intentions(owner: owner, includeTerminal: true).isEmpty, "Forgetting an open loop removes all derived scheduling goals")
        let snapshot = CompanionContextSnapshot(characterId: owner, personaRevision: 2, generatedAt: Date(), expiresAt: Date().addingTimeInterval(90), intentions: [], memories: Array(repeating: ["id": "one", "content": String(repeating: "x", count: 2000)], count: 20))
        try check(NativeCompanionData.array(snapshot.roleContext(activity: nil, at: Date())["memories"]).count == 8, "Role context enforces its memory count and excerpt limits")
    }
}
