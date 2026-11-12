import Foundation

extension NativeCompanionStore {
    func recentRoleDialogue(owner: String, limit: Int = 4) throws -> [CompanionObject] {
        let cutoff = get("memoryCutoff:\(owner)") as? String ?? ""
        var result: [CompanionObject] = []
        for row in try rows("SELECT e.seq,e.at,e.payload FROM events e LEFT JOIN proactive_outputs o ON o.id=json_extract(e.payload,'$.outputId') WHERE e.type='utterance' AND json_extract(e.payload,'$.characterId')=? AND e.at>=? AND (json_extract(e.payload,'$.outputId') IS NULL OR (json_extract(o.payload,'$.presentedAt') IS NOT NULL OR (json_extract(o.payload,'$.modality')='socialMessage' AND o.status='completed'))) ORDER BY e.seq DESC LIMIT ?", [owner, cutoff, min(limit, 16)]) {
            let data = NativeCompanionData.object(try NativeCompanionData.decode(Data((row["payload"] as! String).utf8)))
            result.append(["id": "dialogue:\(row["seq"]!)", "at": row["at"]!, "from": owner, "text": data["text"] ?? "", "source": "said_by_self"])
        }
        for row in try rows("SELECT d.id,r.received_at,d.sender,d.text FROM deliveries d JOIN daily_receipts r ON d.id=r.delivery_id WHERE d.recipient=? AND d.status IN ('delivered','context_consumed') AND r.received_at>=? ORDER BY r.received_at DESC LIMIT ?", [owner, cutoff, min(limit, 16)]) {
            result.append(["id": "delivery:\(row["id"]!)", "at": row["received_at"]!, "from": row["sender"]!, "text": row["text"]!, "source": "told_by_other"])
        }
        return Array(result.sorted { ($0["at"] as? String ?? "") < ($1["at"] as? String ?? "") }.suffix(min(limit, 16)))
    }
    func initiativeMemories(owner: String, intentions: [CompanionIntention]) throws -> [CompanionObject] {
        var chosen: [CompanionObject] = []
        for intention in intentions.prefix(3) {
            if let id = intention.sourceMemoryId, let memory = try memoryRead(id, owner: owner) { chosen.append(memory) }
            let words = intention.goal.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }).prefix(3).joined(separator: " ")
            if !words.isEmpty { chosen += try memorySearch(owner: owner, query: words, limit: 4) }
        }
        chosen += try memorySearch(owner: owner, query: "", limit: 20)
        var seen = Set<String>()
        return Array(chosen.filter { row in
            guard let id = row["id"] as? String, seen.insert(id).inserted else { return false }
            return !["observed", "legacy_import"].contains(row["provenance"] as? String ?? "") && row["memory_type"] as? String != "diary"
        }.prefix(8))
    }
    func dailyBackground(owner: String) throws -> [CompanionObject] {
        try initiativeMemories(owner: owner, intentions: []).map { row in
            ["id": row["id"] ?? "", "memory_type": row["memory_type"] ?? "", "provenance": row["provenance"] ?? "inferred",
             "content": String((row["content"] as? String ?? "").prefix(400)), "occurred_at": row["occurred_at"] ?? NSNull()]
        }
    }
    func dailyPendingContext(owner: String) throws -> [CompanionObject] {
        try dailyLoops(owner).prefix(32).map { row in
            ["id": row["id"] ?? "", "content": String((row["content"] as? String ?? "").prefix(400)), "provenance": row["provenance"] ?? "inferred"]
        }
    }
    // Daily open loops keep their memory identity. A terminal follow-up is not recreated every day.
    func syncOpenLoopIntentions(owner: String, now: Date = Date()) throws {
        try transaction {
            for memory in try dailyLoops(owner) {
                guard let memoryID = memory["id"] as? String,
                      try rows("SELECT memory_id FROM proactive_loop_intentions WHERE memory_id=?", [memoryID]).isEmpty else { continue }
                let evidence = evidenceIDs(memory).filter { $0.hasPrefix("dialogue:") || $0.hasPrefix("delivery:") }
                guard !evidence.isEmpty else { continue }
                let date = (memory["created_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } ?? now
                let expiry = date.addingTimeInterval(7 * 86400)
                guard expiry > now else { continue }
                guard (try? verifyIntentionEvidence(owner: owner, ids: evidence)) != nil else { continue }
                if try intentions(owner: owner).count >= 32 { break }
                let value = CompanionIntention(ownerCharacterId: owner, goal: String((memory["content"] as? String ?? "").prefix(300)), origin: .conversationMemory,
                    topicKey: "daily:" + memoryID, sourceMemoryId: memoryID, evidenceIds: Array(evidence.prefix(16)),
                    priority: 0.6, expiresAt: expiry, maxAttempts: 1, createdBy: "daily_open_loop", createdAt: now, updatedAt: now)
                let id = try proposeIntention(value, now: now)
                try execute("INSERT INTO proactive_loop_intentions VALUES (?,?,?)", [memoryID, owner, id])
            }
            for row in try rows("SELECT p.intention_id FROM proactive_loop_intentions p JOIN daily_open_loops l ON l.memory_id=p.memory_id JOIN proactive_intentions i ON i.id=p.intention_id WHERE p.owner=? AND l.status='resolved' AND i.state NOT IN ('completed','cancelled','expired','failed')", [owner]) {
                try transitionIntention(row["intention_id"] as! String, owner: owner, to: .cancelled, reason: "agreement_resolved", now: now)
            }
        }
    }
    func reviewIntentionPersona(owner: String, revision: Int) throws {
        try transaction {
            let key = "intentionPersona:\(owner)"
            if let old = get(key) as? Int, old != revision {
                for intention in try intentions(owner: owner) where !intention.state.terminal && intention.state != .needsReview {
                    try transitionIntention(intention.id, owner: owner, to: .needsReview, reason: "persona_changed")
                }
            }
            try set(key, revision)
        }
    }
}
