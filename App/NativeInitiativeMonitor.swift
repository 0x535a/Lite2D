import Foundation

extension NativeCompanionStore {
    func monitorIntention(_ row: CompanionObject) throws -> CompanionMonitorItem {
        let value = try CompanionProactiveCoding.decode(CompanionIntention.self, row["payload"] as! String)
        let state = CompanionIntentionState(rawValue: row["state"] as? String ?? "") ?? value.state
        var item = CompanionMonitorItem(id: value.id, kind: "intention", owner: value.ownerCharacterId, title: value.goal)
        item.content = value.goal; item.status = state.rawValue; item.source = value.origin.rawValue
        item.at = NativeCompanionData.iso(value.updatedAt); item.version = String(row["revision"] as? Int ?? 0)
        item.fields = [
            .init(key: "priority", value: String(value.priority)), .init(key: "attempt_count", value: String(value.attemptCount)),
            .init(key: "max_attempts", value: String(value.maxAttempts)), .init(key: "expires_at", value: NativeCompanionData.iso(value.expiresAt)),
            .init(key: "not_before", value: value.notBefore.map(NativeCompanionData.iso) ?? ""),
            .init(key: "cooldown_until", value: value.cooldownUntil.map(NativeCompanionData.iso) ?? ""),
            .init(key: "last_decision_reason", value: value.lastDecisionReason), .init(key: "target_character_id", value: value.targetCharacterId ?? "")]
        item.links = value.evidenceIds.map { .init(id: $0) }
        if let id = value.sourceMemoryId { item.links.append(.init(id: id, kind: "memory")) }
        if !state.terminal { item.actions = ["intention_cancel"] }
        if state == .needsReview && value.expiresAt > Date() && value.attemptCount < value.maxAttempts { item.actions.append("intention_resume") }
        return item
    }
    func initiativeMonitorPage(_ query: CompanionMonitorQuery, requestID: String) throws -> CompanionMonitorPage {
        var result = CompanionMonitorPage(requestID: requestID, query: query, items: [], total: 0)
        var args: [Any?] = [], sql: String, order: String
        switch query.section {
        case "cognition":
            if let state = try cognitiveState(owner: query.owner) {
                var item = CompanionMonitorItem(id: "cognition", kind: "cognition", owner: query.owner, title: "cognition")
                item.at = NativeCompanionData.iso(state.updatedAt)
                item.fields = [.init(key: "curiosity", value: String(state.curiosity)), .init(key: "social_interest", value: String(state.socialInterest)), .init(key: "expression_energy", value: String(state.expressionEnergy)), .init(key: "affect", value: state.affect.rawValue)]
                result.items = [item]; result.total = 1
            }
            return result
        case "intentions":
            sql = "SELECT * FROM proactive_intentions WHERE owner=?"; args = [query.owner]; order = "rowid"
            if !query.status.isEmpty { sql += " AND state=?"; args.append(query.status) }
            if !query.search.isEmpty { sql += " AND json_extract(payload,'$.goal') LIKE ?"; args.append("%" + query.search + "%") }
        case "outputs":
            sql = "SELECT * FROM proactive_outputs WHERE owner=?"; args = [query.owner]; order = "at"
            if !query.status.isEmpty { sql += " AND status=?"; args.append(query.status) }
            if !query.search.isEmpty { sql += " AND json_extract(payload,'$.text') LIKE ?"; args.append("%" + query.search + "%") }
        case "decisions":
            if query.status == "defer_summary" {
                sql = "SELECT * FROM proactive_defer_summaries WHERE 1=1"; order = "last_at"
                if !query.owner.isEmpty { sql += " AND owner=?"; args.append(query.owner) }
                if !query.search.isEmpty { sql += " AND reasons LIKE ?"; args.append("%" + query.search + "%") }
                break
            }
            sql = "SELECT * FROM proactive_decisions WHERE 1=1"; order = "at"
            if query.status.isEmpty { sql += " AND json_extract(payload,'$.action')!='defer'" }
            else if ["admit", "cancel", "defer"].contains(query.status) { sql += " AND json_extract(payload,'$.action')=?"; args.append(query.status) }
            else { return result }
            if !query.owner.isEmpty { sql += " AND json_extract(payload,'$.characterId')=?"; args.append(query.owner) }
            if !query.search.isEmpty { sql += " AND payload LIKE ?"; args.append("%" + query.search + "%") }
        default: return result
        }
        result.total = try rows("SELECT COUNT(*) AS n FROM (" + sql + ")", args).first?["n"] as? Int ?? 0
        let direction = query.sort == "oldest" ? "ASC" : "DESC"
        result.items = try rows(sql + " ORDER BY \(order) \(direction),id \(direction) LIMIT ? OFFSET ?", args + [query.pageSize, query.page * query.pageSize]).map { row in
            if query.section == "intentions" { return try monitorIntention(row) }
            if query.section == "outputs" { return try monitorOutput(row) }
            if query.status == "defer_summary" { return try monitorDeferredSummary(row) }
            return try monitorDecision(row)
        }
        return result
    }
    func monitorDeferredSummary(_ row: CompanionObject) throws -> CompanionMonitorItem {
        let reasons = try CompanionProactiveCoding.decode([String].self, row["reasons"] as! String)
        var item = CompanionMonitorItem(id: row["id"] as! String, kind: "defer_summary", owner: row["owner"] as! String, title: "defer_summary")
        item.status = row["mode"] as! String; item.content = reasons.joined(separator: ", ")
        item.at = NativeCompanionData.iso(Date(timeIntervalSince1970: row["last_at"] as! Double))
        item.fields = [.init(key: "evaluation_count", value: String(row["sample_count"] as! Int)),
                       .init(key: "first_decided_at", value: NativeCompanionData.iso(Date(timeIntervalSince1970: row["first_at"] as! Double))),
                       .init(key: "last_evaluated_at", value: item.at), .init(key: "policy_revision", value: row["policy_revision"] as! String)]
        return item
    }
    func monitorOutput(_ row: CompanionObject) throws -> CompanionMonitorItem {
        let value = try CompanionProactiveCoding.decode(CompanionOutputReceipt.self, row["payload"] as! String)
        var item = CompanionMonitorItem(id: value.id, kind: "output", owner: value.characterId, title: value.modality.rawValue)
        item.content = value.text; item.status = row["status"] as? String ?? value.status.rawValue; item.at = NativeCompanionData.iso(value.createdAt)
        item.fields = [.init(key: "topic", value: value.topicId), .init(key: "presented_at", value: value.presentedAt.map(NativeCompanionData.iso) ?? ""),
                       .init(key: "completed_at", value: value.completedAt.map(NativeCompanionData.iso) ?? ""), .init(key: "reason", value: value.failureReason ?? "")]
        item.links = value.relatedIntentionIds.map { .init(id: $0, kind: "intention") }
        if let id = value.decisionId { item.links.append(.init(id: id, kind: "decision")) }
        return item
    }
    func monitorDecision(_ row: CompanionObject) throws -> CompanionMonitorItem {
        let value = try CompanionProactiveCoding.decode(CompanionDecisionRecord.self, row["payload"] as! String)
        var item = CompanionMonitorItem(id: value.id, kind: "decision", owner: value.characterId, title: value.action)
        item.status = value.mode.rawValue; item.at = NativeCompanionData.iso(value.lastEvaluatedAt ?? value.decidedAt)
        item.content = value.reasonCodes.joined(separator: ", ")
        item.fields = value.scores.sorted { $0.key < $1.key }.map { .init(key: $0.key, value: String($0.value)) }
        item.fields += [.init(key: "modality", value: value.selectedModality.rawValue), .init(key: "policy_revision", value: value.policyRevision)]
        if let count = value.evaluationCount {
            item.fields += [.init(key: "evaluation_count", value: String(count)),
                            .init(key: "first_decided_at", value: NativeCompanionData.iso(value.decidedAt)),
                            .init(key: "last_evaluated_at", value: NativeCompanionData.iso(value.lastEvaluatedAt ?? value.decidedAt))]
        }
        item.links = [.init(id: value.subjectId, kind: "opportunity")]
        return item
    }
    func monitorPlanAction(_ id: String) throws -> CompanionMonitorAction? {
        guard let value = try rows("SELECT payload FROM monitor_previews WHERE id=? AND status='preview'", [id]).first?["payload"] as? String else { return nil }
        return try JSONDecoder().decode(CompanionMonitorPlan.self, from: Data(value.utf8)).action
    }
    func resumeIntention(_ id: String, owner: String) throws {
        guard let value = try intentions(owner: owner).first(where: { $0.id == id && $0.state == .needsReview }), value.expiresAt > Date(), value.attemptCount < value.maxAttempts else { throw NativeCompanionData.error("Future goal is expired, exhausted or not awaiting review") }
        try verifyIntentionEvidence(owner: owner, ids: value.evidenceIds)
        try transitionIntention(id, owner: owner, to: .pending, reason: "reviewed_current_evidence")
    }
}
