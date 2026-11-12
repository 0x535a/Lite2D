import Foundation

struct NativeObservedSession {
    let backend: String
    let id: String
    var project: String?
    var title: String
    var updated: Double
    var created: Double?
    var file: URL?
    var object: CompanionObject {
        var value: CompanionObject = ["backend": backend, "id": id, "title": title, "updated": updated]
        if let project { value["project"] = project }; if let created { value["created"] = created }; return value
    }
    var roleReference: String { "activity_" + NativeCompanionData.hash(key) }
    var roleObject: CompanionObject {
        // A history update proves neither active typing nor a particular task.
        ["sessionRef": roleReference, "activityCategory": "unknown", "confidence": 0.3,
         "state": "unknown", "evidenceType": "agent_history_metadata", "updatedAt": updated,
         "instruction": "A history timestamp changed; activity, mood and task outcome are unknown."]
    }
    var key: String { "\(backend):\(id)" }
}

actor NativeCompanionObservers {
    let codexExecutable: String
    let helper: NativeClaudeHelper
    let watcher: NativeClaudeWatcher
    private var claudeEnabled = false
    private var claudeEpoch = 0
    private var claudeVersion = -1
    private var claudeReady = false
    private var claudeSessions: [NativeObservedSession] = []
    private var codex: NativeCompanionProcess?
    private var baselines: [String: Double] = [:]
    private var initialized = Set<String>()
    private var activities: [String: CompanionObject] = [:]
    init(codex: String, helper: NativeClaudeHelper, claudeRoot: URL? = nil) {
        codexExecutable = codex; self.helper = helper
        let base = claudeRoot ?? ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        watcher = NativeClaudeWatcher(directory: base.appendingPathComponent("projects"))
    }
    func setClaudeEnabled(_ enabled: Bool) async throws {
        guard claudeEnabled != enabled else { return }
        claudeEpoch += 1; claudeEnabled = enabled
        if enabled { try watcher.start(); claudeReady = false; claudeVersion = -1 }
        else { watcher.stop(); claudeSessions = []; claudeReady = false; await helper.stop(); reset("claude") }
    }
    private func claudeList() async throws -> [NativeObservedSession] {
        guard claudeEnabled else { throw NativeCompanionData.error("Claude observation disabled") }
        let snapshot = watcher.snapshot(), epoch = claudeEpoch
        if claudeReady {
            if snapshot.version == claudeVersion { return claudeSessions }
            if Date().timeIntervalSince(snapshot.last) < 2 && Date().timeIntervalSince(snapshot.first) < 30 { return claudeSessions }
        }
        var result: [NativeObservedSession] = [], offset = 0
        while true {
            let page = NativeCompanionData.array(try await helper.call("list", ["limit": 100, "offset": offset]))
            guard claudeEnabled && epoch == claudeEpoch else { throw NativeCompanionData.error("Claude access revoked") }
            for s in page {
                guard let id = s["sessionId"] as? String else { continue }
                result.append(.init(backend: "claude", id: id, project: s["cwd"] as? String,
                    title: NativeCompanionData.clean(s["title"] as? String ?? "Claude Code", limit: 150), updated: s["updated"] as? Double ?? 0, created: s["created"] as? Double))
            }
            if page.count < 100 { break }; offset += page.count
        }
        claudeSessions = result.sorted { $0.updated > $1.updated }; claudeReady = true; claudeVersion = snapshot.version
        watcher.resetQuietWindow(version: snapshot.version)
        return claudeSessions
    }
    func reconcileClaude() { watcher.markChanged() }
    func watcherVersion() -> Int { watcher.snapshot().version }
    private func codexClient() async throws -> NativeCompanionProcess {
        if let codex, codex.process.isRunning { return codex }
        let child = NativeCompanionProcess(); try child.start(codexExecutable, arguments: ["app-server", "--listen", "stdio://"])
        codex = child
        do {
            _ = try await child.rpc("initialize", ["clientInfo": ["name": "lite2d_companion_observer", "version": "1.2.0"], "capabilities": ["experimentalApi": false]])
            try child.write(["method": "initialized"]); return child
        } catch { child.close(); codex = nil; throw error }
    }
    func list(_ backend: String) async throws -> [NativeObservedSession] {
        if backend == "claude" { return try await claudeList() }
        var result: [NativeObservedSession] = []
        for archived in [false, true] {
            var cursor: String?, seen = Set<String>()
            repeat {
                let page: CompanionObject
                if backend == "opencode" {
                    let client = try NativeCompanionHTTP.discover()
                    var query = ["limit": "100", "archived": String(archived)]
                    if let cursor { query["cursor"] = cursor } else { query["order"] = "desc" }
                    page = try await client.get("api/session", query)
                    for s in NativeCompanionData.array(page["data"]) {
                        guard let id = s["id"] as? String, NativeCompanionData.object(s["metadata"])["lite2dCompanion"] as? Bool != true,
                              (s["title"] as? String ?? "").range(of: #"^Lite2D [\da-f-]{36}$"#, options: [.regularExpression, .caseInsensitive]) == nil else { continue }
                        let time = NativeCompanionData.object(s["time"])
                        result.append(.init(backend: backend, id: id, project: NativeCompanionData.object(s["location"])["directory"] as? String, title: NativeCompanionData.clean(s["title"] as? String ?? "OpenCode", limit: 150), updated: time["updated"] as? Double ?? 0, created: time["created"] as? Double))
                    }
                    cursor = NativeCompanionData.object(page["cursor"])["next"] as? String
                } else if backend == "codex" {
                    let client = try await codexClient()
                    var params: CompanionObject = ["archived": archived, "limit": 100, "sortKey": "updated_at", "sortDirection": "desc", "modelProviders": [], "useStateDbOnly": true,
                        "sourceKinds": ["cli", "vscode", "exec", "appServer", "subAgent", "subAgentReview", "subAgentCompact", "subAgentThreadSpawn", "subAgentOther", "unknown"]]
                    if let cursor { params["cursor"] = cursor }
                    page = try await client.rpc("thread/list", params)
                    for s in NativeCompanionData.array(page["data"]) {
                        guard let id = s["id"] as? String else { continue }
                        result.append(.init(backend: backend, id: id, project: s["cwd"] as? String, title: NativeCompanionData.clean(s["name"] as? String ?? s["preview"] as? String ?? "Codex", limit: 150), updated: (s["updatedAt"] as? Double ?? 0) * 1000, created: (s["createdAt"] as? Double).map { $0 * 1000 }))
                    }
                    cursor = page["nextCursor"] as? String
                } else { throw NativeCompanionData.error("Unknown observer") }
                if let cursor { guard !seen.contains(cursor) else { throw NativeCompanionData.error("Observer pagination did not advance") }; seen.insert(cursor) }
            } while cursor != nil
        }
        return Dictionary(result.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b }).values.sorted { $0.updated > $1.updated }
    }
    func recent(_ session: NativeObservedSession) async throws -> [CompanionObject] {
        if session.backend == "claude" {
            guard claudeEnabled else { throw NativeCompanionData.error("Claude observation disabled") }
            let epoch = claudeEpoch
            var params: CompanionObject = ["sessionId": session.id]
            if let project = session.project { params["dir"] = project }
            let rows = NativeCompanionData.array(try await helper.call("recent", params))
            guard claudeEnabled && epoch == claudeEpoch else { throw NativeCompanionData.error("Claude access revoked") }
            return rows.map { ["id": $0["id"] ?? "", "text": NativeCompanionData.clean($0["text"] as? String ?? "", limit: 2000)] }
        }
        let messages: [CompanionObject]
        if session.backend == "opencode" {
            messages = NativeCompanionData.array(try await NativeCompanionHTTP.discover().get("api/session/\(session.id)/message", ["limit": "8", "order": "desc"])["data"])
        } else {
            messages = NativeCompanionData.array(try await codexClient().rpc("thread/turns/list", ["threadId": session.id, "limit": 2, "sortDirection": "desc", "itemsView": "summary"])["data"])
        }
        return messages.compactMap { m in let text = NativeCompanionData.clean(NativeCompanionData.text(m), limit: 2000); return text.isEmpty ? nil : ["id": m["id"] as? String ?? m["uuid"] as? String ?? NativeCompanionData.hash(text), "text": text] }
    }
    func poll(_ backend: String, excluded: Set<String>) async throws -> (sessions: [NativeObservedSession], changes: [CompanionObject]) {
        let sessions = try await list(backend).filter { !excluded.contains($0.id) }
        let changed = sessions.filter { baselines[$0.key] != nil && baselines[$0.key] != $0.updated }
        let newcomers = initialized.contains(backend) ? sessions.filter { baselines[$0.key] == nil } : []
        let targets = Set((changed + newcomers + Array(sessions.prefix(6))).prefix(12).map(\.id))
        var changes: [CompanionObject] = []
        for s in sessions {
            let previous = baselines[s.key]
            guard targets.contains(s.id) else { if previous == nil && !initialized.contains(backend) { baselines[s.key] = s.updated }; continue }
            if backend == "claude", previous == s.updated, activities[s.key] != nil { continue }
            let messages = try await recent(s); let digest = NativeCompanionData.hash(NativeCompanionData.string(messages))
            baselines[s.key] = s.updated
            let old = activities[s.key]; if old?["digest"] as? String == digest { continue }
            var activity = s.object; activity["messages"] = messages; activity["digest"] = digest; activity["sessionRef"] = s.key; activity["sourceRef"] = "\(s.key):\(s.updated)"
            activities[s.key] = activity
            if old != nil || (previous != nil && previous != s.updated) || (previous == nil && initialized.contains(backend)) { changes.append(activity) }
        }
        let available = Set(sessions.map(\.key))
        for key in activities.keys where key.hasPrefix(backend + ":") && !available.contains(key) { activities.removeValue(forKey: key) }
        initialized.insert(backend); return (sessions, changes)
    }
    // Default perception path never requests message history/turn bodies.
    func pollMetadata(_ backend: String, excluded: Set<String>) async throws -> (sessions: [NativeObservedSession], changes: [CompanionObject]) {
        let listed = try await list(backend).filter { !excluded.contains($0.id) }
        let wasReady = initialized.contains("metadata:" + backend)
        var changes: [CompanionObject] = []
        let prefix = "metadata:"
        for session in listed {
            let key = prefix + session.key
            if wasReady, baselines[key] != session.updated {
                var change = session.roleObject
                change["backend"] = backend // Controller routing only; stripped before role generation.
                changes.append(change)
            }
            baselines[key] = session.updated
        }
        let available = Set(listed.map { prefix + $0.key })
        baselines = baselines.filter { !$0.key.hasPrefix(prefix + backend + ":") || available.contains($0.key) }
        initialized.insert("metadata:" + backend)
        return (listed, changes)
    }
    func activity(_ session: NativeObservedSession) async throws -> CompanionObject {
        if let existing = activities[session.key], existing["updated"] as? Double == session.updated { return existing }
        var value = session.object; value["messages"] = try await recent(session); value["sessionRef"] = session.key; activities[session.key] = value; return value
    }
    func recentWork() -> [CompanionObject] { Array(activities.values.sorted { ($0["updated"] as? Double ?? 0) > ($1["updated"] as? Double ?? 0) }.prefix(8)) }
    func reset(_ backend: String) { initialized.remove(backend); initialized.remove("metadata:" + backend); baselines = baselines.filter { !$0.key.hasPrefix(backend + ":") && !$0.key.hasPrefix("metadata:" + backend + ":") }; activities = activities.filter { !$0.key.hasPrefix(backend + ":") } }
    func close() async { watcher.stop(); claudeEnabled = false; claudeEpoch += 1; await helper.stop(); codex?.close(); codex = nil }
    func disable(_ backend: String) async {
        reset(backend)
        if backend == "claude" { try? await setClaudeEnabled(false) }
        if backend == "codex" { codex?.close(); codex = nil }
    }
}
