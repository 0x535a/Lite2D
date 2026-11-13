import Foundation

// Wire objects use camelCase. No raw source text belongs in a role projection.
enum CompanionActivityCategory: String, Codable, CaseIterable {
    case browsing, programming, writing, research, experiment, media, communication, idle, unknown
}
enum CompanionPrivacyClass: String, Codable { case `public`, normal, personal, sensitive, restricted }
enum CompanionPerceptionUse: String, Codable, CaseIterable { case attention, activityContext, characterCognition, memory, expression, audit }
enum CompanionProactiveMode: String, Codable { case off, shadow, live }
enum CompanionModality: String, Codable { case silent, ambient, bubble, socialMessage }

enum CompanionProactiveCoding {
    static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
    static func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(text.utf8))
    }
    static func object<T: Encodable>(_ value: T) throws -> CompanionObject {
        NativeCompanionData.object(try NativeCompanionData.decode(Data(encode(value).utf8)))
    }
    static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw NativeCompanionData.error("Proactive: " + message) }
    }
    static func bounded(_ value: String, bytes: Int) -> Bool { !value.isEmpty && value.utf8.count <= bytes && !value.contains("\0") }
    static func score(_ value: Double) -> Bool { value.isFinite && (0...1).contains(value) }
}

struct CompanionPerceptionPolicy: Codable, Equatable {
    var allowedCharacterIds: [String] = []
    var allowedUses: [CompanionPerceptionUse] = [.attention]
    var remoteInferenceAllowed = false
    var memoryAllowed = false
    var consentEpoch = 1
    var resourceScopeRevision: String?
    func permits(_ character: String, use: CompanionPerceptionUse, remote: Bool = false) -> Bool {
        allowedCharacterIds.contains(character) && allowedUses.contains(use) && (!remote || remoteInferenceAllowed)
    }
    func validate() throws {
        try CompanionProactiveCoding.require(consentEpoch > 0 && allowedCharacterIds.count <= 100 && allowedCharacterIds.allSatisfy(NativeCompanionData.validID), "Invalid consent policy")
        try CompanionProactiveCoding.require(!memoryAllowed || allowedUses.contains(.memory), "Memory grant lacks memory purpose")
    }
}

