import Foundation
import SQLite3

private final class NotificationFixture {
    let url: URL
    var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    init(_ url: URL) throws {
        self.url = url
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw NativeCompanionData.error("Cannot create notification fixture") }
        try execute("PRAGMA journal_mode=WAL"); try execute("PRAGMA wal_autocheckpoint=0")
        try execute("CREATE TABLE app(app_id INTEGER PRIMARY KEY,identifier TEXT)")
        try execute("CREATE TABLE record(rec_id INTEGER PRIMARY KEY,app_id INTEGER,uuid BLOB,data BLOB,delivered_date REAL)")
        try execute("INSERT INTO app VALUES (1,'fixture.allowed'),(2,'PRIVATE_UNSELECTED_APP')")
    }
    deinit { sqlite3_close(db) }
    func execute(_ sql: String, _ args: [Any] = []) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw NativeCompanionData.error("Fixture prepare failed") }
        defer { sqlite3_finalize(statement) }
        for (i, value) in args.enumerated() {
            let index = Int32(i + 1)
            if let value = value as? Data { _ = value.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(value.count), transient) } }
            else if let value = value as? String { sqlite3_bind_text(statement, index, value, -1, transient) }
            else if let value = value as? NSNumber { sqlite3_bind_double(statement, index, value.doubleValue) }
        }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else { throw NativeCompanionData.error("Fixture step failed") }
    }
    func insert(_ id: Int, app: Int = 1, uuid: UUID = UUID(), text: String = "Fixture local text", at now: Date) throws {
        var bytes = uuid.uuid
        let key = withUnsafeBytes(of: &bytes) { Data($0) }
        let data = try PropertyListSerialization.data(fromPropertyList: ["req": ["titl": "PRIVATE_SYNTHETIC_TITLE", "body": text]], format: .binary, options: 0)
        try execute("INSERT INTO record VALUES (?,?,?,?,?)", [id, app, key, data, now.timeIntervalSinceReferenceDate])
    }
}

