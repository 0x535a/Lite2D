import Foundation

struct CompanionNotificationSignal {
    var epoch: Int
    var state: String
    var baseline: Bool = false
    var observed = 0
    var duplicates = 0
    var restricted = 0
    var malformed = 0
    var gaps: [String] = []
}

extension NativeCompanionStore {
    func notificationSchema() throws {
        try execute("CREATE TABLE IF NOT EXISTS notification_versions(source TEXT NOT NULL,generation TEXT NOT NULL,identity TEXT NOT NULL,fingerprint TEXT NOT NULL,revision INTEGER NOT NULL,record_id INTEGER NOT NULL,last_seen REAL NOT NULL,PRIMARY KEY(source,generation,identity))")
        if try !rows("PRAGMA table_info(notification_versions)").contains(where: { $0["name"] as? String == "record_id" }) {
            try execute("ALTER TABLE notification_versions ADD COLUMN record_id INTEGER NOT NULL DEFAULT 0")
        }
    }
    func notificationCursor(source: String, epoch: Int) throws -> CompanionNotificationCursor? {
        guard let value = try rows("SELECT cursor FROM perception_cursors WHERE source=? AND epoch=?", [source, epoch]).first?["cursor"] as? String else { return nil }
        return try? CompanionProactiveCoding.decode(CompanionNotificationCursor.self, value)
    }
    func commitNotifications(_ batch: CompanionNotificationBatch, source: String, epoch: Int, now: Date = Date()) throws -> CompanionNotificationSignal {
        try transaction {
            guard let policy = try perceptionPolicy(source), policy.consentEpoch == epoch, policy.resourceScopeRevision == batch.scopeRevision,
                  policy.allowedCharacterIds.isEmpty, !policy.remoteInferenceAllowed, !policy.memoryAllowed else { throw CompanionNotificationError.consentChanged }
            var result = CompanionNotificationSignal(epoch: epoch, state: "available", baseline: batch.baseline, gaps: batch.gaps)
            if batch.baseline { try execute("DELETE FROM notification_versions WHERE source=?", [source]) }
            for item in batch.records {
                let old = try rows("SELECT fingerprint,revision,last_seen,record_id FROM notification_versions WHERE source=? AND generation=? AND identity=?", [source, batch.cursor.generation, item.stableID]).first
                if let previous = old?["record_id"] as? Int, previous != item.recordID { result.gaps.append("identity_record_moved") }
                if old?["fingerprint"] as? String == item.fingerprint {
                    result.duplicates += 1
                    if (old?["last_seen"] as? Double ?? 0) < now.addingTimeInterval(-3600).timeIntervalSince1970 || Int64(old?["record_id"] as? Int ?? -1) != item.recordID {
                        try execute("UPDATE notification_versions SET last_seen=?,record_id=? WHERE source=? AND generation=? AND identity=?", [now.timeIntervalSince1970, item.recordID, source, batch.cursor.generation, item.stableID])
                    }
                    continue
                }
                let revision = (old?["revision"] as? Int ?? 0) + 1
                try execute("INSERT OR REPLACE INTO notification_versions(source,generation,identity,fingerprint,revision,record_id,last_seen) VALUES (?,?,?,?,?,?,?)", [source, batch.cursor.generation, item.stableID, item.fingerprint, revision, item.recordID, now.timeIntervalSince1970])
                if item.privacy == .restricted { result.restricted += 1 }
                if item.malformedContent { result.malformed += 1 }
                guard !batch.baseline else { continue }
                var event = CompanionObservation(id: batch.cursor.generation + ":" + item.stableID, source: source, type: old == nil ? "notification.record_observed" : "notification.record_updated",
                    observedAt: now, sourceAt: item.sourceAt, subject: "notification_metadata", expiresAt: now.addingTimeInterval(120))
                event.revision = revision; event.privacyClass = item.privacy; event.originDevice = "unknown"; event.confidence = 0.8; event.policy = policy
                if try ingestPerception(event, now: now) != nil { result.observed += 1 }
            }
            try savePerceptionCursor(source: source, generation: batch.cursor.generation, cursor: CompanionProactiveCoding.encode(batch.cursor), epoch: epoch)
            try execute("DELETE FROM notification_versions WHERE source=? AND last_seen<?", [source, now.addingTimeInterval(-86400).timeIntervalSince1970])
            try execute("DELETE FROM notification_versions WHERE rowid IN (SELECT rowid FROM notification_versions WHERE source=? ORDER BY last_seen DESC LIMIT -1 OFFSET 8192)", [source])
            result.gaps = Array(Set(result.gaps)).sorted()
            return result
        }
    }
}

