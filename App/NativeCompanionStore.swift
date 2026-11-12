import Foundation
import CryptoKit
import SQLite3

typealias CompanionObject = [String: Any]

enum NativeCompanionData {
    static let backends = ["opencode", "codex", "claude"]
    static func hash(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    static func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]) }
    static func string(_ value: Any) -> String { (try? json(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "null" }
    static func decode(_ data: Data) throws -> Any { try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) }
    static func object(_ value: Any?) -> CompanionObject { value as? CompanionObject ?? [:] }
    static func array(_ value: Any?) -> [CompanionObject] { value as? [CompanionObject] ?? [] }
    static func validID(_ value: String) -> Bool { UUID(uuidString: value) != nil }
    static func now() -> Double { Date().timeIntervalSince1970 * 1000 }
    static func iso(_ date: Date = Date()) -> String { ISO8601DateFormatter().string(from: date) }
    static func currentTime(_ date: Date = Date(), timeZone: TimeZone = .current) -> CompanionObject {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        return ["utc": iso(date), "local": formatter.string(from: date),
                "timeZone": timeZone.identifier, "utcOffsetSeconds": timeZone.secondsFromGMT(for: date),
                "weekday": weekdays[calendar.component(.weekday, from: date) - 1]]
    }
    static func error(_ message: String) -> Error { NSError(domain: "Lite2D.Companion", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    static func clean(_ input: String, limit: Int = 4000) -> String {
        var text = input
        for (pattern, replacement) in [
            (#"-----BEGIN [^-]*PRIVATE KEY-----[\s\S]*?-----END [^-]*PRIVATE KEY-----"#, "[redacted]"),
            (#"(?i)\b(?:sk-[\w-]{12,}|gh[pousr]_[\w]{15,}|Bearer\s+[\w.\/-]{10,})"#, "[redacted]"),
            (#"(?i)((?:api[_-]?key|token|password|secret|cookie|authorization)\s*[=:]\s*)[^\s,;\"']+"#, "$1[redacted]")
        ] {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: replacement)
            }
        }
        return String(text.prefix(limit))
    }
    static func text(_ value: Any?) -> String {
        if let s = value as? String { return s }
        if let a = value as? [Any] { return a.map { text($0) }.filter { !$0.isEmpty }.joined(separator: "\n") }
        guard let o = value as? CompanionObject else { return "" }
        let kind = o["type"] as? String ?? ""
        if ["reasoning", "thinking"].contains(kind) { return "" }
        if ["tool_use", "toolCall"].contains(kind) { return "[tool: \(o["name"] as? String ?? "activity")]" }
        if kind == "tool_result" { return o["is_error"] as? Bool == true ? "[tool failed]" : "[tool completed]" }
        if let s = o["text"] as? String { return s }
        return text(o["content"] ?? o["message"] ?? o["parts"] ?? o["items"])
    }
    static func output(_ raw: String) -> CompanionObject {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") { trimmed = trimmed.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "").trimmingCharacters(in: .whitespacesAndNewlines) }
        if ["skip", "[skip]"].contains(trimmed.lowercased()) { return ["skip": true] }
        if let bytes = trimmed.data(using: .utf8), let o = try? decode(bytes) as? CompanionObject {
            if o["skip"] as? Bool == true { return ["skip": true] }
            guard let value = o["text"] as? String else { return ["skip": true] }
            let emotion = o["emotion"] as? String ?? "neutral"
            return ["text": clean(value, limit: 300), "emotion": ["neutral", "happy", "curious", "concerned"].contains(emotion) ? emotion : "neutral"]
        }
        return trimmed.isEmpty || trimmed.hasPrefix("{") || trimmed.hasPrefix("[") ? ["skip": true] : ["text": clean(trimmed, limit: 300), "emotion": "neutral"]
    }
}

// SQLite schema and JSON state encoding match the former Node Controller so
// existing Sessions, notes, revisions, quotas and history require no export/import.
final class NativeCompanionStore {
    let root: URL
    private var database: OpaquePointer?
    private let lock = NSRecursiveLock()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private var ftsAvailable = false
    init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard sqlite3_open_v2(root.appendingPathComponent("state.sqlite").path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw NativeCompanionData.error("Cannot open Companion database") }
        sqlite3_busy_timeout(database, 3000)
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA secure_delete=ON")
        try execute("PRAGMA foreign_keys=ON")
        for sql in [
            "CREATE TABLE IF NOT EXISTS state(key TEXT PRIMARY KEY,value TEXT NOT NULL)",
            "CREATE TABLE IF NOT EXISTS events(seq INTEGER PRIMARY KEY AUTOINCREMENT,at TEXT NOT NULL,type TEXT NOT NULL,payload TEXT NOT NULL)",
            "CREATE TABLE IF NOT EXISTS records(path TEXT PRIMARY KEY,content TEXT NOT NULL,revision TEXT NOT NULL)",
            "CREATE TABLE IF NOT EXISTS changes(id INTEGER PRIMARY KEY,at TEXT,actor TEXT,path TEXT,before_revision TEXT,revision TEXT,content TEXT)",
            "CREATE TABLE IF NOT EXISTS deliveries(id TEXT PRIMARY KEY,topic TEXT,sender TEXT,recipient TEXT,text TEXT,status TEXT,remote_id TEXT,at TEXT)",
            "CREATE TABLE IF NOT EXISTS requests(at INTEGER NOT NULL)",
            "CREATE TABLE IF NOT EXISTS persona_revisions(id TEXT PRIMARY KEY,character_id TEXT NOT NULL,revision INTEGER NOT NULL,raw_hash TEXT NOT NULL,base_hash TEXT,markdown TEXT NOT NULL,actor TEXT NOT NULL,source_kind TEXT NOT NULL,created_at TEXT NOT NULL)",
            "CREATE UNIQUE INDEX IF NOT EXISTS persona_revisions_character_revision ON persona_revisions(character_id,revision)",
            "CREATE TABLE IF NOT EXISTS persona_claims(id TEXT PRIMARY KEY,revision_id TEXT NOT NULL,character_id TEXT NOT NULL,field TEXT NOT NULL,value TEXT NOT NULL,kind TEXT NOT NULL,provenance TEXT NOT NULL,confidence REAL NOT NULL,status TEXT NOT NULL,created_at TEXT NOT NULL)",
            "CREATE INDEX IF NOT EXISTS persona_claims_character ON persona_claims(character_id,status)",
            "CREATE TABLE IF NOT EXISTS persona_views(character_id TEXT NOT NULL,view_kind TEXT NOT NULL,content TEXT NOT NULL,content_hash TEXT NOT NULL,identity_revision TEXT NOT NULL,memory_cursor TEXT,generated_at TEXT NOT NULL,PRIMARY KEY(character_id,view_kind))",
            "CREATE TABLE IF NOT EXISTS memory_items(id TEXT PRIMARY KEY,owner_character_id TEXT NOT NULL,memory_type TEXT NOT NULL,scope TEXT NOT NULL,provenance TEXT NOT NULL,content TEXT NOT NULL,evidence_ids TEXT NOT NULL,source_actor_id TEXT,revision INTEGER NOT NULL,status TEXT NOT NULL,created_at TEXT NOT NULL,updated_at TEXT NOT NULL,supersedes_id TEXT)",
            "CREATE TABLE IF NOT EXISTS memory_details(memory_id TEXT PRIMARY KEY REFERENCES memory_items(id),event_id TEXT,subject_ids TEXT NOT NULL,source_ref TEXT,confidence REAL NOT NULL,salience REAL NOT NULL,occurred_at TEXT,learned_at TEXT NOT NULL,recorded_at TEXT NOT NULL,valid_from TEXT,valid_to TEXT,created_by TEXT NOT NULL)",
            "CREATE INDEX IF NOT EXISTS memory_items_owner_status ON memory_items(owner_character_id,status)",
            "CREATE TABLE IF NOT EXISTS world_events(id TEXT PRIMARY KEY,world_id TEXT NOT NULL,event_type TEXT NOT NULL,happened_at TEXT,source_kind TEXT NOT NULL,synthetic INTEGER NOT NULL,payload TEXT NOT NULL,created_at TEXT NOT NULL)",
            "CREATE TABLE IF NOT EXISTS relations(id TEXT PRIMARY KEY,observer_character_id TEXT NOT NULL,target_character_id TEXT NOT NULL,role TEXT,trust REAL NOT NULL,familiarity REAL NOT NULL,closeness REAL NOT NULL,impression TEXT,evidence_ids TEXT NOT NULL,seed_batch_id TEXT,revision INTEGER NOT NULL,status TEXT NOT NULL,created_at TEXT NOT NULL,updated_at TEXT NOT NULL,UNIQUE(observer_character_id,target_character_id))",
            "CREATE TABLE IF NOT EXISTS seed_batches(id TEXT PRIMARY KEY,idempotency_key TEXT UNIQUE NOT NULL,world_id TEXT NOT NULL,status TEXT NOT NULL,payload TEXT NOT NULL,created_at TEXT NOT NULL,updated_at TEXT NOT NULL)",
            "CREATE TABLE IF NOT EXISTS reflection_jobs(id TEXT PRIMARY KEY,owner_character_id TEXT NOT NULL,status TEXT NOT NULL,evidence_ids TEXT NOT NULL,proposed_content TEXT NOT NULL,created_at TEXT NOT NULL,updated_at TEXT NOT NULL)",
            "CREATE INDEX IF NOT EXISTS reflection_jobs_owner_status ON reflection_jobs(owner_character_id,status)",
            "CREATE TABLE IF NOT EXISTS seed_relation_backups(batch_id TEXT NOT NULL,observer TEXT NOT NULL,target TEXT NOT NULL,payload TEXT NOT NULL,PRIMARY KEY(batch_id,observer,target))",
            "CREATE TABLE IF NOT EXISTS memory_dependencies(memory_id TEXT NOT NULL,evidence_id TEXT NOT NULL,PRIMARY KEY(memory_id,evidence_id))",
            "CREATE TABLE IF NOT EXISTS memory_audit(id TEXT PRIMARY KEY,owner TEXT NOT NULL,operation TEXT NOT NULL,target TEXT NOT NULL,at TEXT NOT NULL)",
            "CREATE TABLE IF NOT EXISTS growth_jobs(id TEXT PRIMARY KEY,owner TEXT NOT NULL,target TEXT,field TEXT NOT NULL,old_value REAL NOT NULL,new_value REAL NOT NULL,evidence_ids TEXT NOT NULL,reason TEXT NOT NULL,status TEXT NOT NULL,base_revision INTEGER NOT NULL,created_at TEXT NOT NULL,updated_at TEXT NOT NULL)",
            "CREATE TABLE IF NOT EXISTS traits(owner TEXT NOT NULL,field TEXT NOT NULL,value REAL NOT NULL,revision INTEGER NOT NULL,PRIMARY KEY(owner,field))",
            "UPDATE deliveries SET status='delivery_unknown' WHERE status='delivering'"
        ] { try execute(sql) }
        try monitorSchema()
        try dailySchema()
        try transaction { try proactiveSchema() }
        do {
            try execute("CREATE VIRTUAL TABLE IF NOT EXISTS memory_fts USING fts5(memory_id UNINDEXED,owner_character_id UNINDEXED,content)")
            ftsAvailable = true
        } catch { ftsAvailable = false }
        try backfillLegacyMemories()
        try transaction {
            for row in try rows("SELECT id,evidence_ids FROM memory_items WHERE status!='deleted'") {
                for evidence in Set(evidenceIDs(row)) { try execute("INSERT OR IGNORE INTO memory_dependencies VALUES (?,?)", [row["id"], evidence]) }
            }
            try execute("INSERT OR IGNORE INTO memory_details SELECT id,NULL,'[]',NULL,0.5,0.5,NULL,created_at,created_at,NULL,NULL,owner_character_id FROM memory_items")
            try execute("PRAGMA user_version=5")
        }
    }
    deinit { sqlite3_close(database) }
    // Hold the recursive lock for the entire transaction, including reads and CAS.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        let nested = sqlite3_get_autocommit(database) == 0
        let savepoint = "sp_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        try execute(nested ? "SAVEPOINT \(savepoint)" : "BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute(nested ? "RELEASE SAVEPOINT \(savepoint)" : "COMMIT")
            return result
        } catch {
            if nested { try? execute("ROLLBACK TO SAVEPOINT \(savepoint)"); try? execute("RELEASE SAVEPOINT \(savepoint)") }
            else { try? execute("ROLLBACK") }
            throw error
        }
    }
    func audit(owner: String, operation: String, target: String, actor: String? = nil, result: String? = nil) throws {
        let id = UUID().uuidString
        try execute("INSERT INTO memory_audit VALUES (?,?,?,?,?)", [id, owner, operation, target, NativeCompanionData.iso()])
        if actor != nil || result != nil { try execute("INSERT INTO monitor_audit_details VALUES (?,?,?)", [id, actor, result]) }
    }
    func evidenceIDs(_ row: CompanionObject) -> [String] {
        guard let value = row["evidence_ids"] as? String, let data = value.data(using: .utf8) else { return [] }
        return (try? NativeCompanionData.decode(data)) as? [String] ?? []
    }
    private func statement(_ sql: String, _ args: [Any?]) throws -> OpaquePointer {
        var result: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &result, nil) == SQLITE_OK, let result else { throw NativeCompanionData.error("Companion database query failed: \(String(cString: sqlite3_errmsg(database))) SQL=\(sql)") }
        for (i, value) in args.enumerated() {
            let index = Int32(i + 1)
            if let s = value as? String { sqlite3_bind_text(result, index, s, -1, transient) }
            else if let n = value as? NSNumber { sqlite3_bind_double(result, index, n.doubleValue) }
            else { sqlite3_bind_null(result, index) }
        }
        return result
    }
    func execute(_ sql: String, _ args: [Any?] = []) throws {
        lock.lock(); defer { lock.unlock() }
        let s = try statement(sql, args); defer { sqlite3_finalize(s) }
        let code = sqlite3_step(s)
        guard code == SQLITE_DONE || code == SQLITE_ROW else { throw NativeCompanionData.error("Companion database write failed: \(String(cString: sqlite3_errmsg(database)))") }
    }
    func rows(_ sql: String, _ args: [Any?] = []) throws -> [CompanionObject] {
        lock.lock(); defer { lock.unlock() }
        let s = try statement(sql, args); defer { sqlite3_finalize(s) }
        var result: [CompanionObject] = []
        while true {
            let code = sqlite3_step(s)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw NativeCompanionData.error("Companion database read failed") }
            var row: CompanionObject = [:]
            for i in 0..<sqlite3_column_count(s) {
                let name = String(cString: sqlite3_column_name(s, i))
                switch sqlite3_column_type(s, i) {
                case SQLITE_INTEGER: row[name] = Int(sqlite3_column_int64(s, i))
                case SQLITE_FLOAT: row[name] = sqlite3_column_double(s, i)
                case SQLITE_TEXT: row[name] = String(cString: sqlite3_column_text(s, i))
                default: row[name] = NSNull()
                }
            }
            result.append(row)
        }
        return result
    }
    func get(_ key: String) -> Any? {
        guard let s = try? rows("SELECT value FROM state WHERE key=?", [key]).first?["value"] as? String,
              let data = s.data(using: .utf8) else { return nil }
        return try? NativeCompanionData.decode(data)
    }
    func set(_ key: String, _ value: Any) throws { try execute("INSERT OR REPLACE INTO state VALUES (?,?)", [key, NativeCompanionData.string(value)]) }

    private func backfillLegacyMemories() throws {
        for row in try rows("SELECT key,value FROM state WHERE key LIKE 'memory:%'") {
            guard let key = row["key"] as? String, let owner = key.split(separator: ":", maxSplits: 1).last.map(String.init), NativeCompanionData.validID(owner),
                  let encoded = row["value"] as? String, let data = encoded.data(using: .utf8), let content = try? NativeCompanionData.decode(data) as? String,
                  !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let exists = try rows("SELECT id FROM memory_items WHERE owner_character_id=? AND provenance='legacy_import' LIMIT 1", [owner]).first != nil
            if !exists { _ = try memoryWrite(owner: owner, type: "diary", provenance: "legacy_import", content: content) }
        }
    }

    func ingestPersona(characterID: String, markdown: String, actor: String = "user", sourceKind: String = "user_persona_edit") throws -> CompanionObject {
        guard NativeCompanionData.validID(characterID), !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw NativeCompanionData.error("Invalid Persona") }
        return try transaction {
        let hash = NativeCompanionData.hash(markdown), now = NativeCompanionData.iso()
        if let existing = try latestPersona(characterID: characterID), existing["raw_hash"] as? String == hash {
            return ["revisionId": existing["id"] ?? "", "revision": existing["revision"] ?? 0, "hash": hash, "unchanged": true]
        }
        let previous = try rows("SELECT revision,raw_hash FROM persona_revisions WHERE character_id=? ORDER BY revision DESC LIMIT 1", [characterID]).first
        let revision = (previous?["revision"] as? Int ?? 0) + 1
        let id = UUID().uuidString
        try execute("INSERT INTO persona_revisions VALUES (?,?,?,?,?,?,?,?,?)", [id, characterID, revision, hash, previous?["raw_hash"], markdown, actor, sourceKind, now])
        try execute("UPDATE persona_claims SET status='superseded' WHERE character_id=? AND status='active'", [characterID])
        for claim in NativePersonaMemory.claims(markdown) {
            try execute("INSERT INTO persona_claims VALUES (?,?,?,?,?,?,?,?,?,?)", [UUID().uuidString, id, characterID, claim.field, claim.value, claim.kind, sourceKind, claim.confidence, "active", now])
        }
        try audit(owner: characterID, operation: "persona.revision", target: id)
        return ["revisionId": id, "revision": revision, "hash": hash, "unchanged": false]
        }
    }

    func latestPersona(characterID: String) throws -> CompanionObject? {
        try rows("SELECT id,character_id,revision,raw_hash,base_hash,markdown,actor,source_kind,created_at FROM persona_revisions WHERE character_id=? ORDER BY revision DESC LIMIT 1", [characterID]).first
    }

    func personaChangePreview(characterID: String, markdown: String) throws -> CompanionObject {
        let current = try latestPersona(characterID: characterID)
        let nextClaims = NativePersonaMemory.claims(markdown).map { ["field": $0.field, "value": $0.value, "kind": $0.kind, "confidence": $0.confidence] as [String: Any] }
        let oldClaims = try personaClaims(characterID: characterID)
        let oldHash = current?["raw_hash"] as? String ?? ""
        let nextHash = NativeCompanionData.hash(markdown)
        return ["characterId": characterID, "baseRevision": current?["revision"] ?? 0, "baseHash": oldHash, "nextHash": nextHash, "changed": oldHash != nextHash, "oldClaims": oldClaims, "newClaims": nextClaims, "conflicts": nextClaims.filter { next in oldClaims.contains { $0["field"] as? String == next["field"] as? String && $0["value"] as? String != next["value"] as? String } }]
    }

    func personaClaims(characterID: String) throws -> [CompanionObject] {
        guard let latest = try latestPersona(characterID: characterID), let revisionID = latest["id"] as? String else { return [] }
        return try rows("SELECT field,value,kind,provenance,confidence,status FROM persona_claims WHERE revision_id=? AND status='active' ORDER BY id", [revisionID])
    }

    func publicIdentityCard(characterID: String, name: String) throws -> CompanionObject {
        guard let persona = try latestPersona(characterID: characterID), let markdown = persona["markdown"] as? String else {
            return ["id": characterID, "name": name, "identityRevision": 0, "confirmed": "", "unknown": "没有公开 Persona 资料；不要根据名字或玩笑推断身份。", "provenance": "missing"]
        }
        let revision = String(persona["revision"] as? Int ?? 0)
        return NativePersonaMemory.publicCard(characterID: characterID, name: name, markdown: markdown, revision: revision)
    }

    func runtimePersona(characterID: String, markdown: String) throws -> String {
        let revision = try ingestPersona(characterID: characterID, markdown: markdown)["revision"] as? Int ?? 1
        let claims = try personaClaims(characterID: characterID).compactMap { row -> NativePersonaClaim? in
            guard let field = row["field"] as? String, let value = row["value"] as? String, let kind = row["kind"] as? String else { return nil }
            return NativePersonaClaim(field: field, value: value, kind: kind, confidence: row["confidence"] as? Double ?? 1)
        }
        let base = NativePersonaMemory.runtimeView(markdown: markdown, revision: String(revision), managed: claims)
        let memories = try memorySearch(owner: characterID, query: "", types: ["belief", "habit", "skill", "reflection", "opinion"], limit: 6)
        let derived = memories.map { "- [\($0["id"] as? String ?? "")] source=\($0["provenance"] as? String ?? ""), evidence=\($0["evidence_ids"] as? String ?? "[]"): \(String(($0["content"] as? String ?? "").prefix(400)))" }.joined(separator: "\n")
        let view = base + (derived.isEmpty ? "" : "\n\n## Derived continuity (controller_generated; not identity or independent evidence)\n" + derived)
        try execute("INSERT OR REPLACE INTO persona_views VALUES (?,?,?,?,?,?,?)", [characterID, "runtime", view, NativeCompanionData.hash(view), String(revision), nil, NativeCompanionData.iso()])
        return view
    }

    @discardableResult func memoryWrite(owner: String, type: String, scope: String = "private", provenance: String = "experienced", content: String, evidenceIDs: [String] = [], sourceActorID: String? = nil, supersedesID: String? = nil, eventID: String? = nil, subjectIDs: [String] = [], sourceRef: String? = nil, confidence: Double = 0.8, salience: Double = 0.5, occurredAt: String? = nil, learnedAt: String? = nil, validFrom: String? = nil, validTo: String? = nil, createdBy: String? = nil) throws -> CompanionObject {
        return try transaction {
        guard NativeCompanionData.validID(owner), !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, content.utf8.count <= 32768 else { throw NativeCompanionData.error("Invalid memory") }
        guard confidence.isFinite, salience.isFinite, (0...1).contains(confidence), (0...1).contains(salience),
              ["private"].contains(scope), ["event", "fact", "belief", "opinion", "skill", "habit", "reflection", "relation", "diary"].contains(type) else { throw NativeCompanionData.error("Invalid memory classification or score") }
        let dateParser = ISO8601DateFormatter()
        for date in [occurredAt, learnedAt, validFrom, validTo].compactMap({ $0 }) { guard dateParser.date(from: date) != nil else { throw NativeCompanionData.error("Invalid memory time") } }
        if let from = validFrom, let to = validTo, dateParser.date(from: from)! > dateParser.date(from: to)! { throw NativeCompanionData.error("Invalid memory validity interval") }
        if let sourceRef { guard sourceRef.count <= 200, !sourceRef.contains("/"), !sourceRef.contains("\\"), NativeCompanionData.clean(sourceRef) == sourceRef else { throw NativeCompanionData.error("Source reference must be an opaque evidence ID") } }
        let id = UUID().uuidString, now = NativeCompanionData.iso()
        let cleaned = NativeCompanionData.clean(content, limit: 32768)
        try execute("INSERT INTO memory_items VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)", [id, owner, type, scope, provenance, cleaned, NativeCompanionData.string(evidenceIDs), sourceActorID, 1, "active", now, now, supersedesID])
        try execute("INSERT INTO memory_details VALUES (?,?,?,?,?,?,?,?,?,?,?,?)", [id, eventID, NativeCompanionData.string(subjectIDs), sourceRef, confidence, salience, occurredAt, learnedAt ?? now, now, validFrom, validTo, createdBy ?? owner])
        if ftsAvailable { try execute("INSERT INTO memory_fts(memory_id,owner_character_id,content) VALUES (?,?,?)", [id, owner, cleaned]) }
        for evidence in Set(evidenceIDs) { try execute("INSERT INTO memory_dependencies VALUES (?,?)", [id, evidence]) }
        try audit(owner: owner, operation: "memory.write", target: id)
        return ["memoryId": id, "revision": 1, "status": "active"]
        }
    }

    func memoryDetails(_ items: [CompanionObject]) throws -> [CompanionObject] {
        try items.compactMap { item -> CompanionObject? in
            var result = item
            if let loop = try rows("SELECT status FROM daily_open_loops WHERE memory_id=?", [item["id"]]).first { result["continuityStatus"] = loop["status"] }
            if let details = try rows("SELECT event_id,subject_ids,source_ref,confidence,salience,occurred_at,learned_at,recorded_at,valid_from,valid_to,created_by FROM memory_details WHERE memory_id=?", [item["id"]]).first {
                let parser = ISO8601DateFormatter(), now = Date()
                if let from = details["valid_from"] as? String, let date = parser.date(from: from), date > now { return nil }
                if let to = details["valid_to"] as? String, let date = parser.date(from: to), date <= now { return nil }
                for (key, value) in details { result[key] = value }
            }
            return result
        }
    }

    func memorySearch(owner: String, query: String, types: [String] = [], limit: Int = 20) throws -> [CompanionObject] {
        let safeLimit = min(max(limit, 1), 100)
        var sql = "SELECT id,memory_type,scope,provenance,content,evidence_ids,source_actor_id,revision,status,created_at,updated_at,supersedes_id FROM memory_items WHERE owner_character_id=? AND status='active'"
        var args: [Any?] = [owner]
        if ftsAvailable && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            do {
                var ftsSQL = "SELECT m.id,m.memory_type,m.scope,m.provenance,m.content,m.evidence_ids,m.source_actor_id,m.revision,m.status,m.created_at,m.updated_at,m.supersedes_id FROM memory_items m JOIN memory_fts f ON f.memory_id=m.id WHERE m.owner_character_id=? AND m.status='active' AND f.owner_character_id=? AND f.content MATCH ?"
                var ftsArgs: [Any?] = [owner, owner, query]
                if !types.isEmpty { ftsSQL += " AND m.memory_type IN (" + Array(repeating: "?", count: types.count).joined(separator: ",") + ")"; ftsArgs.append(contentsOf: types) }
                ftsSQL += " ORDER BY bm25(memory_fts),m.updated_at DESC,m.rowid DESC LIMIT ?"; ftsArgs.append(safeLimit)
                let matches = try rows(ftsSQL, ftsArgs)
                if !matches.isEmpty { return try memoryDetails(matches) }
            } catch { }
        }
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { sql += " AND content LIKE ?"; args.append("%\(query.replacingOccurrences(of: "%", with: ""))%") }
        if !types.isEmpty { sql += " AND memory_type IN (" + Array(repeating: "?", count: types.count).joined(separator: ",") + ")"; args.append(contentsOf: types) }
        sql += " ORDER BY updated_at DESC,rowid DESC LIMIT ?"; args.append(safeLimit)
        return try memoryDetails(rows(sql, args))
    }

    func memoryRead(_ id: String, owner: String) throws -> CompanionObject? {
        try memoryDetails(rows("SELECT id,memory_type,scope,provenance,content,evidence_ids,source_actor_id,revision,status,created_at,updated_at,supersedes_id FROM memory_items WHERE id=? AND owner_character_id=? AND status='active'", [id, owner])).first
    }

    func memoryCorrect(_ id: String, owner: String, content: String, expectedRevision: Int, reason: String) throws -> CompanionObject {
        return try transaction {
        guard let old = try memoryRead(id, owner: owner), let revision = old["revision"] as? Int, revision == expectedRevision else { return ["conflict": true] }
        let next = try memoryWrite(owner: owner, type: old["memory_type"] as? String ?? "fact", scope: old["scope"] as? String ?? "private", provenance: "corrected", content: content, evidenceIDs: [id], supersedesID: id, eventID: old["event_id"] as? String, occurredAt: old["occurred_at"] as? String)
        try execute("UPDATE memory_items SET status='superseded',updated_at=? WHERE id=? AND owner_character_id=?", [NativeCompanionData.iso(), id, owner])
        try invalidateDependents(of: [id], owner: owner)
        try set("memory:\(owner)", "")
        try set("sessionPolicy:\(owner)", "memory-invalidated")
        try set("memoryCutoff:\(owner)", NativeCompanionData.iso())
        try audit(owner: owner, operation: "memory.correct", target: id)
        var result = next; result["reason"] = NativeCompanionData.clean(reason); result["supersedesId"] = id; return result
        }
    }

    // Invalidation traverses explicit dependencies; derived text must never outlive its evidence.
    func invalidateDependents(of ids: [String], owner: String) throws {
        try dailyInvalidate(owner)
        for id in ids {
            try invalidateProactiveDependency(kind: "memory", id: id, reason: "memory_changed")
            try invalidateProactiveDependency(kind: "evidence", id: id, reason: "memory_changed")
        }
        var pending = ids, seen = Set(ids)
        while !pending.isEmpty {
            let source = pending.removeFirst()
            for row in try rows("SELECT m.id FROM memory_items m JOIN memory_dependencies d ON d.memory_id=m.id WHERE d.evidence_id=? AND m.owner_character_id=? AND m.status='active' AND m.supersedes_id IS NULL", [source, owner]) {
                if let id = row["id"] as? String, seen.insert(id).inserted {
                    try invalidateProactiveDependency(kind: "memory", id: id, reason: "evidence_invalidated")
                    try invalidateProactiveDependency(kind: "evidence", id: id, reason: "evidence_invalidated")
                    try execute("UPDATE memory_items SET status='needs_review',content='',updated_at=? WHERE id=?", [NativeCompanionData.iso(), id])
                    if ftsAvailable { try execute("DELETE FROM memory_fts WHERE memory_id=?", [id]) }
                    pending.append(id)
                }
            }
        }
        // Purge only jobs using the affected evidence, not unrelated reflections.
        for job in try rows("SELECT * FROM reflection_jobs WHERE owner_character_id=? AND status IN ('preview','committed')", [owner]) where !Set(evidenceIDs(job)).isDisjoint(with: seen) {
            try execute("UPDATE reflection_jobs SET status='invalidated',proposed_content='' WHERE id=?", [job["id"]])
        }
        for job in try rows("SELECT * FROM growth_jobs WHERE owner=? AND status IN ('preview','committed')", [owner]) where !Set(evidenceIDs(job)).isDisjoint(with: seen) {
            if job["status"] as? String == "committed" {
                do { _ = try rollbackGrowth(owner: owner, jobID: job["id"] as? String ?? "") }
                catch {
                    if let target = job["target"] as? String { try execute("UPDATE relations SET status='needs_review' WHERE observer_character_id=? AND target_character_id=?", [owner, target]) }
                }
            }
            try execute("UPDATE growth_jobs SET status='needs_review',reason='' WHERE id=?", [job["id"]])
        }
        try execute("DELETE FROM persona_views WHERE character_id=?", [owner])
        let generated = root.appendingPathComponent("characters/\(owner)/persona.generated.md")
        try? FileManager.default.removeItem(at: generated)
    }

    @discardableResult func forgetMemory(_ id: String, owner: String) throws -> Bool {
        try transaction {
            guard try rows("SELECT id FROM memory_items WHERE id=? AND owner_character_id=? AND status!='deleted'", [id, owner]).first != nil else { return false }
            try execute("DELETE FROM monitor_previews")
            var chain = Set([id]), pending = [id]
            while !pending.isEmpty {
                let current = pending.removeFirst()
                let parents = try rows("SELECT supersedes_id AS id FROM memory_items WHERE id=? AND owner_character_id=?", [current, owner])
                let children = try rows("SELECT id FROM memory_items WHERE supersedes_id=? AND owner_character_id=?", [current, owner])
                for row in parents + children { if let next = row["id"] as? String, chain.insert(next).inserted { pending.append(next) } }
            }
            try invalidateDependents(of: Array(chain), owner: owner)
            for item in chain {
                try execute("UPDATE memory_items SET status='deleted',content='',evidence_ids='[]',updated_at=? WHERE id=? AND owner_character_id=?", [NativeCompanionData.iso(), item, owner])
                if ftsAvailable { try execute("DELETE FROM memory_fts WHERE memory_id=?", [item]) }
            }
            try set("memory:\(owner)", "")
            try set("memoryCutoff:\(owner)", NativeCompanionData.iso())
            try set("sessionPolicy:\(owner)", "memory-invalidated")
            try execute("UPDATE deliveries SET status='cancelled' WHERE recipient=? AND status IN ('queued','accepted_pending_context')", [owner])
            try audit(owner: owner, operation: "memory.forget", target: id)
            return true
        }
    }

    func forgetCharacter(_ owner: String) throws {
        try transaction {
            try execute("DELETE FROM proactive_dependencies WHERE id IN (SELECT id FROM proactive_intentions WHERE owner=?)", [owner])
            try execute("DELETE FROM proactive_intentions WHERE owner=?", [owner])
            try execute("DELETE FROM proactive_outputs WHERE owner=?", [owner])
            try execute("DELETE FROM proactive_opportunities WHERE owner=?", [owner])
            try dailyInvalidate(owner)
            try execute("DELETE FROM monitor_previews")
            try execute("UPDATE memory_items SET status='deleted',content='',evidence_ids='[]',updated_at=? WHERE owner_character_id=?", [NativeCompanionData.iso(), owner])
            if ftsAvailable { try execute("DELETE FROM memory_fts WHERE owner_character_id=?", [owner]) }
            try set("memory:\(owner)", "")
            try set("legacyMigrated:\(owner)", true)
            try set("memoryCutoff:\(owner)", NativeCompanionData.iso())
            try execute("UPDATE reflection_jobs SET status='invalidated',proposed_content='' WHERE owner_character_id=?", [owner])
            try execute("UPDATE growth_jobs SET status='invalidated',reason='' WHERE owner=?", [owner])
            try execute("DELETE FROM traits WHERE owner=?", [owner])
            try execute("DELETE FROM persona_views WHERE character_id=?", [owner])
            try execute("UPDATE relations SET status='archived',impression='',updated_at=? WHERE observer_character_id=? OR target_character_id=?", [NativeCompanionData.iso(), owner, owner])
            try audit(owner: owner, operation: "character.forget", target: owner)
        }
    }

    // Only direct, active sources belonging to this actor qualify as growth evidence.
    func recordDirectMemory(owner: String, source: String, eventID: String, content: String, sourceActorID: String? = nil) throws -> CompanionObject {
        try transaction {
            guard ["experienced", "observed", "told_by_other"].contains(source), !eventID.isEmpty else { throw NativeCompanionData.error("Invalid direct event") }
            if let old = try rows("SELECT m.id,m.status FROM memory_items m JOIN memory_details d ON d.memory_id=m.id WHERE m.owner_character_id=? AND d.event_id=? AND m.memory_type='event' ORDER BY m.rowid DESC LIMIT 1", [owner, eventID]).first {
                return ["memoryId": old["id"] ?? "", "status": old["status"] ?? "", "duplicate": true]
            }
            return try memoryWrite(owner: owner, type: "event", provenance: source, content: content, sourceActorID: sourceActorID, eventID: eventID)
        }
    }

    func verifiedEvidence(owner: String, ids: [String], minimum: Int = 1) throws -> [CompanionObject] {
        let unique = Array(Set(ids)).sorted()
        guard unique.count >= minimum, unique.count <= 20 else { throw NativeCompanionData.error("Independent evidence is required") }
        let records = try unique.map { id in
            guard let item = try memoryRead(id, owner: owner),
                  ["experienced", "observed", "told_by_other"].contains(item["provenance"] as? String ?? ""),
                  ["event", "fact"].contains(item["memory_type"] as? String ?? "") else { throw NativeCompanionData.error("Evidence is unavailable, synthetic or derived") }
            return item
        }
        let events = Set(records.map { ($0["event_id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? ($0["id"] as? String ?? "") })
        guard events.count >= minimum else { throw NativeCompanionData.error("Repeated views of the same event are not independent evidence") }
        return records
    }

    func reflectionPreview(owner: String, limit: Int = 20) throws -> [CompanionObject] {
        try transaction {
            let memories = try memorySearch(owner: owner, query: "", types: ["event", "fact"], limit: min(max(limit, 2), 20)).filter {
                ["experienced", "observed", "told_by_other"].contains($0["provenance"] as? String ?? "")
            }
            guard memories.count >= 2 else { return [] }
            let evidence = memories.compactMap { $0["id"] as? String }.sorted()
            _ = try verifiedEvidence(owner: owner, ids: evidence, minimum: 2)
            let encoded = NativeCompanionData.string(evidence)
            if let existing = try rows("SELECT * FROM reflection_jobs WHERE owner_character_id=? AND evidence_ids=? AND status IN ('preview','committed','cancelled') ORDER BY created_at DESC LIMIT 1", [owner, encoded]).first { return [existing] }
            let snippets = memories.map { "[\($0["id"] as? String ?? "")] (\($0["provenance"] as? String ?? "")) \(String(($0["content"] as? String ?? "").prefix(240)))" }
            let content = "待审核的证据摘要（不是新的独立经历）：\n" + snippets.joined(separator: "\n")
            let id = UUID().uuidString, now = NativeCompanionData.iso()
            try execute("INSERT INTO reflection_jobs VALUES (?,?,?,?,?,?,?)", [id, owner, "preview", encoded, content, now, now])
            return try rows("SELECT * FROM reflection_jobs WHERE id=?", [id])
        }
    }

    func commitReflection(owner: String, jobID: String) throws -> CompanionObject {
        try transaction {
            guard let job = try rows("SELECT * FROM reflection_jobs WHERE id=? AND owner_character_id=? AND status='preview'", [jobID, owner]).first,
                  let content = job["proposed_content"] as? String else { throw NativeCompanionData.error("Reflection job is unavailable") }
            let ids = evidenceIDs(job)
            _ = try verifiedEvidence(owner: owner, ids: ids, minimum: 2)
            let result = try memoryWrite(owner: owner, type: "reflection", provenance: "inferred", content: content, evidenceIDs: ids)
            try execute("UPDATE reflection_jobs SET status='committed',updated_at=? WHERE id=?", [NativeCompanionData.iso(), jobID])
            try execute("INSERT INTO reflection_outputs VALUES (?,?)", [jobID, result["memoryId"]])
            try audit(owner: owner, operation: "reflection.commit", target: jobID)
            var output = result; output["jobId"] = jobID; output["evidenceIds"] = ids; return output
        }
    }

    func cancelReflection(owner: String, jobID: String) throws -> Bool {
        try transaction {
            guard let job = try rows("SELECT status FROM reflection_jobs WHERE id=? AND owner_character_id=?", [jobID, owner]).first, job["status"] as? String == "preview" else { return false }
            try execute("UPDATE reflection_jobs SET status='cancelled',proposed_content='',updated_at=? WHERE id=?", [NativeCompanionData.iso(), jobID])
            try audit(owner: owner, operation: "reflection.cancel", target: jobID)
            return true
        }
    }

    // Proposals cannot change locked identity or policy. Explicit approval is a host-only operation.
    func previewGrowth(owner: String, target: String? = nil, field: String, value: Double, evidence: [String], reason: String) throws -> CompanionObject {
        try transaction {
            guard value.isFinite, (0...1).contains(value), !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw NativeCompanionData.error("Growth needs a bounded value and reason") }
            let sources = try verifiedEvidence(owner: owner, ids: evidence, minimum: 2)
            let old: Double, revision: Int
            if let target {
                guard target != owner, NativeCompanionData.validID(target), ["trust", "familiarity", "closeness"].contains(field),
                      sources.contains(where: { $0["source_actor_id"] as? String == target }),
                      let relation = try relationGet(observer: owner, target: target) else { throw NativeCompanionData.error("Relationship growth requires evidence involving the target") }
                old = (relation[field] as? NSNumber)?.doubleValue ?? 0.5; revision = relation["revision"] as? Int ?? 1
            } else {
                guard ["curiosity", "patience", "sociability", "carefulness"].contains(field) else { throw NativeCompanionData.error("Locked identity and policy are not growth fields") }
                let trait = try rows("SELECT value,revision FROM traits WHERE owner=? AND field=?", [owner, field]).first
                old = (trait?["value"] as? NSNumber)?.doubleValue ?? 0.5; revision = trait?["revision"] as? Int ?? 0
            }
            let cap = target == nil ? 0.05 : 0.1
            guard abs(value - old) > 0.000001, abs(value - old) <= cap + 0.000001 else { throw NativeCompanionData.error("Growth exceeds the per-day change limit") }
            let id = UUID().uuidString, now = NativeCompanionData.iso()
            try execute("INSERT INTO growth_jobs VALUES (?,?,?,?,?,?,?,?,?,?,?,?)", [id, owner, target, field, old, value, NativeCompanionData.string(Array(Set(evidence)).sorted()), NativeCompanionData.clean(reason, limit: 2000), "preview", revision, now, now])
            return try rows("SELECT * FROM growth_jobs WHERE id=?", [id]).first!
        }
    }

    func commitGrowth(owner: String, jobID: String) throws -> CompanionObject {
        try transaction {
            guard let job = try rows("SELECT * FROM growth_jobs WHERE id=? AND owner=? AND status='preview'", [jobID, owner]).first,
                  let field = job["field"] as? String, let old = job["old_value"] as? Double, let value = job["new_value"] as? Double,
                  let revision = job["base_revision"] as? Int else { throw NativeCompanionData.error("Growth proposal is unavailable") }
            let sources = try verifiedEvidence(owner: owner, ids: evidenceIDs(job), minimum: 2)
            let target = job["target"] as? String
            let reused = try rows("SELECT id FROM growth_jobs WHERE owner=? AND field=? AND COALESCE(target,'')=? AND evidence_ids=? AND status IN ('committed','rolled_back','needs_review') LIMIT 1", [owner, field, target ?? "", job["evidence_ids"]])
            guard reused.isEmpty else { throw NativeCompanionData.error("This evidence has already supported a change; new experiences are required") }
            let date = String(NativeCompanionData.iso().prefix(10))
            let spent = try rows("SELECT old_value,new_value FROM growth_jobs WHERE owner=? AND field=? AND COALESCE(target,'')=? AND status IN ('committed','rolled_back','needs_review') AND updated_at>=?", [owner, field, target ?? "", date]).reduce(0.0) { $0 + abs(($1["new_value"] as? Double ?? 0) - ($1["old_value"] as? Double ?? 0)) }
            guard spent + abs(value - old) <= (target == nil ? 0.05 : 0.1) + 0.000001 else { throw NativeCompanionData.error("Daily growth allowance is exhausted") }
            if let target {
                guard sources.contains(where: { $0["source_actor_id"] as? String == target }), let current = try relationGet(observer: owner, target: target), current["revision"] as? Int == revision else { throw NativeCompanionData.error("Relationship changed; preview again") }
                // field was validated at proposal creation; recheck before SQL interpolation.
                guard ["trust", "familiarity", "closeness"].contains(field) else { throw NativeCompanionData.error("Invalid growth field") }
                try execute("UPDATE relations SET \(field)=?,revision=revision+1,evidence_ids=?,updated_at=? WHERE observer_character_id=? AND target_character_id=?", [value, job["evidence_ids"], NativeCompanionData.iso(), owner, target])
            } else {
                let current = try rows("SELECT revision FROM traits WHERE owner=? AND field=?", [owner, field]).first?["revision"] as? Int ?? 0
                guard current == revision else { throw NativeCompanionData.error("Trait changed; preview again") }
                try execute("INSERT OR REPLACE INTO traits VALUES (?,?,?,?)", [owner, field, value, revision + 1])
            }
            try execute("UPDATE growth_jobs SET status='committed',updated_at=? WHERE id=?", [NativeCompanionData.iso(), jobID])
            try audit(owner: owner, operation: "growth.commit", target: jobID)
            return ["jobId": jobID, "status": "committed", "revision": revision + 1]
        }
    }

    func rollbackGrowth(owner: String, jobID: String) throws -> CompanionObject {
        try transaction {
            guard let job = try rows("SELECT * FROM growth_jobs WHERE id=? AND owner=? AND status='committed'", [jobID, owner]).first,
                  let field = job["field"] as? String, let old = job["old_value"] as? Double, let revision = job["base_revision"] as? Int else { throw NativeCompanionData.error("Committed growth is unavailable") }
            if let target = job["target"] as? String {
                guard ["trust", "familiarity", "closeness"].contains(field), let current = try relationGet(observer: owner, target: target), current["revision"] as? Int == revision + 1 else { throw NativeCompanionData.error("Later relationship changes require review") }
                try execute("UPDATE relations SET \(field)=?,revision=revision+1,updated_at=? WHERE observer_character_id=? AND target_character_id=?", [old, NativeCompanionData.iso(), owner, target])
            } else {
                guard try rows("SELECT revision FROM traits WHERE owner=? AND field=?", [owner, field]).first?["revision"] as? Int == revision + 1 else { throw NativeCompanionData.error("Later trait changes require review") }
                try execute("UPDATE traits SET value=?,revision=revision+1 WHERE owner=? AND field=?", [old, owner, field])
            }
            try execute("UPDATE growth_jobs SET status='rolled_back',updated_at=? WHERE id=?", [NativeCompanionData.iso(), jobID])
            try audit(owner: owner, operation: "growth.rollback", target: jobID)
            return ["jobId": jobID, "status": "rolled_back"]
        }
    }

    func growthState(owner: String) throws -> CompanionObject {
        ["traits": try rows("SELECT t.* FROM traits t WHERE owner=? AND NOT EXISTS (SELECT 1 FROM growth_jobs g WHERE g.owner=t.owner AND g.field=t.field AND g.target IS NULL AND g.status='needs_review')", [owner]),
         "proposals": try rows("SELECT * FROM growth_jobs WHERE owner=? ORDER BY created_at DESC LIMIT 100", [owner]),
         "reflections": try rows("SELECT * FROM reflection_jobs WHERE owner_character_id=? ORDER BY created_at DESC LIMIT 100", [owner])]
    }

    func relationGet(observer: String, target: String) throws -> CompanionObject? {
        try rows("SELECT observer_character_id,target_character_id,role,trust,familiarity,closeness,impression,evidence_ids,seed_batch_id,revision,status,created_at,updated_at FROM relations WHERE observer_character_id=? AND target_character_id=? AND status='active'", [observer, target]).first
    }

    func previewRelationshipBootstrap(worldID: String, participants: [String], premise: String, perspectives: CompanionObject, idempotencyKey: String) throws -> CompanionObject {
        guard participants.count >= 2, participants.count <= 20, Set(participants).count == participants.count, participants.allSatisfy(NativeCompanionData.validID), !premise.isEmpty, !idempotencyKey.isEmpty else { throw NativeCompanionData.error("Invalid relationship seed") }
        if let existing = try rows("SELECT id,status,payload FROM seed_batches WHERE idempotency_key=?", [idempotencyKey]).first {
            return ["previewId": existing["id"] ?? "", "status": existing["status"] ?? "", "idempotent": true, "proposed": existing["payload"] ?? "{}"]
        }
        let proposed: CompanionObject = ["participants": participants, "premise": NativeCompanionData.clean(premise, limit: 4000), "perspectives": perspectives, "synthetic": true, "source": "world_seed"]
        let batchID = UUID().uuidString, now = NativeCompanionData.iso()
        try execute("INSERT INTO seed_batches VALUES (?,?,?,?,?,?,?)", [batchID, idempotencyKey, worldID, "preview", NativeCompanionData.string(proposed), now, now])
        return ["previewId": batchID, "status": "preview", "idempotent": false, "proposed": proposed]
    }

    func commitRelationshipBootstrap(previewID: String, approvedBy: String) throws -> CompanionObject {
        lock.lock(); defer { lock.unlock() }
        guard !approvedBy.isEmpty, let batch = try rows("SELECT id,world_id,status,payload FROM seed_batches WHERE id=?", [previewID]).first,
              let status = batch["status"] as? String, status == "preview",
              let payloadText = batch["payload"] as? String, let payloadData = payloadText.data(using: .utf8), let payload = try NativeCompanionData.decode(payloadData) as? CompanionObject,
              let participants = payload["participants"] as? [String] else { throw NativeCompanionData.error("Seed preview is unavailable or already committed") }
        let now = NativeCompanionData.iso(), eventID = UUID().uuidString
        try execute("BEGIN IMMEDIATE")
        do {
            try execute("UPDATE seed_batches SET status='committing',updated_at=? WHERE id=?", [now, previewID])
            let eventPayload: CompanionObject = ["premise": payload["premise"] ?? "", "participants": participants, "approvedBy": approvedBy, "seedBatchId": previewID]
            try execute("INSERT INTO world_events VALUES (?,?,?,?,?,?,?,?)", [eventID, batch["world_id"] ?? "", "relationship_bootstrap", now, "world_seed", 1, NativeCompanionData.string(eventPayload), now])
            let perspectives = NativeCompanionData.object(payload["perspectives"])
            for observer in participants {
                for target in participants where target != observer {
                let perspective = NativeCompanionData.object(perspectives[observer])
                let view = participants.count == 2 && perspective["role"] != nil ? perspective : NativeCompanionData.object(perspective[target])
                let previous = try rows("SELECT * FROM relations WHERE observer_character_id=? AND target_character_id=?", [observer, target]).first
                try execute("INSERT INTO seed_relation_backups VALUES (?,?,?,?)", [previewID, observer, target, NativeCompanionData.string(previous ?? [:])])
                let trust = min(max(view["trust"] as? Double ?? 0.5, 0), 1)
                let familiarity = min(max(view["familiarity"] as? Double ?? trust, 0), 1)
                let closeness = min(max(view["closeness"] as? Double ?? familiarity, 0), 1)
                let role = view["role"] as? String ?? "known_person"
                let impression = NativeCompanionData.clean(view["impression"] as? String ?? "", limit: 2000)
                try execute("INSERT OR REPLACE INTO relations VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)", [UUID().uuidString, observer, target, role, trust, familiarity, closeness, impression, NativeCompanionData.string([eventID]), previewID, 1, "active", now, now])
                _ = try memoryWrite(owner: observer, type: "relation", provenance: "world_seed", content: impression.isEmpty ? "我与对方存在设定中的关系：\(role)。" : impression, evidenceIDs: [eventID], sourceActorID: nil, supersedesID: nil)
                }
            }
            try execute("UPDATE seed_batches SET status='committed',updated_at=? WHERE id=?", [NativeCompanionData.iso(), previewID])
            try execute("COMMIT")
            return ["seedBatchId": previewID, "status": "committed", "eventId": eventID, "participants": participants]
        } catch { try? execute("ROLLBACK"); try? execute("UPDATE seed_batches SET status='failed',updated_at=? WHERE id=?", [NativeCompanionData.iso(), previewID]); throw error }
    }

    func rollbackSeedBatch(_ batchID: String) throws -> CompanionObject {
        try transaction {
            guard let batch = try rows("SELECT status FROM seed_batches WHERE id=?", [batchID]).first, batch["status"] as? String == "committed" else { throw NativeCompanionData.error("Seed batch is not committed") }
            let legacyRelations = try rows("SELECT * FROM relations WHERE seed_batch_id=?", [batchID])
            let legacyEvents = legacyRelations.flatMap { evidenceIDs($0) }
            var conflicts: [String] = []
            for saved in try rows("SELECT observer,target,payload FROM seed_relation_backups WHERE batch_id=?", [batchID]) {
                let observer = saved["observer"] as? String ?? "", target = saved["target"] as? String ?? ""
                guard let current = try rows("SELECT * FROM relations WHERE observer_character_id=? AND target_character_id=?", [observer, target]).first,
                      current["seed_batch_id"] as? String == batchID, current["revision"] as? Int == 1 else { conflicts.append("\(observer)->\(target)"); continue }
                let old = NativeCompanionData.object((saved["payload"] as? String)?.data(using: .utf8).flatMap { try? NativeCompanionData.decode($0) })
                if !old.isEmpty {
                    let fields = ["id", "observer_character_id", "target_character_id", "role", "trust", "familiarity", "closeness", "impression", "evidence_ids", "seed_batch_id", "revision", "status", "created_at", "updated_at"]
                    try execute("INSERT OR REPLACE INTO relations VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)", fields.map { old[$0] })
                } else {
                    try execute("UPDATE relations SET status='archived',updated_at=? WHERE observer_character_id=? AND target_character_id=?", [NativeCompanionData.iso(), observer, target])
                }
            }
            for relation in legacyRelations {
                if relation["revision"] as? Int == 1 {
                    try execute("UPDATE relations SET status='archived' WHERE id=? AND seed_batch_id=?", [relation["id"], batchID])
                } else {
                    let edge = "\(relation["observer_character_id"] as? String ?? "")->\(relation["target_character_id"] as? String ?? "")"
                    if !conflicts.contains(edge) { conflicts.append(edge) }
                }
            }
            // Match the event through its participant memory and seed's creation audit.
            let eventRows = try rows("SELECT id,payload FROM world_events WHERE event_type='relationship_bootstrap' AND source_kind='world_seed'")
            let ownedEvents = eventRows.filter { row in
                let payload = NativeCompanionData.object((row["payload"] as? String)?.data(using: .utf8).flatMap { try? NativeCompanionData.decode($0) })
                return payload["seedBatchId"] as? String == batchID
            }.compactMap { $0["id"] as? String }
            for event in Set(ownedEvents + legacyEvents) {
                let memories = try rows("SELECT m.id,m.owner_character_id FROM memory_items m JOIN memory_dependencies d ON d.memory_id=m.id WHERE d.evidence_id=? AND m.provenance='world_seed'", [event])
                for memory in memories {
                    let id = memory["id"] as? String ?? "", owner = memory["owner_character_id"] as? String ?? ""
                    try invalidateDependents(of: [id], owner: owner)
                    try execute("UPDATE memory_items SET status='archived',updated_at=? WHERE id=?", [NativeCompanionData.iso(), id])
                    if ftsAvailable { try execute("DELETE FROM memory_fts WHERE memory_id=?", [id]) }
                }
            }
            try execute("UPDATE seed_batches SET status='rolled_back',updated_at=? WHERE id=?", [NativeCompanionData.iso(), batchID])
            return ["seedBatchId": batchID, "status": "rolled_back", "conflicts": conflicts]
        }
    }
    func event(_ type: String, _ payload: CompanionObject) throws -> CompanionObject {
        lock.lock(); defer { lock.unlock() }
        let at = NativeCompanionData.iso()
        try execute("INSERT INTO events(at,type,payload) VALUES (?,?,?)", [at, type, NativeCompanionData.string(payload)])
        var result = payload; result["type"] = type; result["protocolVersion"] = 1; result["sequence"] = Int(sqlite3_last_insert_rowid(database)); result["createdAt"] = at
        return result
    }
    func history(_ limit: Int = 200) throws -> [CompanionObject] {
        try rows("SELECT seq,at,type,payload FROM events WHERE type IN ('utterance','topic.end','error','record.changed') ORDER BY seq DESC LIMIT ?", [limit]).reversed().map { row in
            var e = NativeCompanionData.object((row["payload"] as? String).flatMap { $0.data(using: .utf8) }.flatMap { try? NativeCompanionData.decode($0) })
            e["sequence"] = row["seq"]; e["createdAt"] = row["at"]; e["type"] = row["type"]; return e
        }
    }
    func spend(_ limit: Int, now: Double = NativeCompanionData.now()) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        try execute("DELETE FROM requests WHERE at<?", [now - 3600000])
        if try requestCount(now: now) >= limit { return false }
        try execute("INSERT INTO requests VALUES (?)", [now]); return true
    }
    func requestCount(now: Double = NativeCompanionData.now()) throws -> Int { try rows("SELECT COUNT(*) AS n FROM requests WHERE at>=?", [now - 3600000]).first?["n"] as? Int ?? 0 }
    func readRecord(_ name: String) throws -> CompanionObject {
        guard !name.contains(".."), name.range(of: #"^[\w\u0080-\uffff][\w\u0080-\uffff .-]{0,120}\.md$"#, options: .regularExpression) != nil else { throw NativeCompanionData.error("Invalid record name") }
        if var row = try rows("SELECT content,revision FROM records WHERE path=?", [name]).first { row["exists"] = true; return row }
        return ["content": "", "revision": NativeCompanionData.hash(""), "exists": false]
    }
    func updateRecord(actor: String, name: String, content: String, revision: String? = nil) throws -> CompanionObject {
        guard content.utf8.count <= 32768 else { throw NativeCompanionData.error("Record exceeds 32 KB") }
        return try transaction {
            let before = try readRecord(name)
            let matches = revision.map { $0 == before["revision"] as? String } ?? (before["exists"] as? Bool == false)
            guard matches else { return ["conflict": true, "revision": before["revision"] ?? ""] }
            let next = NativeCompanionData.hash(content)
            try execute("INSERT OR REPLACE INTO records VALUES (?,?,?)", [name, content, next])
            try execute("INSERT INTO changes(at,actor,path,before_revision,revision,content) VALUES (?,?,?,?,?,?)", [NativeCompanionData.iso(), actor, name, revision, next, content])
            return ["revision": next]
        }
    }
    func records() throws -> [CompanionObject] {
        try rows("SELECT path FROM records ORDER BY path").map { row in var r = try readRecord(row["path"] as! String); r["path"] = row["path"]; return r }
    }
    func exportNotes() throws {
        lock.lock(); defer { lock.unlock() }
        func project(_ relative: String, _ content: String) throws {
            var directory = root
            for part in relative.split(separator: "/").dropLast() {
                directory.appendPathComponent(String(part))
                if !FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
                let attributes = try directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                guard attributes.isSymbolicLink != true, attributes.isDirectory == true else { throw NativeCompanionData.error("Invalid memory directory") }
            }
            try content.write(to: root.appendingPathComponent(relative), atomically: true, encoding: .utf8)
        }
        for row in try rows("SELECT key,value FROM state WHERE key LIKE 'memory:%'") {
            let id = String((row["key"] as! String).dropFirst(7))
            if NativeCompanionData.validID(id), let data = (row["value"] as? String)?.data(using: .utf8), let value = try NativeCompanionData.decode(data) as? String { try project("characters/\(id)/memory.md", value) }
        }
        let all = try records(); let names = Set(all.compactMap { $0["path"] as? String })
        for row in all { try project("public/records/\(row["path"] as! String)", row["content"] as? String ?? "") }
        let directory = root.appendingPathComponent("public/records")
        if (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true {
            for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] where file.pathExtension == "md" && !names.contains(file.lastPathComponent) { try FileManager.default.removeItem(at: file) }
        }
        let lines = try history(1000).filter { $0["type"] as? String == "utterance" }.map { "## \($0["createdAt"] as? String ?? "") · \($0["characterId"] as? String ?? "")\n\n\($0["text"] as? String ?? "")\n" }
        try project("public/exchanges/recent.md", "# Companion exchanges\n\n" + lines.joined(separator: "\n"))
    }
}

struct NativeCompanionPrompt: Decodable {
    let system: String
    let turnIntent: String
    let manualTest: String
    let peerReceipt: String
    let styleExample: String
    let toolDescriptions: [String: String]
    func system(persona: String) -> String { system + "\n\nPERSONA:\n" + persona }
    static func load(_ file: URL) throws -> Self { try JSONDecoder().decode(Self.self, from: Data(contentsOf: file)) }
}