enum CompanionNotificationTests {
    static func run(root: URL, check: (Bool, String) throws -> Void) throws {
        let directory = root.appendingPathComponent("notification-fixtures")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixture = try NotificationFixture(directory.appendingPathComponent("usernoted.db"))
        let now = Date(), source = NativeNotificationPerception.source
        try fixture.insert(1, at: now.addingTimeInterval(-60)); try fixture.insert(2, app: 2, text: "PRIVATE_UNSELECTED_TEXT", at: now)
        let store = try NativeCompanionStore(root: directory.appendingPathComponent("controller"))
        var policy = CompanionPerceptionPolicy(); policy.allowedUses = [.audit]; policy.resourceScopeRevision = CompanionNotificationDatabase.scopeRevision(apps: ["fixture.allowed"], content: false)
        policy = try store.setPerceptionConsent(source: source, enabled: true, policy: policy)
        func read(_ cursor: CompanionNotificationCursor?, content: Bool = false) throws -> CompanionNotificationBatch {
            let reader = try CompanionNotificationDatabase(url: fixture.url)
            try check(reader.isReadOnly, "Notification source connections are opened strictly read-only")
            let batch = try reader.read(cursor: cursor, apps: ["fixture.allowed"], contentAllowed: content, now: now)
            try check(content ? reader.contentColumnReads > 0 : reader.contentColumnReads == 0, content ? "Local content classification requires an explicit content-column grant" : "Metadata mode never authorizes reading the notification BLOB column")
            return batch
        }
        let baseline = try read(nil)
        let initial = try store.commitNotifications(baseline, source: source, epoch: policy.consentEpoch, now: now)
        try check(baseline.records.count == 1 && initial.baseline && initial.observed == 0, "Initial notification baseline is silent and excludes unselected Apps")
        let stable = UUID()
        try fixture.insert(3, uuid: stable, text: "verification code 654321", at: now)
        let fresh = try read(baseline.cursor)
        let changed = try store.commitNotifications(fresh, source: source, epoch: policy.consentEpoch, now: now)
        try check(!fresh.baseline && changed.observed == 1 && changed.duplicates == 1, "A read-only source sees committed WAL changes without replaying its baseline")
        let again = try read(fresh.cursor)
        try check(try store.commitNotifications(again, source: source, epoch: policy.consentEpoch, now: now).observed == 0, "Repeated metadata polling does not create duplicate notification events")
        try fixture.execute("UPDATE record SET delivered_date=? WHERE rec_id=3", [now.addingTimeInterval(10).timeIntervalSinceReferenceDate])
        let revised = try read(again.cursor)
        let update = try store.commitNotifications(revised, source: source, epoch: policy.consentEpoch, now: now)
        try check(update.observed == 1 && (try store.rows("SELECT revision FROM perception_events WHERE source=?", [source])).first?["revision"] as? Int == 2, "Notification updates keep stable identity while incrementing the normalized revision")
        policy.resourceScopeRevision = CompanionNotificationDatabase.scopeRevision(apps: ["fixture.allowed"], content: true)
        policy = try store.setPerceptionConsent(source: source, enabled: true, policy: policy)
        let contentBaseline = try read(nil, content: true)
        let classified = try store.commitNotifications(contentBaseline, source: source, epoch: policy.consentEpoch, now: now)
        try check(classified.restricted == 1 && classified.observed == 0, "OTP content is classified locally as restricted, even when content inspection is explicitly enabled")
        let body = try PropertyListSerialization.data(fromPropertyList: ["req": ["body": "new verification code 987654"]], format: .binary, options: 0)
        try fixture.execute("UPDATE record SET data=? WHERE rec_id=3", [body])
        let bodyUpdate = try read(contentBaseline.cursor, content: true)
        try check(try store.commitNotifications(bodyUpdate, source: source, epoch: policy.consentEpoch, now: now).observed == 1, "Authorized local content fingerprints detect updates even when the delivery time is unchanged")
        let text = NativeCompanionData.string(try store.rows("SELECT * FROM perception_events")) + NativeCompanionData.string(try store.rows("SELECT * FROM notification_versions")) + NativeCompanionData.string(try store.rows("SELECT * FROM perception_cursors"))
        try check(!text.contains("PRIVATE_SYNTHETIC_TITLE") && !text.contains("987654") && !text.contains("PRIVATE_UNSELECTED_TEXT") && (try store.rows("SELECT id FROM memory_items")).isEmpty, "Notification bodies and titles never enter event payloads, cursor data or role memories")
        let reopened = try NativeCompanionStore(root: store.root)
        let saved = try reopened.notificationCursor(source: source, epoch: policy.consentEpoch)
        let afterRestart = try read(saved, content: true)
        try check(!afterRestart.baseline && (try reopened.commitNotifications(afterRestart, source: source, epoch: policy.consentEpoch, now: now)).observed == 0, "A restart resumes the durable cursor without replaying notification history")
        let oldEpoch = policy.consentEpoch
        policy = try store.setPerceptionConsent(source: source, enabled: false, policy: policy)
        var denied = false
        do { _ = try store.commitNotifications(bodyUpdate, source: source, epoch: oldEpoch, now: now) } catch { denied = error as? CompanionNotificationError == .consentChanged }
        try check(denied && (try store.rows("SELECT * FROM notification_versions")).isEmpty && (try store.rows("SELECT * FROM perception_cursors WHERE source=?", [source])).isEmpty, "Revocation clears notification fingerprints/cursors and rejects late commits")
        policy.resourceScopeRevision = CompanionNotificationDatabase.scopeRevision(apps: ["fixture.allowed"], content: false)
        policy = try store.setPerceptionConsent(source: source, enabled: true, policy: policy)
        let reenabled = try read(nil)
        _ = try store.commitNotifications(reenabled, source: source, epoch: policy.consentEpoch, now: now)
        try fixture.execute("BEGIN")
        for id in 4...523 { try fixture.insert(id, at: now) }
        try fixture.execute("COMMIT")
        let firstPage = try read(reenabled.cursor)
        let firstResult = try store.commitNotifications(firstPage, source: source, epoch: policy.consentEpoch, now: now)
        let secondPage = try read(firstPage.cursor)
        let secondResult = try store.commitNotifications(secondPage, source: source, epoch: policy.consentEpoch, now: now)
        try check(firstPage.hasMore && firstResult.observed == 512 && !secondPage.hasMore && secondResult.observed == 8, "Incremental pagination processes more than one full page with identical source timestamps")
        try fixture.insert(524, at: now.addingTimeInterval(-10 * 86400))
        let late = try read(secondPage.cursor)
        try check(try store.commitNotifications(late, source: source, epoch: policy.consentEpoch, now: now).observed == 1, "New records with old source dates are found through the independent record cursor")
        try fixture.insert(525, uuid: stable, at: now.addingTimeInterval(20))
        let reused = try read(late.cursor)
        let moved = try store.commitNotifications(reused, source: source, epoch: policy.consentEpoch, now: now)
        try check(moved.observed == 1 && moved.gaps.contains("identity_record_moved"), "Reused notification identity at a different record ID is versioned and explicitly flagged")
        try fixture.execute("BEGIN")
        for id in 526...1045 { try fixture.insert(id, at: now) }
        try fixture.execute("UPDATE record SET uuid=NULL WHERE rec_id=526")
        try fixture.execute("COMMIT")
        let malformedPage = try read(reused.cursor)
        let validFirst = try store.commitNotifications(malformedPage, source: source, epoch: policy.consentEpoch, now: now)
        let remainingPage = try read(malformedPage.cursor)
        let validRest = try store.commitNotifications(remainingPage, source: source, epoch: policy.consentEpoch, now: now)
        try check(malformedPage.hasMore && malformedPage.gaps.contains("missing_uuid") && validFirst.observed + validRest.observed == 519, "Malformed rows cannot cause the pagination cursor to skip valid records on later pages")
        let replacement = try NotificationFixture(directory.appendingPathComponent("replacement.db"))
        try replacement.insert(1, uuid: stable, at: now)
        let replaced = try CompanionNotificationDatabase(url: replacement.url).read(cursor: late.cursor, apps: ["fixture.allowed"], contentAllowed: false, now: now)
        try check(replaced.baseline && replaced.gaps.contains("database_replaced") && (try store.commitNotifications(replaced, source: source, epoch: policy.consentEpoch, now: now)).observed == 0, "Database replacement establishes a new silent generation rather than replaying reused IDs")
        try replacement.execute("UPDATE record SET data=? WHERE rec_id=1", [Data([0, 1, 2])])
        let malformed = try CompanionNotificationDatabase(url: replacement.url).read(cursor: replaced.cursor, apps: ["fixture.allowed"], contentAllowed: true, now: now)
        try check(malformed.records.first?.malformedContent == true && malformed.records.first?.privacy == .restricted, "Unknown notification payload formats are classified conservatively without inventing content")
        var scopeDenied = false
        do { _ = try store.commitNotifications(malformed, source: source, epoch: policy.consentEpoch, now: now) } catch { scopeDenied = error as? CompanionNotificationError == .consentChanged }
        try check(scopeDenied, "A content-inspecting batch cannot be committed under a metadata-only consent scope")
        let brokenURL = directory.appendingPathComponent("incompatible.db")
        var broken: OpaquePointer?; sqlite3_open(brokenURL.path, &broken); sqlite3_close(broken)
        var unsupported = false
        do { _ = try CompanionNotificationDatabase(url: brokenURL) } catch { unsupported = error as? CompanionNotificationError == .unsupportedSchema }
        try check(unsupported, "An incompatible notification schema is reported explicitly instead of appearing empty")
        let wideID: Int64 = 9_007_199_254_741_001
        var wideUUID = UUID().uuid
        let wideBytes = withUnsafeBytes(of: &wideUUID) { Data($0) }
        try fixture.execute("INSERT INTO record VALUES (9007199254741001,1,?,NULL,?)", [wideBytes, now.timeIntervalSinceReferenceDate])
        let wide = try read(store.notificationCursor(source: source, epoch: policy.consentEpoch))
        _ = try store.commitNotifications(wide, source: source, epoch: policy.consentEpoch, now: now)
        let persistedID = try store.rows("SELECT MAX(record_id) AS id FROM notification_versions WHERE source=?", [source]).first?["id"] as? Int ?? 0
        try check(wide.cursor.highWatermark == wideID && Int64(persistedID) == wideID, "SQLite notification cursors and identity metadata preserve 64-bit IDs beyond floating-point precision")
        try fixture.execute("PRAGMA journal_mode=DELETE")
        try fixture.execute("BEGIN EXCLUSIVE")
        var busy = false
        do { _ = try CompanionNotificationDatabase(url: fixture.url) } catch { busy = error as? CompanionNotificationError == .temporarilyUnavailable }
        try fixture.execute("ROLLBACK")
        try check(busy, "A locked notification source is temporarily unavailable rather than an empty notification history")
    }
}

