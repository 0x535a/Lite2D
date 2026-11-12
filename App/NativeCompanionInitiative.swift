import Foundation

extension NativeCompanionStore {
    func opportunities(owners: [String], now: Date = Date()) throws -> [CompanionOpportunity] {
        guard !owners.isEmpty else { return [] }
        let placeholders = owners.map { _ in "?" }.joined(separator: ",")
        return try rows("SELECT payload,state FROM proactive_opportunities WHERE owner IN (\(placeholders)) AND state IN ('pending','ready','deferred') AND expires_at>? ORDER BY rowid LIMIT 256", owners.map { $0 as Any? } + [now.timeIntervalSince1970]).compactMap { row in
            guard let payload = row["payload"] as? String, var value = try? CompanionProactiveCoding.decode(CompanionOpportunity.self, payload) else { return nil }
            value.state = CompanionOpportunityState(rawValue: row["state"] as? String ?? "") ?? .cancelled
            return value
        }
    }
    func opportunityAuthorized(_ opportunity: CompanionOpportunity, now: Date = Date(), forExpression: Bool = false) throws -> Bool {
        for id in opportunity.sourceEventIds {
            guard let row = try rows("SELECT source,epoch,expires_at FROM perception_events WHERE id=?", [id]).first,
                  (row["expires_at"] as? Double ?? 0) > now.timeIntervalSince1970,
                  let source = row["source"] as? String, let policy = try perceptionPolicy(source),
                  policy.consentEpoch == row["epoch"] as? Int,
                  policy.permits(opportunity.ownerCharacterId, use: forExpression ? .expression : .attention, remote: forExpression) else { return false }
        }
        for id in opportunity.relatedIntentionIds {
            guard let value = try intentions(owner: opportunity.ownerCharacterId).first(where: { $0.id == id }), value.state != .needsReview,
                  !value.state.terminal, value.expiresAt > now, value.attemptCount < value.maxAttempts || value.state == .executing else { return false }
            if forExpression {
                guard (try? verifyIntentionEvidence(owner: value.ownerCharacterId, ids: value.evidenceIds)) != nil else { return false }
                if let memory = value.sourceMemoryId, try memoryRead(memory, owner: value.ownerCharacterId) == nil { return false }
            }
        }
        return true
    }
    func claimOpportunity(_ opportunity: CompanionOpportunity, now: Date = Date()) throws -> Bool {
        try transaction {
            guard opportunity.expiresAt > now, try opportunityAuthorized(opportunity, now: now, forExpression: true),
                  try rows("SELECT id FROM proactive_opportunities WHERE id=? AND state IN ('pending','ready','deferred')", [opportunity.id]).first != nil else { return false }
            // Same external event is heard once, even when several characters proposed reacting.
            try execute("UPDATE proactive_opportunities SET state=CASE WHEN id=? THEN 'consumed' ELSE 'cancelled' END WHERE topic_key=? AND state IN ('pending','ready','deferred')", [opportunity.id, opportunity.topicKey])
            return true
        }
    }
    func finishSocialDelivery(_ delivery: String, now: Date = Date()) throws {
        try transaction {
            guard try rows("SELECT id FROM deliveries WHERE id=? AND status IN ('delivered','context_consumed')", [delivery]).first != nil else { throw NativeCompanionData.error("Peer delivery is not confirmed") }
            for row in try rows("SELECT id,owner,payload FROM proactive_outputs WHERE json_extract(payload,'$.deliveryId')=? AND status IN ('queued','presented')", [delivery]) {
                var value = try CompanionProactiveCoding.decode(CompanionOutputReceipt.self, row["payload"] as! String)
                value.status = .completed; value.completedAt = now
                for id in value.relatedIntentionIds {
                    if try intentions(owner: value.characterId).contains(where: { $0.id == id && $0.state == .executing }) {
                        try transitionIntention(id, owner: value.characterId, to: .completed, reason: "delivered", now: now)
                    }
                }
                try execute("UPDATE proactive_outputs SET status='completed',payload=? WHERE id=?", [try CompanionProactiveCoding.encode(value), value.id])
            }
        }
    }
    func settleUndeliveredSocialOutputs(_ topic: String) throws {
        try transaction {
            for row in try rows("SELECT o.payload,d.status AS delivery_status FROM proactive_outputs o LEFT JOIN deliveries d ON d.id=json_extract(o.payload,'$.deliveryId') WHERE json_extract(o.payload,'$.topicId')=? AND json_extract(o.payload,'$.modality')='socialMessage' AND o.status NOT IN ('completed','failed')", [topic]) {
                var value = try CompanionProactiveCoding.decode(CompanionOutputReceipt.self, row["payload"] as! String)
                let status = row["delivery_status"] as? String ?? "delivery_unknown"
                guard !["delivered", "context_consumed"].contains(status) else { continue }
                let uncertain = ["delivery_unknown", "accepted_pending_context"].contains(status)
                for id in value.relatedIntentionIds {
                    if try intentions(owner: value.characterId).contains(where: { $0.id == id && $0.state == .executing }) {
                        try transitionIntention(id, owner: value.characterId, to: uncertain ? .needsReview : .deferred, reason: status)
                    }
                }
                value.failureReason = status; value.status = uncertain ? .deliveryUnknown : (value.presentedAt == nil ? .cancelled : .dismissed)
                try execute("UPDATE proactive_outputs SET status=?,payload=? WHERE id=?", [value.status.rawValue, try CompanionProactiveCoding.encode(value), value.id])
            }
        }
    }
    func cancelTopicOutputs(_ topic: String, reason: String) throws {
        for row in try rows("SELECT id,owner,status FROM proactive_outputs WHERE json_extract(payload,'$.topicId')=? AND status IN ('candidate','admitted','queued','presented')", [topic]) {
            try acknowledgeOutput(row["id"] as! String, owner: row["owner"] as! String, status: row["status"] as? String == "presented" ? .dismissed : .cancelled, reason: reason)
        }
    }
}