actor NativeNotificationPerception {
    static let source = "macos.notification.usernoted"
    static var defaultURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Group Containers/group.com.apple.usernoted/db2/db") }
    private let store: NativeCompanionStore
    private let url: URL
    private let sink: (CompanionNotificationSignal) -> Void
    private var watcher: CompanionPathWatch?
    private var epoch: Int?
    private var apps: [String] = []
    private var contentAllowed = false
    private var generation = 0
    private var loop: Task<Void, Never>?
    private var debounce: Task<Void, Never>?
    private var firstDirty: UInt64?
    private var burstDeadlinePending = false
    private var forceBaseline = false
    private var baselineReason: String?
    init(store: NativeCompanionStore, url: URL = NativeNotificationPerception.defaultURL, sink: @escaping (CompanionNotificationSignal) -> Void) {
        self.store = store; self.url = url; self.sink = sink
    }
    func configure(epoch: Int?, apps: [String], contentAllowed: Bool, sleeping: Bool) {
        let selected = Array(Set(apps)).sorted()
        let desired = sleeping ? nil : epoch
        if self.epoch == desired && self.apps == selected && self.contentAllowed == contentAllowed { return }
        stop(); self.epoch = desired; self.apps = selected; self.contentAllowed = contentAllowed
        guard let epoch = desired else { return }
        guard !selected.isEmpty else { sink(.init(epoch: epoch, state: "needs_allowlist")); return }
        guard selected.count <= 64 else { sink(.init(epoch: epoch, state: "error")); return }
        let expected = generation
        ensureWatcher(expected: expected)
        loop = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.poll(expected: expected)
                do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
            }
        }
    }
    private func ensureWatcher(expected: Int) {
        guard watcher == nil, epoch != nil, expected == generation else { return }
        do { watcher = try CompanionPathWatch(root: url.deletingLastPathComponent(), allowedNames: [url.lastPathComponent, url.lastPathComponent + "-wal"]) { [weak self] gap in Task { await self?.dirty(gap: gap, generation: expected) } } }
        catch { /* Timed health reconciliation remains available. */ }
    }
    private func dirty(gap: Bool, generation expected: Int) {
        guard expected == generation, epoch != nil else { return }
        forceBaseline = forceBaseline || gap
        if gap { baselineReason = "watcher_gap" }
        let now = DispatchTime.now().uptimeNanoseconds
        if firstDirty == nil { firstDirty = now }
        let overdue = now >= firstDirty! && now - firstDirty! >= 10_000_000_000
        if overdue && burstDeadlinePending { return }
        if overdue { burstDeadlinePending = true }
        debounce?.cancel()
        let delay = overdue ? 0.05 : 1.5
        debounce = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
            await self?.poll(expected: expected)
        }
    }
    private func poll(expected: Int) {
        guard expected == generation, let epoch else { return }
        firstDirty = nil; burstDeadlinePending = false
        ensureWatcher(expected: expected)
        do {
            // Fresh short-lived read-only connection sees the current WAL and survives database replacement.
            let reader = try CompanionNotificationDatabase(url: url)
            let cursor = forceBaseline ? nil : try store.notificationCursor(source: Self.source, epoch: epoch)
            var batch = try reader.read(cursor: cursor, apps: apps, contentAllowed: contentAllowed)
            if forceBaseline { batch.gaps.append(baselineReason ?? "source_restarted") }
            let result = try store.commitNotifications(batch, source: Self.source, epoch: epoch)
            forceBaseline = false; baselineReason = nil
            guard expected == generation else { return }
            sink(result)
            if batch.hasMore { dirty(gap: false, generation: expected) }
        } catch let error as CompanionNotificationError {
            if [.permissionDenied, .unsupportedSchema, .notSupported].contains(error) {
                watcher?.stop(); watcher = nil; forceBaseline = true; baselineReason = "source_access_gap"
                try? store.invalidatePerceptionSource(Self.source)
            }
            if error != .consentChanged { sink(.init(epoch: epoch, state: error.rawValue)) }
        } catch { sink(.init(epoch: epoch, state: "temporarily_unavailable")) }
    }
    func stop() {
        generation += 1; epoch = nil
        loop?.cancel(); loop = nil; debounce?.cancel(); debounce = nil
        watcher?.stop(); watcher = nil; firstDirty = nil; burstDeadlinePending = false; forceBaseline = false; baselineReason = nil
    }
}
