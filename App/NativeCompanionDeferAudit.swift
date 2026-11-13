import Foundation

enum CompanionDeferAudit {
    static let rawRetentionSeconds: Double = 3600
    static let rawLimit = 512
    static let summaryLimit = 2048
}

extension NativeCompanionStore {
    // No opportunity IDs, goals, source content or score snapshots enter rollups.
    func accumulateDeferredDecision(_ decision: CompanionDecisionRecord, count: Int = 1) throws {
        let last = decision.lastEvaluatedAt ?? decision.decidedAt
        let bucket = floor(last.timeIntervalSince1970 / 3600) * 3600
        let reasons = try CompanionProactiveCoding.encode(Array(Set(decision.reasonCodes)).sorted())
        let key = NativeCompanionData.hash([decision.characterId, decision.mode.rawValue, decision.policyRevision, String(Int64(bucket)), reasons].joined(separator: "\0"))
        try execute("""
            INSERT INTO proactive_defer_summaries(id,owner,mode,policy_revision,bucket,reasons,sample_count,first_at,last_at)
            VALUES (?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET
            sample_count=MIN(2147483647,proactive_defer_summaries.sample_count+excluded.sample_count),
            first_at=MIN(proactive_defer_summaries.first_at,excluded.first_at),last_at=MAX(proactive_defer_summaries.last_at,excluded.last_at)
            """, [key, decision.characterId, decision.mode.rawValue, decision.policyRevision, bucket, reasons, min(2147483647, max(1, count)), decision.decidedAt.timeIntervalSince1970, last.timeIntervalSince1970])
    }
    func pruneDeferredAudit(now: Date, retentionHours: Int) throws {
        try execute("DELETE FROM proactive_decisions WHERE json_extract(payload,'$.action')='defer' AND at<?", [now.timeIntervalSince1970 - CompanionDeferAudit.rawRetentionSeconds])
        try execute("DELETE FROM proactive_decisions WHERE id IN (SELECT id FROM proactive_decisions WHERE json_extract(payload,'$.action')='defer' ORDER BY at DESC,rowid DESC LIMIT -1 OFFSET ?)", [CompanionDeferAudit.rawLimit])
        try execute("DELETE FROM proactive_defer_summaries WHERE last_at<?", [now.timeIntervalSince1970 - Double(min(168, max(1, retentionHours))) * 3600])
        try trimDeferredSummaries()
    }
    func trimDeferredSummaries() throws {
        try execute("DELETE FROM proactive_defer_summaries WHERE id IN (SELECT id FROM proactive_defer_summaries ORDER BY last_at DESC,id DESC LIMIT -1 OFFSET ?)", [CompanionDeferAudit.summaryLimit])
    }
    func migrateDeferredAudit(now: Date = Date()) throws {
        guard try rows("SELECT value FROM proactive_metadata WHERE key='defer_audit'").first?["value"] as? String != "hourly-v1" else { return }
        try transaction {
            // Another connection may have completed migration while BEGIN waited.
            guard try rows("SELECT value FROM proactive_metadata WHERE key='defer_audit'").first?["value"] as? String != "hourly-v1" else { return }
            for row in try rows("SELECT payload FROM proactive_decisions WHERE json_extract(payload,'$.action')='defer' ORDER BY at,rowid") {
                let decision = try CompanionProactiveCoding.decode(CompanionDecisionRecord.self, row["payload"] as! String)
                try accumulateDeferredDecision(decision, count: decision.evaluationCount ?? 1)
            }
            try pruneDeferredAudit(now: now, retentionHours: 168)
            try execute("INSERT OR REPLACE INTO proactive_metadata VALUES ('defer_audit','hourly-v1')")
        }
    }
}
