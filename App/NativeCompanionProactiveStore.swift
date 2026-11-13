import Foundation

extension NativeCompanionStore {
    func proactiveSchema() throws {
        for sql in [
            "CREATE TABLE IF NOT EXISTS perception_sources(source TEXT PRIMARY KEY,epoch INTEGER NOT NULL,enabled INTEGER NOT NULL,policy TEXT NOT NULL)",
            "CREATE TABLE IF NOT EXISTS perception_events(id TEXT PRIMARY KEY,source TEXT NOT NULL,source_key TEXT NOT NULL,revision INTEGER NOT NULL,epoch INTEGER NOT NULL,expires_at REAL NOT NULL,purge_at REAL NOT NULL,policy TEXT NOT NULL,payload TEXT,UNIQUE(source,source_key))",
            "CREATE INDEX IF NOT EXISTS perception_events_expiry ON perception_events(purge_at)",
            "CREATE TABLE IF NOT EXISTS proactive_opportunities(id TEXT PRIMARY KEY,owner TEXT NOT NULL,topic_key TEXT NOT NULL,state TEXT NOT NULL,expires_at REAL NOT NULL,payload TEXT NOT NULL)",
            "CREATE UNIQUE INDEX IF NOT EXISTS proactive_opportunity_active ON proactive_opportunities(owner,topic_key) WHERE state IN ('pending','ready','deferred')",
            "CREATE TABLE IF NOT EXISTS proactive_intentions(id TEXT PRIMARY KEY,owner TEXT NOT NULL,topic_key TEXT NOT NULL,state TEXT NOT NULL,expires_at REAL NOT NULL,revision INTEGER NOT NULL,payload TEXT NOT NULL)",
            "CREATE UNIQUE INDEX IF NOT EXISTS proactive_intention_active ON proactive_intentions(owner,topic_key) WHERE state IN ('proposed','pending','ready','executing','deferred','needsReview')",
            "CREATE TABLE IF NOT EXISTS proactive_dependencies(kind TEXT NOT NULL,id TEXT NOT NULL,source_kind TEXT NOT NULL,source_id TEXT NOT NULL,PRIMARY KEY(kind,id,source_kind,source_id))",
            "CREATE TABLE IF NOT EXISTS proactive_decisions(id TEXT PRIMARY KEY,subject_id TEXT NOT NULL,at REAL NOT NULL,payload TEXT NOT NULL)",
            "CREATE INDEX IF NOT EXISTS proactive_decisions_at ON proactive_decisions(at)",
            "CREATE INDEX IF NOT EXISTS proactive_decisions_subject_at ON proactive_decisions(subject_id,at)",
            "CREATE INDEX IF NOT EXISTS proactive_decisions_action_at ON proactive_decisions(json_extract(payload,'$.action'),at)",
            "CREATE TABLE IF NOT EXISTS proactive_defer_summaries(id TEXT PRIMARY KEY,owner TEXT NOT NULL,mode TEXT NOT NULL,policy_revision TEXT NOT NULL,bucket REAL NOT NULL,reasons TEXT NOT NULL,sample_count INTEGER NOT NULL,first_at REAL NOT NULL,last_at REAL NOT NULL)",
            "CREATE INDEX IF NOT EXISTS proactive_defer_summaries_last ON proactive_defer_summaries(last_at)",
            "CREATE TABLE IF NOT EXISTS proactive_outputs(id TEXT PRIMARY KEY,owner TEXT NOT NULL,status TEXT NOT NULL,at REAL NOT NULL,payload TEXT NOT NULL)",
            "CREATE TABLE IF NOT EXISTS perception_cursors(source TEXT PRIMARY KEY,generation TEXT NOT NULL,cursor TEXT NOT NULL,epoch INTEGER NOT NULL)",
            "CREATE TABLE IF NOT EXISTS proactive_loop_intentions(memory_id TEXT PRIMARY KEY,owner TEXT NOT NULL,intention_id TEXT NOT NULL UNIQUE)",
            "CREATE TABLE IF NOT EXISTS proactive_metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL)",
            "INSERT OR IGNORE INTO proactive_metadata VALUES ('schema','1')"
        ] { try execute(sql) }
        try migrateDeferredAudit()
        // In-flight execution cannot be called complete after an unclean shutdown.
        for row in try rows("SELECT payload FROM proactive_intentions WHERE state='executing'") {
            var intention = try CompanionProactiveCoding.decode(CompanionIntention.self, row["payload"] as! String)
            intention.state = .needsReview; intention.lastDecisionReason = "execution_unknown_after_restart"
            try execute("UPDATE proactive_intentions SET state=?,revision=revision+1,payload=? WHERE id=?", [intention.state.rawValue, try CompanionProactiveCoding.encode(intention), intention.id])
        }
    }