private final class NotificationSignals {
    private let lock = NSLock()
    private var values: [CompanionNotificationSignal] = []
    func add(_ value: CompanionNotificationSignal) { lock.withLock { values.append(value) } }
    func all() -> [CompanionNotificationSignal] { lock.withLock { values } }
}
extension CompanionNotificationTests {
    static func runLifecycle(root: URL, check: (Bool, String) throws -> Void) async throws {
        let directory = root.appendingPathComponent("notification-lifecycle")
        let sourceDir = directory.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        let fixture = try NotificationFixture(sourceDir.appendingPathComponent("db"))
        try fixture.insert(1, at: Date())
        let store = try NativeCompanionStore(root: directory.appendingPathComponent("controller"))
        var policy = CompanionPerceptionPolicy(); policy.allowedUses = [.audit]
        policy.resourceScopeRevision = CompanionNotificationDatabase.scopeRevision(apps: ["fixture.allowed"], content: false)
        policy = try store.setPerceptionConsent(source: NativeNotificationPerception.source, enabled: true, policy: policy)
        let signals = NotificationSignals()
        let sensor = NativeNotificationPerception(store: store, url: fixture.url, sink: signals.add)
        await sensor.configure(epoch: policy.consentEpoch, apps: ["fixture.allowed"], contentAllowed: false, sleeping: true)
        try await Task.sleep(nanoseconds: 100_000_000)
        try check(signals.all().isEmpty, "Sleeping notification sensors neither open a source nor emit a baseline")
        await sensor.configure(epoch: policy.consentEpoch, apps: ["fixture.allowed"], contentAllowed: false, sleeping: false)
        let readyDeadline = Date().addingTimeInterval(5)
        while !signals.all().contains(where: { $0.baseline }), Date() < readyDeadline { try await Task.sleep(nanoseconds: 20_000_000) }
        try check(signals.all().contains { $0.baseline && $0.state == "available" }, "The native notification actor establishes its read-only baseline after enabling")
        try fixture.insert(2, at: Date())
        let changeDeadline = Date().addingTimeInterval(8)
        while !signals.all().contains(where: { $0.observed == 1 }), Date() < changeDeadline { try await Task.sleep(nanoseconds: 50_000_000) }
        try check(signals.all().contains { $0.observed == 1 }, "Native file events and debounce detect a real fixture WAL update without polling a model")
        await sensor.stop()
        let count = signals.all().count
        try fixture.insert(3, at: Date())
        try await Task.sleep(nanoseconds: 3_000_000_000)
        try check(signals.all().count == count, "Stopping the notification actor cancels watcher/debounce callbacks and further source reads")
    }
}