struct CompanionObservation: Codable, Equatable {
    var schemaVersion = 1
    var id: String
    var revision = 1
    var source: String
    var type: String
    var observedAt: Date
    var sourceAt: Date?
    var subject: String
    // Typed, bounded metadata only. Source adapters must not supply arbitrary dictionaries.
    var activityCategory: CompanionActivityCategory?
    var evidenceType: String = "source_metadata"
    var privacyClass: CompanionPrivacyClass = .normal
    var confidence: Double = 1
    var expiresAt: Date
    var retentionSeconds = 0
    var originDevice = "mac"
    var policy = CompanionPerceptionPolicy()
    var actionability = "observation_only"
    func validate() throws {
        let c = CompanionProactiveCoding.self
        try c.require(schemaVersion == 1 && revision > 0, "Unsupported event version")
        try c.require(c.bounded(id, bytes: 256) && c.bounded(source, bytes: 100) && c.bounded(type, bytes: 100), "Invalid event identity")
        try c.require(c.bounded(subject, bytes: 100) && c.bounded(evidenceType, bytes: 100), "Unbounded metadata")
        try c.require(c.score(confidence) && expiresAt >= observedAt && (0...604800).contains(retentionSeconds), "Invalid event score/time/retention")
        try c.require(sourceAt.map { $0 <= observedAt.addingTimeInterval(300) } ?? true, "Source time is in the future")
        try c.require(["mac", "iphone", "ipad", "watch", "unknown"].contains(originDevice) && actionability == "observation_only", "Invalid origin/actionability")
        try policy.validate()
    }
    // Match bridge §9.2: context is a typed envelope, not a free-text escape hatch.
    enum CodingKeys: String, CodingKey { case schemaVersion, id, revision, source, type, observedAt, sourceAt, subject, context, privacyClass, confidence, expiresAt, retentionSeconds, originDevice, policy, actionability }
    struct Context: Codable { var activityCategory: CompanionActivityCategory?; var evidenceType: String }
    init(id: String, source: String, type: String, observedAt: Date = Date(), sourceAt: Date? = nil, subject: String, expiresAt: Date) {
        self.id = id; self.source = source; self.type = type; self.observedAt = observedAt; self.sourceAt = sourceAt; self.subject = subject; self.expiresAt = expiresAt
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion); id = try c.decode(String.self, forKey: .id)
        revision = try c.decode(Int.self, forKey: .revision); source = try c.decode(String.self, forKey: .source); type = try c.decode(String.self, forKey: .type)
        observedAt = try c.decode(Date.self, forKey: .observedAt); sourceAt = try c.decodeIfPresent(Date.self, forKey: .sourceAt)
        subject = try c.decode(String.self, forKey: .subject); let context = try c.decode(Context.self, forKey: .context)
        activityCategory = context.activityCategory; evidenceType = context.evidenceType
        privacyClass = try c.decode(CompanionPrivacyClass.self, forKey: .privacyClass); confidence = try c.decode(Double.self, forKey: .confidence)
        expiresAt = try c.decode(Date.self, forKey: .expiresAt); retentionSeconds = try c.decode(Int.self, forKey: .retentionSeconds)
        originDevice = try c.decode(String.self, forKey: .originDevice); policy = try c.decode(CompanionPerceptionPolicy.self, forKey: .policy)
        actionability = try c.decode(String.self, forKey: .actionability); try validate()
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion); try c.encode(id, forKey: .id); try c.encode(revision, forKey: .revision)
        try c.encode(source, forKey: .source); try c.encode(type, forKey: .type); try c.encode(observedAt, forKey: .observedAt); try c.encodeIfPresent(sourceAt, forKey: .sourceAt)
        try c.encode(subject, forKey: .subject); try c.encode(Context(activityCategory: activityCategory, evidenceType: evidenceType), forKey: .context)
        try c.encode(privacyClass, forKey: .privacyClass); try c.encode(confidence, forKey: .confidence); try c.encode(expiresAt, forKey: .expiresAt)
        try c.encode(retentionSeconds, forKey: .retentionSeconds); try c.encode(originDevice, forKey: .originDevice); try c.encode(policy, forKey: .policy); try c.encode(actionability, forKey: .actionability)
    }
}

struct CompanionActivityContext: Codable, Equatable {
    var contextId = UUID().uuidString
    var category: CompanionActivityCategory
    var confidence: Double
    var observedAt: Date
    var expiresAt: Date
    var source: String
    var consentEpoch: Int
    var contextScope: String?
    // This is the sole projection allowed in role context. Never encode the entire object there.
    func roleProjection(at now: Date) -> CompanionObject? {
        guard expiresAt > now, CompanionProactiveCoding.score(confidence), confidence >= 0.65 else { return nil }
        return ["category": category.rawValue, "confidence": confidence, "observedAt": NativeCompanionData.iso(observedAt), "expiresAt": NativeCompanionData.iso(expiresAt)]
    }
}

