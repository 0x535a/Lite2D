import Foundation

enum CompanionAffect: String, Codable { case neutral, happy, curious, concerned }
struct CompanionCognitiveState: Codable, Equatable {
    var owner: String
    var curiosity: Double = 0.5
    var socialInterest: Double = 0.35
    var expressionEnergy: Double = 0.45
    var affect: CompanionAffect = .neutral
    var updatedAt: Date
    var lastExpressionAt: Date?
    var lastSocialAt: Date?
    var lastOutputId: String?
    mutating func advance(to now: Date, curiosityPrior: Double = 0.5, sociabilityPrior: Double = 0.5) {
        guard now > updatedAt else { return }
        let elapsed = min(86400, now.timeIntervalSince(updatedAt)), remaining = exp(-elapsed / 1800)
        let curiousBase = min(0.8, max(0.2, curiosityPrior)), socialBase = min(0.6, max(0.15, sociabilityPrior * 0.7))
        curiosity = min(0.8, max(0, curiousBase + (curiosity - curiousBase) * remaining))
        socialInterest = min(0.65, max(0, socialBase + (socialInterest - socialBase) * remaining))
        expressionEnergy = min(0.7, max(0, 0.45 + (expressionEnergy - 0.45) * remaining))
        if let lastExpressionAt, now.timeIntervalSince(lastExpressionAt) >= 1800 { affect = .neutral }
        updatedAt = now
    }
    mutating func expression(output: String, emotion: CompanionAffect, at now: Date) {
        guard lastOutputId != output else { return }
        expressionEnergy = max(0, expressionEnergy - 0.15); curiosity = max(0, curiosity - 0.05)
        affect = emotion; lastExpressionAt = now; lastOutputId = output; updatedAt = max(updatedAt, now)
    }
    mutating func social(at now: Date) { socialInterest = max(0, socialInterest - 0.05); lastSocialAt = now; updatedAt = max(updatedAt, now) }
    var interestPriority: Double { min(0.75, max(0.2, 0.3 + curiosity * 0.15 + expressionEnergy * 0.25)) }
}

extension NativeCompanionStore {
    func cognitionSchema() throws { try execute("CREATE TABLE IF NOT EXISTS cognitive_states(owner TEXT PRIMARY KEY,payload TEXT NOT NULL,updated_at REAL NOT NULL)") }
    func cognitiveState(owner: String) throws -> CompanionCognitiveState? {
        guard let payload = try rows("SELECT payload FROM cognitive_states WHERE owner=?", [owner]).first?["payload"] as? String else { return nil }
        return try CompanionProactiveCoding.decode(CompanionCognitiveState.self, payload)
    }
    @discardableResult func maintainCognition(owner: String, now: Date = Date()) throws -> CompanionCognitiveState {
        try transaction {
            try CompanionProactiveCoding.require(NativeCompanionData.validID(owner), "Invalid cognitive owner")
            let previous = try cognitiveState(owner: owner)
            if let previous, now.timeIntervalSince(previous.updatedAt) < 60 { return previous }
            let traits = try rows("SELECT t.field,t.value FROM traits t WHERE t.owner=? AND NOT EXISTS (SELECT 1 FROM growth_jobs g WHERE g.owner=t.owner AND g.field=t.field AND g.target IS NULL AND g.status='needs_review')", [owner])
            let curiosity = traits.first { $0["field"] as? String == "curiosity" }?["value"] as? Double ?? 0.5
            let sociability = traits.first { $0["field"] as? String == "sociability" }?["value"] as? Double ?? 0.5
            var state = previous ?? CompanionCognitiveState(owner: owner, curiosity: min(0.8, max(0.2, curiosity)), socialInterest: min(0.6, max(0.15, sociability * 0.7)), updatedAt: now)
            state.advance(to: now, curiosityPrior: curiosity, sociabilityPrior: sociability)
            try saveCognition(state)
            return state
        }
    }
    func saveCognition(_ state: CompanionCognitiveState) throws {
        try CompanionProactiveCoding.require(NativeCompanionData.validID(state.owner) && [state.curiosity, state.socialInterest, state.expressionEnergy].allSatisfy(CompanionProactiveCoding.score), "Invalid cognitive state")
        try execute("INSERT OR REPLACE INTO cognitive_states VALUES (?,?,?)", [state.owner, try CompanionProactiveCoding.encode(state), state.updatedAt.timeIntervalSince1970])
    }
    func recordCognitiveExpression(_ value: CompanionOutputReceipt, now: Date = Date()) throws {
        var state = try maintainCognition(owner: value.characterId, now: now)
        state.expression(output: value.id, emotion: value.emotion ?? .neutral, at: now)
        try saveCognition(state)
    }
    func recordCognitiveSocial(_ value: CompanionOutputReceipt, now: Date = Date()) throws {
        var state = try maintainCognition(owner: value.characterId, now: now)
        if value.presentedAt == nil { state.expression(output: value.id, emotion: value.emotion ?? .neutral, at: now) }
        state.social(at: now); try saveCognition(state)
    }
}
