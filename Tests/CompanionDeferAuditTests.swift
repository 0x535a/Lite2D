import Foundation

enum CompanionDeferAuditTests {
    static func run(root: URL, check: (Bool, String) throws -> Void) throws {
        let owner = "11111111-1111-4111-8111-111111111111", other = "22222222-2222-4222-8222-222222222222"
        let now = Date(), store = try NativeCompanionStore(root: root.appendingPathComponent("defer-rollups"))
        func decision(_ date: Date, owner id: String = owner, action: String = "defer") -> CompanionDecisionRecord {
            CompanionDecisionRecord(mode: .live, subjectId: UUID().uuidString, characterId: id, action: action, reasonCodes: ["user_active"], scores: ["value": 0.8, "cost": 0.2], selectedModality: action == "admit" ? .bubble : .silent, policyRevision: "v2", decidedAt: date)
        }
        try store.transaction {
            for _ in 0...CompanionDeferAudit.rawLimit { try store.recordDecision(decision(now)) }
        }
        try check(try store.rows("SELECT id FROM proactive_decisions").count == CompanionDeferAudit.rawLimit && store.rows("SELECT sample_count FROM proactive_defer_summaries").first?["sample_count"] as? Int == CompanionDeferAudit.rawLimit + 1, "Different deferred opportunities share an hourly reason rollup while raw diagnostics stay bounded")
        let admission = decision(now.addingTimeInterval(-7200), action: "admit")
        try store.recordDecision(admission)
        var query = CompanionMonitorQuery(); query.section = "decisions"
        let normal = try store.monitorPage(query, requestID: "important", owners: [owner, other])
        try check(normal.total == 1 && normal.items.first?.id == admission.id, "The default initiative browser excludes defer diagnostics without hiding admissions")
        query.status = "defer_summary"
        let rollups = try store.monitorPage(query, requestID: "summary", owners: [owner, other])
        try check(rollups.total == 1 && rollups.items.first?.kind == "defer_summary" && rollups.items.first?.links.isEmpty == true, "Deferred summaries expose counters and reasons without private opportunity or goal links")
        query.owner = other
        try check(try store.monitorPage(query, requestID: "other", owners: [owner, other]).total == 0 && store.monitorReference(owner: other, id: rollups.items[0].id, kind: "defer_summary").status == "unavailable", "Summary lists and direct references enforce private character ownership")
        try store.recordDecision(decision(now.addingTimeInterval(-7200)))
        try store.pruneProactive(now: now.addingTimeInterval(3601), auditRetentionHours: 168)
        try check(try store.rows("SELECT id FROM proactive_decisions WHERE json_extract(payload,'$.action')='defer'").isEmpty && store.rows("SELECT id FROM proactive_defer_summaries").count == 2 && store.monitorReference(owner: owner, id: admission.id, kind: "decision").status == "live", "Hourly raw expiry preserves longer-lived aggregates and referenced admission evidence")
        try store.pruneProactive(now: now.addingTimeInterval(169 * 3600), auditRetentionHours: 168)
        try check(try store.rows("SELECT id FROM proactive_defer_summaries").isEmpty, "Deferred rollups expire at the configured audit horizon")
        try store.transaction {
            for index in 0...CompanionDeferAudit.summaryLimit {
                var value = decision(now); value.policyRevision = "fixture-\(index)"
                try store.accumulateDeferredDecision(value)
            }
            try store.trimDeferredSummaries()
        }
        try check(try store.rows("SELECT id FROM proactive_defer_summaries").count == CompanionDeferAudit.summaryLimit, "The summary cap remains bounded even with many reason-policy groups")
        try store.clearConversationHistory()
        try check(try store.rows("SELECT id FROM proactive_defer_summaries").isEmpty, "Clearing history also removes its deferred summaries")

        let legacyRoot = root.appendingPathComponent("legacy-defer-migration"), legacy = try NativeCompanionStore(root: legacyRoot)
        try legacy.execute("DELETE FROM proactive_metadata WHERE key='defer_audit'")
        var old = decision(now.addingTimeInterval(-10800)); old.lastEvaluatedAt = now.addingTimeInterval(-7200); old.evaluationCount = 7
        try legacy.execute("INSERT INTO proactive_decisions VALUES (?,?,?,?)", [old.id, old.subjectId, old.lastEvaluatedAt!.timeIntervalSince1970, try CompanionProactiveCoding.encode(old)])
        try legacy.recordDecision(admission)
        let migrated = try NativeCompanionStore(root: legacyRoot)
        try check(try migrated.rows("SELECT sample_count FROM proactive_defer_summaries").first?["sample_count"] as? Int == 7 && migrated.rows("SELECT id FROM proactive_decisions WHERE json_extract(payload,'$.action')='defer'").isEmpty && migrated.rows("SELECT id FROM proactive_decisions WHERE id=?", [admission.id]).count == 1, "Legacy defer records are summarized before age cleanup while admissions survive migration")
        let again = try NativeCompanionStore(root: legacyRoot)
        try check(try again.rows("SELECT sample_count FROM proactive_defer_summaries").first?["sample_count"] as? Int == 7 && again.rows("PRAGMA integrity_check").first?["integrity_check"] as? String == "ok", "Deferred migration is transactional, idempotent and keeps database integrity")
    }
}