    func perceptionPolicy(_ source: String) throws -> CompanionPerceptionPolicy? {
        guard let text = try rows("SELECT policy FROM perception_sources WHERE source=? AND enabled=1", [source]).first?["policy"] as? String else { return nil }
        return try CompanionProactiveCoding.decode(CompanionPerceptionPolicy.self, text)
    }
    // Every change increments the persisted epoch, including off→on. An old async callback never regains access.
    @discardableResult func setPerceptionConsent(source: String, enabled: Bool, policy: CompanionPerceptionPolicy) throws -> CompanionPerceptionPolicy {
        try transaction {
            try CompanionProactiveCoding.require(CompanionProactiveCoding.bounded(source, bytes: 100), "Invalid perception source")
            let previous = try rows("SELECT epoch,enabled,policy FROM perception_sources WHERE source=?", [source]).first
            if let previous, (previous["enabled"] as? Int == 1) == enabled,
               let encoded = previous["policy"] as? String, var old = try? CompanionProactiveCoding.decode(CompanionPerceptionPolicy.self, encoded) {
                old.consentEpoch = policy.consentEpoch
                if old == policy { var result = policy; result.consentEpoch = previous["epoch"] as! Int; return result }
            }
            var next = policy; next.consentEpoch = (previous?["epoch"] as? Int ?? 0) + 1; try next.validate()
            try execute("INSERT OR REPLACE INTO perception_sources VALUES (?,?,?,?)", [source, next.consentEpoch, enabled ? 1 : 0, try CompanionProactiveCoding.encode(next)])
            try invalidatePerceptionSource(source)
            return next
        }
    }
    func invalidatePerceptionSource(_ source: String) throws {
        try invalidateProactiveDependency(kind: "source", id: source, reason: "source_revoked")
        let events = try rows("SELECT id FROM perception_events WHERE source=?", [source]).compactMap { $0["id"] as? String }
        for event in events { try invalidateProactiveDependency(kind: "event", id: event, reason: "source_revoked") }
        try execute("DELETE FROM notification_versions WHERE source=?", [source])
        try execute("DELETE FROM perception_events WHERE source=?", [source]); try execute("DELETE FROM perception_cursors WHERE source=?", [source])
    }
    // `retentionSeconds=0`: persist only opaque dedupe identity, never the observation body.
    @discardableResult func ingestPerception(_ event: CompanionObservation, now: Date = Date()) throws -> String? {
        try transaction {
            try event.validate()
            guard let granted = try perceptionPolicy(event.source), granted == event.policy, event.expiresAt > now else { return nil }
            let old = try rows("SELECT id,revision FROM perception_events WHERE source=? AND source_key=?", [event.source, NativeCompanionData.hash(event.id)]).first
            if let revision = old?["revision"] as? Int, revision >= event.revision { return nil }
            let id = old?["id"] as? String ?? UUID().uuidString
            if old != nil { try invalidateProactiveDependency(kind: "event", id: id, reason: "event_revised") }
            let payload: String? = event.retentionSeconds > 0 ? try CompanionProactiveCoding.encode(event) : nil
            try execute("INSERT OR REPLACE INTO perception_events VALUES (?,?,?,?,?,?,?,?,?)", [id, event.source, NativeCompanionData.hash(event.id), event.revision, event.policy.consentEpoch, event.expiresAt.timeIntervalSince1970, now.addingTimeInterval(Double(max(3600, event.retentionSeconds))).timeIntervalSince1970, try CompanionProactiveCoding.encode(event.policy), payload])
            // Dedupe bounds are enforced even if a source produces unbounded stable IDs.
            try execute("DELETE FROM perception_events WHERE id IN (SELECT id FROM perception_events WHERE source=? ORDER BY rowid DESC LIMIT -1 OFFSET 2048)", [event.source])
            return id
        }
    }
    func savePerceptionCursor(source: String, generation: String, cursor: String, epoch: Int) throws {
        try transaction {
            guard try perceptionPolicy(source)?.consentEpoch == epoch else { throw NativeCompanionData.error("Perception consent changed") }
            try CompanionProactiveCoding.require(generation.utf8.count <= 256 && cursor.utf8.count <= 8192, "Cursor too large")
            try execute("INSERT OR REPLACE INTO perception_cursors VALUES (?,?,?,?)", [source, generation, cursor, epoch])
        }
    }
    @discardableResult func saveOpportunity(_ opportunity: CompanionOpportunity, now: Date = Date()) throws -> String {
        try transaction {
            try opportunity.validate()
            try CompanionProactiveCoding.require(opportunity.expiresAt > now, "Expired opportunity")
            if let existing = try rows("SELECT id FROM proactive_opportunities WHERE owner=? AND topic_key=? AND state IN ('pending','ready','deferred') AND expires_at>?", [opportunity.ownerCharacterId, opportunity.topicKey, now.timeIntervalSince1970]).first?["id"] as? String { return existing }
            try execute("UPDATE proactive_opportunities SET state='expired' WHERE owner=? AND topic_key=? AND expires_at<=?", [opportunity.ownerCharacterId, opportunity.topicKey, now.timeIntervalSince1970])
            for id in opportunity.sourceEventIds {
                guard let row = try rows("SELECT policy FROM perception_events WHERE id=? AND expires_at>?", [id, now.timeIntervalSince1970]).first,
                      let text = row["policy"] as? String else { throw NativeCompanionData.error("Opportunity source expired or missing") }
                let policy = try CompanionProactiveCoding.decode(CompanionPerceptionPolicy.self, text)
                try CompanionProactiveCoding.require(policy.permits(opportunity.ownerCharacterId, use: .attention), "Opportunity source is not authorized for this character")
            }
            try execute("INSERT INTO proactive_opportunities VALUES (?,?,?,?,?,?)", [opportunity.id, opportunity.ownerCharacterId, opportunity.topicKey, opportunity.state.rawValue, opportunity.expiresAt.timeIntervalSince1970, try CompanionProactiveCoding.encode(opportunity)])
            for id in opportunity.sourceEventIds {
                try proactiveDependency(kind: "opportunity", id: opportunity.id, sourceKind: "event", sourceID: id)
                if let source = try rows("SELECT source FROM perception_events WHERE id=?", [id]).first?["source"] as? String { try proactiveDependency(kind: "opportunity", id: opportunity.id, sourceKind: "source", sourceID: source) }
            }
            return opportunity.id
        }
    }
    func verifyIntentionEvidence(owner: String, ids: [String]) throws {
        for id in Set(ids) {
            if id.hasPrefix("dialogue:") || id.hasPrefix("delivery:") {
                let item = try monitorReference(owner: owner, id: id)
                try CompanionProactiveCoding.require(["experienced", "told_by_other"].contains(item.source) && !item.content.isEmpty, "Intention evidence is unavailable")
            } else {
                let evidence = try verifiedEvidence(owner: owner, ids: [id])
                try CompanionProactiveCoding.require(evidence.allSatisfy { $0["provenance"] as? String != "observed" }, "Observed work cannot create a lasting goal")
            }
        }
    }
    // Only the host may acknowledge presentation. Role MCP will never expose this method.
    func saveOutputCandidate(_ output: CompanionOutputReceipt) throws {
        try transaction {
            let c = CompanionProactiveCoding.self
            try c.require(NativeCompanionData.validID(output.id) && NativeCompanionData.validID(output.characterId) && NativeCompanionData.validID(output.topicId), "Invalid output identity")
            try c.require(output.status == .candidate && c.bounded(output.text, bytes: 2400) && output.relatedIntentionIds.count <= 3, "Invalid output candidate")
            for id in output.relatedIntentionIds {
                try c.require(try rows("SELECT id FROM proactive_intentions WHERE id=? AND owner=? AND state='executing'", [id, output.characterId]).first != nil, "Output intention is not executing")
                try proactiveDependency(kind: "output", id: output.id, sourceKind: "intention", sourceID: id)
            }
            try execute("INSERT INTO proactive_outputs VALUES (?,?,?,?,?)", [output.id, output.characterId, output.status.rawValue, output.createdAt.timeIntervalSince1970, try CompanionProactiveCoding.encode(output)])
        }
    }
    func acknowledgeOutput(_ id: String, owner: String, status: CompanionOutputStatus, reason: String? = nil, now: Date = Date()) throws {
        try transaction {
            guard let row = try rows("SELECT payload FROM proactive_outputs WHERE id=? AND owner=?", [id, owner]).first else { throw NativeCompanionData.error("Output not found") }
            var value = try CompanionProactiveCoding.decode(CompanionOutputReceipt.self, row["payload"] as! String)
            let transitions: [CompanionOutputStatus: [CompanionOutputStatus]] = [
                .candidate: [.admitted, .cancelled, .failed], .admitted: [.queued, .cancelled, .failed],
                .queued: [.presented, .cancelled, .failed, .deliveryUnknown], .presented: [.completed, .dismissed]]
            if value.status == status || [.completed, .cancelled, .failed, .dismissed].contains(value.status) { return } // duplicate/late host receipt is harmless
            try CompanionProactiveCoding.require(transitions[value.status]?.contains(status) == true, "Invalid output transition")
            if value.modality == .socialMessage && status == .completed { return } // UI completion is not peer consumption.
            value.status = status; value.failureReason = reason.map { String($0.prefix(100)) }
            if status == .presented { value.presentedAt = now; try recordCognitiveExpression(value, now: now) }
            if status == .completed { value.completedAt = now }
            try execute("UPDATE proactive_outputs SET status=?,payload=? WHERE id=?", [status.rawValue, try CompanionProactiveCoding.encode(value), id])
            for intentionID in value.relatedIntentionIds {
                guard try intentions(owner: owner).contains(where: { $0.id == intentionID && $0.state == .executing }) else { continue }
                if status == .presented && value.modality == .bubble {
                    try transitionIntention(intentionID, owner: owner, to: .completed, reason: "presented", now: now)
                } else if [.cancelled, .failed].contains(status) {
                    try transitionIntention(intentionID, owner: owner, to: .deferred, reason: reason ?? status.rawValue, now: now)
                } else if status == .deliveryUnknown {
                    try transitionIntention(intentionID, owner: owner, to: .needsReview, reason: "delivery_unknown", now: now)
                }
            }
        }
    }
    func proactiveDependency(kind: String, id: String, sourceKind: String, sourceID: String) throws {
        try execute("INSERT OR IGNORE INTO proactive_dependencies VALUES (?,?,?,?)", [kind, id, sourceKind, sourceID])
    }
    @discardableResult func proposeIntention(_ proposed: CompanionIntention, now: Date = Date()) throws -> String {
        try transaction {
            var value = proposed; try value.validate()
            try CompanionProactiveCoding.require(value.state == .pending && value.attemptCount == 0 && value.expiresAt > now, "New intention must be pending")
            // Semantic interpretation may be model-authored; direct evidence must belong to this actor.
            try verifyIntentionEvidence(owner: value.ownerCharacterId, ids: value.evidenceIds)
            if let memory = value.sourceMemoryId {
                try CompanionProactiveCoding.require(try memoryRead(memory, owner: value.ownerCharacterId) != nil, "Missing source memory")
            }
            for row in try rows("SELECT payload FROM proactive_intentions WHERE owner=? AND state='cancelled' AND expires_at>?", [value.ownerCharacterId, now.timeIntervalSince1970]) {
                let old = try CompanionProactiveCoding.decode(CompanionIntention.self, row["payload"] as! String)
                if old.lastDecisionReason == "user_cancelled" && (old.topicKey == value.topicKey || Set(value.evidenceIds).isSubset(of: Set(old.evidenceIds))) {
                    throw NativeCompanionData.error("The user cancelled this future goal; do not recreate it from old evidence")
                }
            }
            let existing = try rows("SELECT id FROM proactive_intentions WHERE owner=? AND topic_key=? AND state IN ('proposed','pending','ready','executing','deferred','needsReview')", [value.ownerCharacterId, value.topicKey]).first?["id"] as? String
            if let existing { return existing }
            try CompanionProactiveCoding.require(try rows("SELECT id FROM proactive_intentions WHERE owner=? AND state IN ('pending','ready','executing','deferred','needsReview')", [value.ownerCharacterId]).count < 32, "Intention queue full")
            value.createdAt = now; value.updatedAt = now
            try execute("INSERT INTO proactive_intentions VALUES (?,?,?,?,?,1,?)", [value.id, value.ownerCharacterId, value.topicKey, value.state.rawValue, value.expiresAt.timeIntervalSince1970, try CompanionProactiveCoding.encode(value)])
            for evidence in value.evidenceIds { try proactiveDependency(kind: "intention", id: value.id, sourceKind: "evidence", sourceID: evidence) }
            if let memory = value.sourceMemoryId { try proactiveDependency(kind: "intention", id: value.id, sourceKind: "memory", sourceID: memory) }
            for event in value.relatedEventIds { try proactiveDependency(kind: "intention", id: value.id, sourceKind: "event", sourceID: event) }
            return value.id
        }
    }
    func intentions(owner: String, includeTerminal: Bool = false) throws -> [CompanionIntention] {
        try rows("SELECT payload,state FROM proactive_intentions WHERE owner=? ORDER BY rowid DESC LIMIT 100", [owner]).compactMap { row in
            var value = try CompanionProactiveCoding.decode(CompanionIntention.self, row["payload"] as! String)
            value.state = CompanionIntentionState(rawValue: row["state"] as! String)!
            return includeTerminal || !value.state.terminal ? value : nil
        }
    }
    func transitionIntention(_ id: String, owner: String, to state: CompanionIntentionState, reason: String, now: Date = Date(), cooldown: TimeInterval = 180) throws {
        try transaction {
            guard let row = try rows("SELECT * FROM proactive_intentions WHERE id=? AND owner=?", [id, owner]).first else { throw NativeCompanionData.error("Intention not found") }
            var value = try CompanionProactiveCoding.decode(CompanionIntention.self, row["payload"] as! String)
            value.state = CompanionIntentionState(rawValue: row["state"] as! String)!
            try CompanionProactiveCoding.require(value.state.canTransition(to: state), "Invalid intention transition")
            if [.ready, .executing].contains(state) {
                try CompanionProactiveCoding.require(value.expiresAt > now && (value.notBefore ?? .distantPast) <= now && (value.cooldownUntil ?? .distantPast) <= now && value.attemptCount < value.maxAttempts, "Intention not eligible")
            }
            if state == .executing { value.attemptCount += 1 }
            if state == .deferred { value.cooldownUntil = now.addingTimeInterval(max(1, cooldown)) }
            value.state = state; value.lastDecisionReason = String(reason.prefix(100)); value.updatedAt = now
            if state == .deferred && value.attemptCount >= value.maxAttempts { value.state = .failed; value.lastDecisionReason = "attempt_limit" }
            if state == .completed { value.completedAt = now }
            try execute("UPDATE proactive_intentions SET state=?,revision=revision+1,payload=? WHERE id=?", [value.state.rawValue, try CompanionProactiveCoding.encode(value), id])
        }
    }
    func recordDecision(_ decision: CompanionDecisionRecord) throws {
        try transaction {
            if decision.action == "defer" {
                try accumulateDeferredDecision(decision)
                try trimDeferredSummaries()
            }
            if decision.action == "defer",
               let text = try rows("SELECT payload FROM proactive_decisions WHERE subject_id=? ORDER BY at DESC,rowid DESC LIMIT 1", [decision.subjectId]).first?["payload"] as? String,
               var previous = try? CompanionProactiveCoding.decode(CompanionDecisionRecord.self, text),
               previous.action == decision.action, previous.mode == decision.mode,
               previous.characterId == decision.characterId, previous.reasonCodes == decision.reasonCodes,
               previous.scores == decision.scores, previous.selectedModality == decision.selectedModality,
               previous.policyRevision == decision.policyRevision,
               decision.decidedAt >= (previous.lastEvaluatedAt ?? previous.decidedAt) {
                previous.lastEvaluatedAt = decision.decidedAt
                previous.evaluationCount = min(Int.max - 1, previous.evaluationCount ?? 1) + 1
                try execute("UPDATE proactive_decisions SET at=?,payload=? WHERE id=?", [decision.decidedAt.timeIntervalSince1970, try CompanionProactiveCoding.encode(previous), previous.id])
                return
            }
            try execute("INSERT INTO proactive_decisions VALUES (?,?,?,?)", [decision.id, decision.subjectId, decision.decidedAt.timeIntervalSince1970, try CompanionProactiveCoding.encode(decision)])
            if decision.action == "defer" {
                try execute("DELETE FROM proactive_decisions WHERE id IN (SELECT id FROM proactive_decisions WHERE json_extract(payload,'$.action')='defer' ORDER BY at DESC,rowid DESC LIMIT -1 OFFSET ?)", [CompanionDeferAudit.rawLimit])
            }
            try execute("DELETE FROM proactive_decisions WHERE id IN (SELECT id FROM proactive_decisions ORDER BY at DESC LIMIT -1 OFFSET 10000)")
        }
    }
    func proactiveReplay(limit: Int = 100) throws -> [CompanionDecisionRecord] {
        try rows("SELECT payload FROM proactive_decisions ORDER BY at DESC,rowid DESC LIMIT ?", [max(1, min(limit, 1000))]).map { try CompanionProactiveCoding.decode(CompanionDecisionRecord.self, $0["payload"] as! String) }
    }
    func invalidateProactiveDependency(kind: String, id: String, reason: String) throws {
        for row in try rows("SELECT kind,id FROM proactive_dependencies WHERE source_kind=? AND source_id=?", [kind, id]) {
            let target = row["id"] as! String
            if row["kind"] as? String == "opportunity" {
                try invalidateProactiveDependency(kind: "opportunity", id: target, reason: reason)
                try execute("UPDATE proactive_opportunities SET state='cancelled',payload='{}' WHERE id=?", [target])
            } else if row["kind"] as? String == "intention" {
                // Erase goal text as well: forgotten evidence must not survive as a pending goal.
                if let saved = try rows("SELECT owner FROM proactive_intentions WHERE id=?", [target]).first {
                    try invalidateProactiveDependency(kind: "intention", id: target, reason: reason)
                    try execute("DELETE FROM proactive_intentions WHERE id=?", [target])
                    try audit(owner: saved["owner"] as? String ?? "", operation: "intention.invalidated", target: target, actor: "controller", result: reason)
                }
            } else if row["kind"] as? String == "output" {
                try execute("DELETE FROM proactive_outputs WHERE id=?", [target])
            }
            try execute("DELETE FROM proactive_dependencies WHERE kind=? AND id=?", [row["kind"], target])
        }
    }
    func pruneProactive(now: Date = Date(), auditRetentionHours: Int = 168) throws {
        try transaction {
            let time = now.timeIntervalSince1970
            for row in try rows("SELECT id,owner FROM proactive_outputs WHERE status IN ('candidate','admitted','queued') AND at<?", [time - 120]) {
                try acknowledgeOutput(row["id"] as! String, owner: row["owner"] as! String, status: .failed, reason: "presentation_timeout", now: now)
            }
            try execute("UPDATE proactive_opportunities SET state='expired' WHERE expires_at<=? AND state IN ('pending','ready','deferred')", [time])
            try execute("UPDATE proactive_intentions SET state='expired' WHERE expires_at<=? AND state IN ('pending','ready','deferred','needsReview')", [time])
            try execute("DELETE FROM perception_events WHERE purge_at<=?", [time])
            try execute("DELETE FROM proactive_decisions WHERE at<?", [time - Double(min(168, max(1, auditRetentionHours))) * 3600])
            try pruneDeferredAudit(now: now, retentionHours: auditRetentionHours)
            try execute("DELETE FROM proactive_outputs WHERE at<? AND status IN ('completed','dismissed','cancelled','failed','deliveryUnknown','presented')", [time - 30 * 86400])
            try execute("DELETE FROM proactive_opportunities WHERE expires_at<?", [time - 86400])
            try execute("DELETE FROM proactive_intentions WHERE expires_at<? AND state IN ('completed','expired','cancelled','failed')", [time - 30 * 86400])
            try execute("DELETE FROM proactive_dependencies WHERE (kind='opportunity' AND id NOT IN (SELECT id FROM proactive_opportunities)) OR (kind='intention' AND id NOT IN (SELECT id FROM proactive_intentions)) OR (kind='output' AND id NOT IN (SELECT id FROM proactive_outputs))")
        }
    }
}
