import Foundation

enum CompanionInitiativeMonitorTests {
    static func run(root: URL, check: (Bool, String) throws -> Void) throws {
        let owner = "11111111-1111-4111-8111-111111111111", other = "22222222-2222-4222-8222-222222222222"
        let store = try NativeCompanionStore(root: root.appendingPathComponent("initiative-management"))
        let memory = try store.recordDirectMemory(owner: owner, source: "experienced", eventID: "actual-movie-agreement", content: "A movie conversation.")
        let memoryID = memory["memoryId"] as! String
        try store.set("session:\(owner)", "original-role-session")
        var values: [CompanionIntention] = []
        for index in 0..<12 {
            let goal = CompanionIntention(ownerCharacterId: owner, goal: "Future thought \(index)", origin: .conversationMemory, topicKey: "topic-\(index)", sourceMemoryId: memoryID, evidenceIds: [memoryID], expiresAt: Date().addingTimeInterval(600))
            _ = try store.proposeIntention(goal); values.append(goal)
        }
        var query = CompanionMonitorQuery(); query.owner = owner; query.section = "intentions"; query.pageSize = 5
        let before = try store.rows("SELECT total_changes() AS n").first?["n"] as? Int
        let page = try store.monitorPage(query, requestID: "one", owners: [owner, other]); query.page = 1
        let next = try store.monitorPage(query, requestID: "two", owners: [owner, other])
        try check(page.total == 12 && page.items.count == 5 && Set(page.items.map(\.id)).isDisjoint(with: next.items.map(\.id)), "Future-goal management pages complete counts without duplicating rows")
        try check(before == store.rows("SELECT total_changes() AS n").first?["n"] as? Int, "Inspecting initiative state never changes goals or invokes a model")
        try check(try store.monitorReference(owner: other, id: values[0].id, kind: "intention").status == "unavailable", "Intention evidence navigation preserves the selected private owner")
        let cancel = CompanionMonitorAction(operation: "intention_cancel", owner: owner, kind: "intention", target: values[0].id)
        let plan = try store.monitorPreview(cancel)
        try check(plan.before.contains(values[0].goal) && plan.after == "cancelled", "Cancelling a future goal presents a concrete before/after preview")
        _ = try store.monitorCommit(plan.id)
        try check(try store.intentions(owner: owner, includeTerminal: true).first(where: { $0.id == values[0].id })?.state == .cancelled && store.memoryRead(memoryID, owner: owner) != nil && store.get("session:\(owner)") as? String == "original-role-session" && store.get("memoryCutoff:\(owner)") == nil, "User goal cancellation preserves supporting memory, Session and conversation cutoff")
        var renamed = values[0]; renamed.id = UUID().uuidString; renamed.topicKey = "renamed-topic"; renamed.goal = "Renamed future thought"
        var rejected = false
        do { _ = try store.proposeIntention(renamed) } catch { rejected = true }
        try check(rejected, "A cancelled goal cannot be recreated under a new title from the same old evidence")
        try store.transitionIntention(values[1].id, owner: owner, to: .needsReview, reason: "persona_changed")
        let resume = try store.monitorPreview(.init(operation: "intention_resume", owner: owner, kind: "intention", target: values[1].id))
        _ = try store.monitorCommit(resume.id)
        try check(try store.intentions(owner: owner).first(where: { $0.id == values[1].id })?.state == .pending, "Human review resumes an eligible goal only after current evidence is validated")
        let stale = try store.monitorPreview(.init(operation: "intention_cancel", owner: owner, kind: "intention", target: values[2].id))
        try store.transitionIntention(values[2].id, owner: owner, to: .deferred, reason: "timing_changed")
        var conflict = false
        do { _ = try store.monitorCommit(stale.id) } catch { conflict = true }
        try check(conflict, "Management rejects a goal preview after its runtime state changes")
        let now = Date(), opportunity = CompanionOpportunity(ownerCharacterId: owner, kind: "interest", sourceEventIds: [], topicKey: "decision", priority: 0.9, intrusionCost: 0.1, notBefore: now, expiresAt: now.addingTimeInterval(30))
        var context = CompanionInterruptContext(); context.idleSeconds = 30
        let decision = CompanionArbiter.decide(opportunity, context: context, mode: .shadow, at: now)
        try store.recordDecision(decision)
        query = .init(); query.section = "decisions"
        let decisions = try store.monitorPage(query, requestID: "decisions", owners: [owner, other])
        try check(decisions.items.first?.id == decision.id && decisions.items.first?.status == "shadow", "The global initiative browser shows actual Shadow decisions and score reasons")
        query.owner = other
        try check(try store.monitorPage(query, requestID: "private-decisions", owners: [owner, other]).total == 0, "Per-character decision filtering cannot expose another character's private goal context")
        let receipt = CompanionOutputReceipt(characterId: owner, topicId: UUID().uuidString, modality: .bubble, text: "Display history fixture")
        try store.saveOutputCandidate(receipt)
        _ = try store.event("utterance", ["characterId": owner, "text": "Display history fixture"])
        try store.clearConversationHistory()
        try check(try store.rows("SELECT id FROM proactive_outputs").isEmpty && store.rows("SELECT id FROM proactive_decisions").isEmpty && store.history().isEmpty && store.memoryRead(memoryID, owner: owner) != nil, "Clearing conversation history also clears initiative receipts and decisions while retaining explicit memory")
    }
}
