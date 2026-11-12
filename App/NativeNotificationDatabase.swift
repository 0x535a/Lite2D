import Foundation
import SQLite3

enum CompanionNotificationError: String, Error {
    case permissionDenied = "permission_denied", notSupported = "not_supported", unsupportedSchema = "unsupported_schema"
    case temporarilyUnavailable = "temporarily_unavailable", malformed = "malformed_record", consentChanged = "consent_changed"
}
struct CompanionNotificationCursor: Codable, Equatable {
    var databaseHint: String
    var generation: String
    var highWatermark: Int64
}
struct CompanionNotificationRecord {
    var recordID: Int64
    var stableID: String
    var fingerprint: String
    var sourceAt: Date
    var privacy: CompanionPrivacyClass
    var malformedContent = false
}
struct CompanionNotificationBatch {
    var records: [CompanionNotificationRecord]
    var cursor: CompanionNotificationCursor
    var baseline: Bool
    var hasMore: Bool
    var gaps: [String]
    var scopeRevision: String
}

// Static SQL, selected App bindings and SQLITE_OPEN_READONLY. Never touches system notification state.
final class CompanionNotificationDatabase {
    private var database: OpaquePointer?
    private let url: URL
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private(set) var isReadOnly = false
    private var databaseHint = ""
    private(set) var contentColumnReads = 0
    private final class Authorization {
        let contentAllowed: Bool
        var contentReads = 0
        let started = ProcessInfo.processInfo.systemUptime
        init(_ allowed: Bool) { contentAllowed = allowed }
    }
    init(url: URL) throws {
        self.url = url
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: url.path) }
        catch {
            let code = (error as NSError).code
            throw [NSFileReadNoPermissionError, Int(EACCES), Int(EPERM)].contains(code) ? CompanionNotificationError.permissionDenied : CompanionNotificationError.notSupported
        }
        let result = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil)
        guard result == SQLITE_OK else { if let database { sqlite3_close(database) }; database = nil; throw Self.failure(result) }
        sqlite3_busy_timeout(database, 150)
        sqlite3_limit(database, SQLITE_LIMIT_LENGTH, 1_048_576)
        isReadOnly = sqlite3_db_readonly(database, "main") == 1
        guard isReadOnly else { throw CompanionNotificationError.permissionDenied }
        let recordFields = try columns("record"), appFields = try columns("app")
        guard Set(["rec_id", "app_id", "uuid", "data", "delivered_date"]).isSubset(of: recordFields),
              Set(["app_id", "identifier"]).isSubset(of: appFields) else { throw CompanionNotificationError.unsupportedSchema }
        let hint = [String(describing: attributes[.systemNumber] ?? ""), String(describing: attributes[.systemFileNumber] ?? ""),
                    String(describing: attributes[.creationDate] ?? ""), recordFields.sorted().joined(separator: ","), appFields.sorted().joined(separator: ",")].joined(separator: ":")
        databaseHint = NativeCompanionData.hash(hint)
    }
    deinit { if let database { sqlite3_close(database) } }
    private static func failure(_ code: Int32) -> CompanionNotificationError {
        switch code & 0xff {
        case SQLITE_PERM, SQLITE_AUTH, SQLITE_CANTOPEN: return .permissionDenied
        case SQLITE_BUSY, SQLITE_LOCKED, SQLITE_IOERR, SQLITE_INTERRUPT: return .temporarilyUnavailable
        default: return .unsupportedSchema
        }
    }
    private func statement(_ sql: String) throws -> OpaquePointer {
        var value: OpaquePointer?
        let result = sqlite3_prepare_v2(database, sql, -1, &value, nil)
        guard result == SQLITE_OK, let value else { if let value { sqlite3_finalize(value) }; throw Self.failure(result) }
        return value
    }
    private func columns(_ table: String) throws -> Set<String> {
        // table is a code constant, never a caller-provided identifier.
        let s = try statement("PRAGMA table_info(\(table))"); defer { sqlite3_finalize(s) }
        var result = Set<String>()
        while true {
            let status = sqlite3_step(s)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw Self.failure(status) }
            result.insert(String(cString: sqlite3_column_text(s, 1)))
        }
    }
    static func scopeRevision(apps: [String], content: Bool) -> String {
        NativeCompanionData.hash(Array(Set(apps)).sorted().joined(separator: ",") + ":" + String(content))
    }
    func read(cursor: CompanionNotificationCursor?, apps: [String], contentAllowed: Bool, now: Date = Date()) throws -> CompanionNotificationBatch {
        guard !apps.isEmpty, apps.count <= 64, apps.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 200 && !$0.contains("\0") }) else { throw CompanionNotificationError.permissionDenied }
        let authorization = Authorization(contentAllowed)
        let raw = Unmanaged.passUnretained(authorization).toOpaque()
        sqlite3_set_authorizer(database, { raw, action, first, second, _, _ in
            guard let raw else { return SQLITE_DENY }
            let policy = Unmanaged<Authorization>.fromOpaque(raw).takeUnretainedValue()
            if action == SQLITE_READ {
                let table = first.map { String(cString: $0) } ?? ""
                let column = second.map { String(cString: $0) } ?? ""
                guard ["record", "app"].contains(table) else { return SQLITE_DENY }
                if table == "record" && column == "data" {
                    policy.contentReads += 1
                    if !policy.contentAllowed { return SQLITE_DENY }
                }
                return SQLITE_OK
            }
            return [SQLITE_SELECT, SQLITE_FUNCTION, SQLITE_TRANSACTION].contains(action) ? SQLITE_OK : SQLITE_DENY
        }, raw)
        sqlite3_progress_handler(database, 1000, { raw in
            guard let raw else { return 1 }
            let policy = Unmanaged<Authorization>.fromOpaque(raw).takeUnretainedValue()
            return ProcessInfo.processInfo.systemUptime - policy.started > 0.25 ? 1 : 0
        }, raw)
        defer { contentColumnReads += authorization.contentReads; sqlite3_set_authorizer(database, nil, nil); sqlite3_progress_handler(database, 0, nil, nil) }
        let begin = try statement("BEGIN"); defer { sqlite3_finalize(begin) }
        guard sqlite3_step(begin) == SQLITE_DONE else { throw CompanionNotificationError.temporarilyUnavailable }
        defer { if let end = try? statement("ROLLBACK") { _ = sqlite3_step(end); sqlite3_finalize(end) } }
        let maximum = try statement("SELECT COALESCE(MAX(rec_id),0) FROM record"); defer { sqlite3_finalize(maximum) }
        guard sqlite3_step(maximum) == SQLITE_ROW, sqlite3_column_type(maximum, 0) == SQLITE_INTEGER else { throw CompanionNotificationError.unsupportedSchema }
        let high = sqlite3_column_int64(maximum, 0)
        let baseline = cursor == nil || cursor!.databaseHint != databaseHint || cursor!.highWatermark > high || cursor!.highWatermark < 0
        let generation = baseline ? UUID().uuidString : cursor!.generation
        let previous = baseline ? high : cursor!.highWatermark
        let count = contentAllowed ? 64 : 512
        let marks = apps.map { _ in "?" }.joined(separator: ",")
        let select = "SELECT r.rec_id,r.uuid,r.delivered_date,a.identifier" + (contentAllowed ? ",r.data" : "") + " FROM record r JOIN app a ON a.app_id=r.app_id WHERE r.delivered_date IS NOT NULL AND a.identifier IN (\(marks)) "
        var gaps: [String] = []
        if let cursor, baseline { gaps.append(cursor.databaseHint != databaseHint ? "database_replaced" : "id_regressed") }
        func fetch(_ suffix: String, maximum: Int) throws -> (records: [CompanionNotificationRecord], physicalIDs: [Int64]) {
            let s = try statement(select + suffix); defer { sqlite3_finalize(s) }
            for (index, app) in apps.enumerated() { sqlite3_bind_text(s, Int32(index + 1), app, -1, transient) }
            var records: [CompanionNotificationRecord] = []
            var physicalIDs: [Int64] = []
            while physicalIDs.count < maximum {
                let result = sqlite3_step(s)
                if result == SQLITE_DONE { break }; guard result == SQLITE_ROW else { throw Self.failure(result) }
                let recID = sqlite3_column_int64(s, 0)
                physicalIDs.append(recID)
                let uuid: String
                if sqlite3_column_type(s, 1) == SQLITE_BLOB, let bytes = sqlite3_column_blob(s, 1), sqlite3_column_bytes(s, 1) == 16 {
                    uuid = Data(bytes: bytes, count: 16).map { String(format: "%02x", $0) }.joined()
                } else if sqlite3_column_type(s, 1) == SQLITE_TEXT, let text = sqlite3_column_text(s, 1) {
                    uuid = String(cString: text).lowercased()
                } else { gaps.append("missing_uuid"); continue }
                guard !uuid.isEmpty && uuid.utf8.count <= 200, let bundle = sqlite3_column_text(s, 3) else { gaps.append("invalid_identity"); continue }
                guard [SQLITE_FLOAT, SQLITE_INTEGER].contains(sqlite3_column_type(s, 2)) else { gaps.append("invalid_source_time"); continue }
                let app = String(cString: bundle), sourceDate = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(s, 2))
                guard sourceDate.timeIntervalSince1970.isFinite, sourceDate <= now.addingTimeInterval(300), recID > 0 else { gaps.append("invalid_source_time"); continue }
                var privacy: CompanionPrivacyClass = .personal, malformed = false, digest = "metadata_only"
                if contentAllowed {
                    let size = Int(sqlite3_column_bytes(s, 4))
                    if let bytes = sqlite3_column_blob(s, 4), size > 0 && size <= 65536 {
                        let data = Data(bytes: bytes, count: size)
                        digest = NativeCompanionData.hash(data.base64EncodedString())
                        let result: (CompanionPrivacyClass, Bool) = autoreleasepool {
                            guard let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any], let request = object["req"] as? [String: Any] else { return (.restricted, true) }
                            let fields = [request["titl"], request["subt"], request["body"]].compactMap { $0 }
                            guard !fields.contains(where: { !($0 is String) }) else { return (.restricted, true) }
                            return (Self.sensitivity(app: app, text: fields.compactMap { $0 as? String }.joined(separator: " ")), false)
                        }
                        privacy = result.0; malformed = result.1
                    } else { malformed = true; privacy = .restricted; digest = "invalid_content" }
                }
                records.append(.init(recordID: recID, stableID: NativeCompanionData.hash(app + ":" + uuid),
                    fingerprint: NativeCompanionData.hash("\(sourceDate.timeIntervalSinceReferenceDate):\(digest)"), sourceAt: sourceDate, privacy: privacy, malformedContent: malformed))
            }
            return (records, physicalIDs)
        }
        var records: [CompanionNotificationRecord]
        let hasMore: Bool
        var nextHigh = high
        if baseline {
            let page = try fetch("ORDER BY r.rec_id DESC LIMIT \(count + 1)", maximum: count + 1)
            records = page.records; hasMore = false
            if page.physicalIDs.count > count {
                gaps.append("baseline_truncated"); let cutoff = page.physicalIDs[count - 1]
                records = records.filter { $0.recordID >= cutoff }
            }
        } else {
            let page = try fetch("AND r.rec_id>\(previous) ORDER BY r.rec_id ASC LIMIT \(count + 1)", maximum: count + 1)
            records = page.records; hasMore = page.physicalIDs.count > count
            if hasMore {
                nextHigh = page.physicalIDs[count - 1]
                records = records.filter { $0.recordID <= nextHigh }
            }
            // Cursor progress follows physical rows, even when malformed payload/identity rows are skipped.
            let overlap = try fetch("AND r.rec_id<=\(previous) ORDER BY r.delivered_date DESC,r.rec_id DESC LIMIT 128", maximum: 128)
            records += overlap.records
            if overlap.physicalIDs.count == 128 { gaps.append("overlap_bounded") }
        }
        var seen = Set<String>()
        records = records.sorted { $0.recordID > $1.recordID }.filter { seen.insert($0.stableID).inserted }
        return .init(records: records, cursor: .init(databaseHint: databaseHint, generation: generation, highWatermark: nextHigh), baseline: baseline, hasMore: hasMore, gaps: Array(Set(gaps)).sorted(), scopeRevision: Self.scopeRevision(apps: apps, content: contentAllowed))
    }
    static func sensitivity(app: String, text: String) -> CompanionPrivacyClass {
        let identity = app.lowercased()
        if ["mobilesms", "wechat", "xinwechat", "telegram", "whatsapp", "signal", "bank", "health", "password", "authenticator"].contains(where: { identity.contains($0) }) { return .restricted }
        let value = text.lowercased()
        if ["验证码", "校验码", "一次性", "密码", "口令", "交易", "支付", "医疗", "处方", "verification code", "one-time", "password", "otp", "bank account"].contains(where: { value.contains($0) }) { return .restricted }
        // No free-text summary or body leaves this reader, even when the local content classifier is enabled.
        return .personal
    }
}