enum CompanionIntentionState: String, Codable, CaseIterable {
    case proposed, pending, ready, executing, completed, deferred, cancelled, expired, failed, needsReview
    var terminal: Bool { [.completed, .cancelled, .expired, .failed].contains(self) }
    func canTransition(to next: Self) -> Bool {
        if terminal { return false }
        if [.cancelled, .expired, .needsReview].contains(next) { return true }
        switch self {
        case .proposed: return next == .pending
        case .pending: return [.ready, .deferred].contains(next)
        case .ready: return [.executing, .deferred].contains(next)
        case .executing: return [.completed, .deferred, .failed].contains(next)
        case .deferred: return [.pending, .ready].contains(next)
        case .needsReview: return next == .pending
        default: return false
        }
    }
}
enum CompanionIntentionOrigin: String, Codable { case conversationMemory, userExplicit, socialMessage, reflection, systemReminder }
struct CompanionIntention: Codable, Equatable {
    var id = UUID().uuidString
    var ownerCharacterId: String
    var targetCharacterId: String?
    var goal: String
    var origin: CompanionIntentionOrigin
    var topicKey: String
    var sourceMemoryId: String?
    var evidenceIds: [String]
    var relatedEventIds: [String] = []
    var priority: Double = 0.5
    var notBefore: Date?
    var expiresAt: Date
    var cooldownUntil: Date?
    var maxAttempts = 2
    var attemptCount = 0
    var state: CompanionIntentionState = .pending
    var lastDecisionReason = "created"
    var policyRevision = "v1"
    var createdBy = "controller"
    var createdAt = Date()
    var updatedAt = Date()
    var completedAt: Date?
    func validate() throws {
        let c = CompanionProactiveCoding.self
        try c.require(NativeCompanionData.validID(id) && NativeCompanionData.validID(ownerCharacterId), "Invalid intention owner")
        try c.require(targetCharacterId.map { NativeCompanionData.validID($0) && $0 != ownerCharacterId } ?? true, "Invalid intention target")
        try c.require(c.bounded(goal, bytes: 1200) && c.bounded(topicKey, bytes: 200) && c.score(priority), "Invalid intention goal/priority")
        try c.require(!evidenceIds.isEmpty && evidenceIds.count <= 16 && evidenceIds.allSatisfy { c.bounded($0, bytes: 256) }, "Missing intention evidence")
        try c.require(expiresAt > createdAt && expiresAt.timeIntervalSince(createdAt) <= 30 * 86400 && (notBefore.map { $0 < expiresAt } ?? true), "Invalid intention lifetime")
        try c.require((1...3).contains(maxAttempts) && (0...maxAttempts).contains(attemptCount), "Invalid intention attempts")
    }
}

enum CompanionOpportunityState: String, Codable { case pending, ready, deferred, consumed, expired, cancelled }
struct CompanionOpportunity: Codable, Equatable {
    var id = UUID().uuidString
    var ownerCharacterId: String
    var kind: String
    var sourceEventIds: [String]
    var relatedIntentionIds: [String] = []
    var topicKey: String
    var priority: Double
    var intrusionCost: Double
    var notBefore: Date
    var expiresAt: Date
    var state: CompanionOpportunityState = .pending
    var reasonCodes: [String] = []
    var policyRevision = "v1"
    func validate() throws {
        let c = CompanionProactiveCoding.self
        try c.require(NativeCompanionData.validID(id) && NativeCompanionData.validID(ownerCharacterId), "Invalid opportunity identity")
        try c.require(c.bounded(topicKey, bytes: 200) && c.bounded(kind, bytes: 100) && c.score(priority) && c.score(intrusionCost), "Invalid opportunity scores")
        try c.require(expiresAt > notBefore && expiresAt.timeIntervalSince(notBefore) <= 86400 && sourceEventIds.count <= 16, "Invalid opportunity lifetime")
    }
}

struct CompanionInterruptContext: Codable, Equatable {
    var enabled = true
    var manualPause = false
    var sleeping = false
    var sessionAvailable = true
    var focusQuiet = false
    var focusUnknown = false
    var visible = true
    var outputBusy = false
    var cooldown = false
    var budgetAvailable = true
    var idleSeconds: Double = 0
    var audioActive = false
    var energyConstrained = false
    var policyRevision = "v1"
    var gates: [String] {
        var result: [String] = []
        if !enabled { result.append("disabled") }; if manualPause { result.append("manual_pause") }
        if sleeping { result.append("sleeping") }; if !sessionAvailable { result.append("session_unknown") }
        if focusUnknown { result.append("focus_unknown") }
        else if focusQuiet { result.append("focus_quiet") }
        if !visible { result.append("character_hidden") }
        if outputBusy { result.append("output_busy") }; if cooldown { result.append("cooldown") }
        if !budgetAvailable { result.append("budget_exhausted") }; return result
    }
}
struct CompanionDecisionRecord: Codable, Equatable {
    var id = UUID().uuidString
    var mode: CompanionProactiveMode
    var subjectId: String
    var characterId: String
    var action: String
    var reasonCodes: [String]
    var scores: [String: Double]
    var selectedModality: CompanionModality
    var policyRevision: String
    var decidedAt: Date
    // Optional for compatibility with decisions written before audit coalescing.
    var lastEvaluatedAt: Date?
    var evaluationCount: Int?
}
enum CompanionArbiter {
    // Pure deterministic function: replay never invokes a model or mutates live state.
    static func decide(_ opportunity: CompanionOpportunity, context: CompanionInterruptContext, mode: CompanionProactiveMode, at now: Date) -> CompanionDecisionRecord {
        var reasons = context.gates
        if mode == .off { reasons.append("mode_off") }
        if opportunity.expiresAt <= now { reasons.append("expired") }
        if opportunity.notBefore > now { reasons.append("not_before") }
        if [.consumed, .expired, .cancelled].contains(opportunity.state) { reasons.append("inactive_opportunity") }
        if !context.idleSeconds.isFinite || context.idleSeconds < 15 { reasons.append("user_active") }
        if context.energyConstrained && opportunity.kind == "intrinsic_interest" { reasons.append("resource_pressure") }
        let cost = min(1, opportunity.intrusionCost + (context.audioActive ? 0.15 : 0))
        let score = opportunity.priority - cost
        if score < 0.15 { reasons.append("low_value") }
        let admitted = reasons.isEmpty
        return CompanionDecisionRecord(mode: mode, subjectId: opportunity.id, characterId: opportunity.ownerCharacterId,
            action: admitted ? "admit" : (reasons.contains("expired") ? "cancel" : "defer"), reasonCodes: admitted ? ["worthwhile_opportunity"] : reasons,
            scores: ["value": opportunity.priority, "cost": cost, "net": score],
            selectedModality: admitted ? .bubble : .silent, policyRevision: context.policyRevision, decidedAt: now)
    }
}

