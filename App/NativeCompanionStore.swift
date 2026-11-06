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
    init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard sqlite3_open_v2(root.appendingPathComponent("state.sqlite").path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw NativeCompanionData.error("Cannot open Companion database") }
        sqlite3_busy_timeout(database, 3000)
        try execute("PRAGMA journal_mode=WAL")
        for sql in [
            "CREATE TABLE IF NOT EXISTS state(key TEXT PRIMARY KEY,value TEXT NOT NULL)",
            "CREATE TABLE IF NOT EXISTS events(seq INTEGER PRIMARY KEY AUTOINCREMENT,at TEXT NOT NULL,type TEXT NOT NULL,payload TEXT NOT NULL)",
            "CREATE TABLE IF NOT EXISTS records(path TEXT PRIMARY KEY,content TEXT NOT NULL,revision TEXT NOT NULL)",
            "CREATE TABLE IF NOT EXISTS changes(id INTEGER PRIMARY KEY,at TEXT,actor TEXT,path TEXT,before_revision TEXT,revision TEXT,content TEXT)",
            "CREATE TABLE IF NOT EXISTS deliveries(id TEXT PRIMARY KEY,topic TEXT,sender TEXT,recipient TEXT,text TEXT,status TEXT,remote_id TEXT,at TEXT)",
            "CREATE TABLE IF NOT EXISTS requests(at INTEGER NOT NULL)",
            "UPDATE deliveries SET status='delivery_unknown' WHERE status='delivering'"
        ] { try execute(sql) }
    }
    deinit { sqlite3_close(database) }
    private func statement(_ sql: String, _ args: [Any?]) throws -> OpaquePointer {
        var result: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &result, nil) == SQLITE_OK, let result else { throw NativeCompanionData.error("Companion database query failed") }
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
        guard code == SQLITE_DONE || code == SQLITE_ROW else { throw NativeCompanionData.error("Companion database write failed") }
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
        lock.lock(); defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do {
            let before = try readRecord(name)
            let matches = revision.map { $0 == before["revision"] as? String } ?? (before["exists"] as? Bool == false)
            guard matches else { try execute("ROLLBACK"); return ["conflict": true, "revision": before["revision"] ?? ""] }
            let next = NativeCompanionData.hash(content)
            try execute("INSERT OR REPLACE INTO records VALUES (?,?,?)", [name, content, next])
            try execute("INSERT INTO changes(at,actor,path,before_revision,revision,content) VALUES (?,?,?,?,?,?)", [NativeCompanionData.iso(), actor, name, revision, next, content])
            try execute("COMMIT"); return ["revision": next]
        } catch { try? execute("ROLLBACK"); throw error }
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
