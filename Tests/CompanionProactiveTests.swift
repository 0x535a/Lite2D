import Foundation

enum CompanionProactiveTests {
    static func run(root: URL, check: (Bool, String) throws -> Void) throws {
        let owner = "11111111-1111-4111-8111-111111111111", other = "22222222-2222-4222-8222-222222222222"
        let now = Date(timeIntervalSince1970: 1794448800)
        let store = try NativeCompanionStore(root: root.appendingPathComponent("proactive"))
        func refuses(_ action: () throws -> Void) -> Bool { do { try action(); return false } catch { return true } }
        var policy = CompanionPerceptionPolicy(); policy.allowedCharacterIds = [owner]
        policy = try store.setPerceptionConsent(source: "test.workspace", enabled: true, policy: policy)
        var observation = CompanionObservation(id: "stable-source-id", source: "test.workspace", type: "activity.changed", observedAt: now, subject: "developer_tool", expiresAt: now.addingTimeInterval(300))
        observation.policy = policy; observation.activityCategory = .programming
        let encoded = try CompanionProactiveCoding.encode(observation)
        try check(try CompanionProactiveCoding.decode(CompanionObservation.self, encoded) == observation, "Perception wire envelope round trips with typed metadata")
        let id = try store.ingestPerception(observation, now: now)!
        try check(try store.ingestPerception(observation, now: now) == nil && store.rows("SELECT payload IS NULL AS empty FROM perception_events").first?["empty"] as? Int == 1, "Ephemeral observation persists only dedupe identity, not source content")
        var opportunity = CompanionOpportunity(ownerCharacterId: owner, kind: "activity.changed", sourceEventIds: [id], topicKey: "activity", priority: 0.8, intrusionCost: 0.2, notBefore: now, expiresAt: now.addingTimeInterval(60))
        let opportunityID = try store.saveOpportunity(opportunity, now: now)
        opportunity.id = UUID().uuidString
        try check(try store.saveOpportunity(opportunity, now: now) == opportunityID, "An active topic produces at most one opportunity per character")
        opportunity.ownerCharacterId = other
        try check(refuses { _ = try store.saveOpportunity(opportunity, now: now) }, "Observation authorization is enforced before a character receives an opportunity")
        opportunity.ownerCharacterId = owner
        var context = CompanionInterruptContext(); context.idleSeconds = 30
        let decision = CompanionArbiter.decide(opportunity, context: context, mode: .shadow, at: now)
        try store.recordDecision(decision)
        try check(decision.action == "admit" && decision.mode == .shadow && (try store.proactiveReplay()).first == decision && (try store.rows("SELECT id FROM proactive_outputs")).isEmpty, "Shadow admission is replayable without generating or presenting output")
        context.manualPause = true
        try check(CompanionArbiter.decide(opportunity, context: context, mode: .shadow, at: now).reasonCodes.contains("manual_pause"), "Manual pause remains a hard gate independently of other state")
        context.manualPause = false; context.idleSeconds = 0
        try check(CompanionArbiter.decide(opportunity, context: context, mode: .live, at: now).selectedModality == .silent, "Active input suppresses unsolicited expression")
        var invalid = observation; invalid.confidence = .nan
        try check(refuses { _ = try store.ingestPerception(invalid, now: now) }, "Nonfinite classifier confidence is rejected")
        observation.revision = 2
        try check(try store.ingestPerception(observation, now: now) == id && store.rows("SELECT state FROM proactive_opportunities WHERE id=?", [opportunityID]).first?["state"] as? String == "cancelled", "Event revisions retain identity and invalidate stale opportunities")
        let revoked = try store.setPerceptionConsent(source: observation.source, enabled: false, policy: policy)
        try check(revoked.consentEpoch > policy.consentEpoch && (try store.ingestPerception(observation, now: now)) == nil, "Revocation rejects late callbacks with their old epoch")
        let regranted = try store.setPerceptionConsent(source: observation.source, enabled: true, policy: revoked)
        try check(regranted.consentEpoch > revoked.consentEpoch && (try store.ingestPerception(observation, now: now)) == nil, "Reenabling a source never reauthorizes an old callback")
        observation.policy = regranted
        _ = try store.ingestPerception(observation, now: now)
        try check(refuses { try store.savePerceptionCursor(source: observation.source, generation: "one", cursor: "10", epoch: policy.consentEpoch) }, "Cursor commits are guarded by the current consent epoch")
        var activity = CompanionActivityContext(category: .programming, confidence: 0.9, observedAt: now, expiresAt: now.addingTimeInterval(60), source: "private-source-path", consentEpoch: 1)
        let activityWire = NativeCompanionData.string(activity.roleProjection(at: now) ?? [:])
        try check(!activityWire.contains("private-source-path") && activity.roleProjection(at: now.addingTimeInterval(61)) == nil, "Activity projection excludes source identifiers and expires")
        activity.confidence = 0.3
        try check(activity.roleProjection(at: now) == nil, "Weak activity evidence does not enter role context")

        let memory = try store.recordDirectMemory(owner: owner, source: "experienced", eventID: "real-dialogue", content: "We agreed to share a movie thought later.")
        let memoryID = memory["memoryId"] as! String
        var intention = CompanionIntention(ownerCharacterId: owner, goal: "Share a movie thought", origin: .conversationMemory, topicKey: "movie", sourceMemoryId: memoryID, evidenceIds: [memoryID], expiresAt: now.addingTimeInterval(600), createdAt: now, updatedAt: now)
        let intentionID = try store.proposeIntention(intention, now: now)
        intention.id = UUID().uuidString
        try check(try store.proposeIntention(intention, now: now) == intentionID, "Intention creation is idempotent by owner and active topic")
        var forged = intention; forged.ownerCharacterId = other; forged.topicKey = "forged"
        try check(refuses { _ = try store.proposeIntention(forged, now: now) }, "A character cannot create an intention using another character's evidence")
        try check(refuses { try store.transitionIntention(intentionID, owner: owner, to: .completed, reason: "model_claim", now: now) }, "A model claim cannot jump from pending to completed")
        try store.transitionIntention(intentionID, owner: owner, to: .ready, reason: "eligible", now: now)
        try store.transitionIntention(intentionID, owner: owner, to: .executing, reason: "admitted", now: now)
        try store.transitionIntention(intentionID, owner: owner, to: .deferred, reason: "output_cancelled", now: now)
        try check(refuses { try store.transitionIntention(intentionID, owner: owner, to: .ready, reason: "retry", now: now) }, "Deferred intentions cannot bypass their cooldown")
        try store.transitionIntention(intentionID, owner: owner, to: .ready, reason: "retry", now: now.addingTimeInterval(181))
        try store.transitionIntention(intentionID, owner: owner, to: .executing, reason: "admitted", now: now.addingTimeInterval(181))
        let restarted = try NativeCompanionStore(root: store.root)
        try check(try restarted.intentions(owner: owner).first?.state == .needsReview && restarted.intentions(owner: owner).first?.attemptCount == 2, "Interrupted execution survives restart as uncertain, preserving the attempt count")
        try restarted.transitionIntention(intentionID, owner: owner, to: .pending, reason: "reviewed", now: now.addingTimeInterval(182))
        try check(refuses { try restarted.transitionIntention(intentionID, owner: owner, to: .ready, reason: "retry", now: now.addingTimeInterval(400)) }, "Restart does not reset maximum intention attempts")
        _ = try restarted.forgetMemory(memoryID, owner: owner)
        try check(try restarted.intentions(owner: owner, includeTerminal: true).isEmpty, "Forgetting evidence erases dependent future goals as well as memory content")

        let direct = try restarted.event("utterance", ["characterId": owner, "text": "I will share another thought later."])
        let sequence = try restarted.rows("SELECT seq FROM events WHERE type='utterance' ORDER BY seq DESC LIMIT 1").first?["seq"] as! Int
        _ = direct
        let goal = CompanionIntention(ownerCharacterId: owner, goal: "Share another thought", origin: .conversationMemory, topicKey: "another-thought", evidenceIds: ["dialogue:\(sequence)"], expiresAt: now.addingTimeInterval(900), createdAt: now, updatedAt: now)
        let goalID = try restarted.proposeIntention(goal, now: now)
        try restarted.transitionIntention(goalID, owner: owner, to: .ready, reason: "eligible", now: now)
        try restarted.transitionIntention(goalID, owner: owner, to: .executing, reason: "admitted", now: now)
        let output = CompanionOutputReceipt(characterId: owner, topicId: UUID().uuidString, modality: .bubble, text: "A movie thought", relatedIntentionIds: [goalID], createdAt: now)
        try restarted.saveOutputCandidate(output)
        try check(refuses { try restarted.acknowledgeOutput(output.id, owner: owner, status: .presented, now: now) }, "Output cannot skip admission and queue acknowledgment")
        try restarted.acknowledgeOutput(output.id, owner: owner, status: .admitted, now: now)
        try restarted.acknowledgeOutput(output.id, owner: owner, status: .queued, now: now)
        try check(try restarted.intentions(owner: owner).first?.state == .executing, "Queueing a bubble does not claim that it was presented")
        try restarted.acknowledgeOutput(output.id, owner: owner, status: .presented, now: now)
        try restarted.acknowledgeOutput(output.id, owner: owner, status: .presented, now: now)
        try check(try restarted.intentions(owner: owner, includeTerminal: true).first?.state == .completed, "Actual presentation completes an expression once, even with duplicate receipts")

        try restarted.pruneProactive(now: now.addingTimeInterval(10 * 86400))
        try check(try restarted.proactiveReplay().isEmpty && restarted.rows("SELECT id FROM perception_events").isEmpty, "Pruning bounds short-lived event and decision retention")
        try check(try restarted.rows("PRAGMA integrity_check").first?["integrity_check"] as? String == "ok", "Additive proactive schema retains SQLite integrity")
    }
}