enum CompanionOutputStatus: String, Codable { case candidate, admitted, queued, presented, completed, dismissed, cancelled, failed, deliveryUnknown }
struct CompanionOutputReceipt: Codable, Equatable {
    var id = UUID().uuidString
    var characterId: String
    var topicId: String
    var modality: CompanionModality
    var status: CompanionOutputStatus = .candidate
    var text: String
    var relatedIntentionIds: [String] = []
    var decisionId: String?
    var deliveryId: String?
    var createdAt: Date = Date()
    var presentedAt: Date?
    var completedAt: Date?
    var failureReason: String?
    var emotion: CompanionAffect?
}

struct CompanionContextSnapshot: Codable {
    var id = UUID().uuidString
    var contextVersion = 1
    var characterId: String
    var personaRevision: Int
    var generatedAt: Date
    var expiresAt: Date
    var intentions: [CompanionIntention]
    var memories: [CompanionObject] = []
    var socialContext: [CompanionObject] = []
    var sharedMemory: [CompanionObject] = []
    var opportunities: [CompanionObject] = []
    // Compiled separately: Any is deliberately not Codable and never accepted from a role.
    enum CodingKeys: String, CodingKey { case id, contextVersion, characterId, personaRevision, generatedAt, expiresAt, intentions }
    func roleContext(activity: CompanionActivityContext?, at now: Date) -> CompanionObject {
        var value: CompanionObject = ["snapshotId": id, "contextVersion": contextVersion, "characterId": characterId,
            "personaRevision": personaRevision, "generatedAt": NativeCompanionData.iso(generatedAt), "expiresAt": NativeCompanionData.iso(expiresAt),
            "intentions": intentions.filter { $0.ownerCharacterId == characterId && !$0.state.terminal && $0.state != .needsReview && $0.expiresAt > now }.prefix(3).map {
                ["id": $0.id, "goal": $0.goal, "origin": $0.origin.rawValue, "expiresAt": NativeCompanionData.iso($0.expiresAt)]
            },
            "memories": Array(memories.prefix(8)).map { memory -> CompanionObject in
                ["id": memory["id"] ?? "", "content": String((memory["content"] as? String ?? "").prefix(400)), "provenance": memory["provenance"] ?? "inferred"]
            },
            "socialContext": Array(socialContext.suffix(4)),
            "sharedMemory": Array(sharedMemory.prefix(4)).map { ["path": $0["path"] ?? "", "content": String(($0["content"] as? String ?? "").prefix(400))] },
            "opportunities": Array(opportunities.prefix(3)),
            "allowedModalities": ["silent", "bubble", "socialMessage"],
            "policy": ["mayMentionActivityCategory": true, "mayDiscussSpecificWork": false]]
        if let projection = activity?.roleProjection(at: now) { value["activity"] = projection }
        return value
    }
}
