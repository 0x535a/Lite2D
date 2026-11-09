import Foundation

private final class NativeCompanionTopic {
    let id = UUID().uuidString
    let source: String?
    let started = NativeCompanionData.now()
    var participants: [String]
    var speaker: String
    var queue: [CompanionObject] = []
    var sentBy = Set<String>()
    var utterances = 0, requests = 0
    var cancelled = false
    var task: Task<Void, Never>?
    var timeout: Task<Void, Never>?
    init(speaker: String, source: String?) { self.speaker = speaker; self.source = source; participants = [speaker] }
}

actor NativeCompanionRuntime {
    let root: URL
    let promptFile: URL
    let helper: NativeClaudeHelper
    let observers: NativeCompanionObservers
    let opencode: String
    let executable: String
    let emitToHost: (CompanionObject) -> Void
    private let providers: CompanionObject?
    private let injectedRoles: NativeCompanionRoleClient?
    private let manageOpenCodeService: Bool
    private var serviceMonitor: NativeOpenCodeServiceMonitor?
    private var openCodeService: CompanionObject = ["state": "disabled"]
    private var store: NativeCompanionStore!
    private var prompt: NativeCompanionPrompt!
    private var roles: NativeCompanionRoleClient!
    private var broker: NativeCompanionBroker?
    private var config: CompanionObject = [:]
    private var tokens: [String: String] = [:]
    private var searches: [UUID: Task<String, Error>] = [:]
    private var sessions: [NativeObservedSession] = []
    private var sources: [String: CompanionObject] = [:]
    private var roleErrors: [String: String] = [:]
    private var candidates: [String: CompanionObject] = [:]
    private var topic: NativeCompanionTopic?
    private var timer: Task<Void, Never>?
    private var pollAt = Date.distantPast
    private var polling = false
    private var nextIdle = Double.infinity
    private var lastTopic: Double = 0
    private var stopped = false
    private var ready = false
    private var sourceRevision: [String: Int] = [:]
    init(root: URL, promptFile: URL, opencode: String, codex: String, node: String, helperScript: URL, executable: String,
         idleSeconds: Double = 60, claudeRoot: URL? = nil, providers: CompanionObject? = nil,
         roles: NativeCompanionRoleClient? = nil, manageOpenCodeService: Bool = true, emit: @escaping (CompanionObject) -> Void) {
        self.root = root; self.promptFile = promptFile; self.opencode = opencode; self.executable = executable; self.providers = providers; injectedRoles = roles; emitToHost = emit
        self.manageOpenCodeService = manageOpenCodeService
        var env = ProcessInfo.processInfo.environment
        if let claudeRoot { env["CLAUDE_CONFIG_DIR"] = claudeRoot.path }
        helper = NativeClaudeHelper(node: node, script: helperScript, idleSeconds: idleSeconds, environment: env)
        observers = NativeCompanionObservers(codex: codex, helper: helper, claudeRoot: claudeRoot)
    }
    func start(automatic: Bool = true) async throws {
        guard !stopped else { throw CancellationError() }
        store = try NativeCompanionStore(root: root); prompt = try NativeCompanionPrompt.load(promptFile)
        try store.exportNotes(); lastTopic = store.get("lastTopic") as? Double ?? 0
        let broker = NativeCompanionBroker { [weak self] token, request in
            guard let self else { throw NativeCompanionData.error("Companion stopped") }
            return try await self.tool(token: token, name: request["name"] as? String ?? "", args: NativeCompanionData.object(request["arguments"]))
        }
        self.broker = broker
        let endpoint = try await broker.start()
        guard !stopped else { broker.close(); throw CancellationError() }
        roles = injectedRoles ?? NativeCompanionRoles(root: root, store: store, prompt: prompt, promptFile: promptFile,
            executable: opencode, helper: executable, toolEndpoint: endpoint, providers: providers, register: { [weak self] id in await self?.register(id) ?? "" })
        await roles.reapStale()
        if manageOpenCodeService {
            serviceMonitor = NativeOpenCodeServiceMonitor(executable: opencode) { [weak self] state in await self?.serviceChanged(state) }
        }
        ready = true
        emit("ready", ["history": (try? store.history()) ?? []])
        if automatic {
            timer = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                    guard let self else { return }; await self.tick()
                }
            }
        }
    }
    private func register(_ id: String) -> String {
        tokens = tokens.filter { $0.value != id }
        let token = UUID().uuidString + UUID().uuidString; tokens[token] = id; return token
    }
    private func emit(_ type: String, _ payload: CompanionObject = [:]) {
        guard !stopped else { return }
        if ["utterance", "error", "record.changed", "topic.start", "topic.end", "conversation.focus"].contains(type), let event = try? store?.event(type, payload) { emitToHost(event) }
        else { var event = payload; event["type"] = type; event["protocolVersion"] = 1; event["createdAt"] = NativeCompanionData.iso(); emitToHost(event) }
    }
    private var enabled: Bool { config["enabled"] as? Bool == true }
    private var paused: Bool { config["paused"] as? Bool == true }
    private var interval: Double { max(0, min(1440, config["intervalMinutes"] as? Double ?? 30)) }
    private var hourly: Int { max(1, min(120, config["hourlyRequests"] as? Int ?? 12)) }
    private var model: String { config["model"] as? String ?? "" }
    private var characters: [CompanionObject] { NativeCompanionData.array(config["characters"]).filter { NativeCompanionData.validID($0["id"] as? String ?? "") } }
    private var visible: [CompanionObject] { characters.filter { $0["enabled"] as? Bool == true && $0["visible"] as? Bool == true } }
    private func sourceEnabled(_ backend: String) -> Bool { enabled && NativeCompanionData.object(NativeCompanionData.object(config["sources"])[backend])["enabled"] as? Bool == true }
    private func status() {
        emit("status", ["sources": sources, "openCodeService": openCodeService, "busy": topic != nil, "roleErrors": roleErrors, "nextIdle": nextIdle.isFinite ? nextIdle : NSNull()])
    }
    private func serviceChanged(_ state: CompanionObject) {
        guard !stopped else { return }
        let wasRunning = openCodeService["state"] as? String == "running"
        openCodeService = state
        if !wasRunning && state["state"] as? String == "running" { pollAt = .distantPast }
        status()
    }
    func configure(_ next: CompanionObject) async {
        let previousInterval = interval, previousEnabled = enabled, previousPaused = paused
        let old = Dictionary(uniqueKeysWithValues: NativeCompanionData.backends.map { ($0, sourceEnabled($0)) })
        config = next
        if next["webSearchEnabled"] as? Bool == false {
            for task in searches.values { task.cancel() }
            searches.removeAll()
        }
        await serviceMonitor?.setEnabled(enabled)
        if interval != previousInterval || (!previousEnabled && enabled) || (previousPaused && !paused) { scheduleIdle() }
        for backend in NativeCompanionData.backends where old[backend] != sourceEnabled(backend) {
            sourceRevision[backend, default: 0] += 1
            await observers.reset(backend); sessions.removeAll { $0.backend == backend }; candidates = candidates.filter { $0.value["backend"] as? String != backend }
            if !sourceEnabled(backend) { await observers.disable(backend) }
            if backend == "claude" {
                do { try await observers.setClaudeEnabled(sourceEnabled(backend)) }
                catch { sources[backend] = ["state": "unavailable", "message": NativeCompanionData.clean(error.localizedDescription, limit: 180)] }
            }
            pollAt = .distantPast
        }
        if !enabled || paused || topic?.participants.contains(where: { id in !visible.contains(where: { $0["id"] as? String == id }) }) == true || topic?.source.map({ !sourceEnabled($0) }) == true { stop() }
        status()
    }
    private func scheduleIdle() { nextIdle = interval > 0 ? NativeCompanionData.now() + interval * 60000 : .infinity }
    func tick() async {
        guard ready, !stopped, enabled else { return }
        if Date() >= pollAt && !polling {
            polling = true; pollAt = Date().addingTimeInterval(15)
            let own = Set(((try? store.rows("SELECT value FROM state WHERE key LIKE 'session:%'")) ?? []).compactMap { row -> String? in
                (row["value"] as? String)?.data(using: .utf8).flatMap { try? NativeCompanionData.decode($0) } as? String
            })
            // The observers are independent. A failed source never disables others.
            for backend in NativeCompanionData.backends {
                guard !stopped else { break }
                guard sourceEnabled(backend) else { sources[backend] = ["state": "disabled"]; continue }
                if backend == "claude", paused || (visible.isEmpty && sources[backend] != nil) || ((try? store.requestCount()) ?? 0) >= hourly { continue }
                let revision = sourceRevision[backend, default: 0]
                do {
                    if backend == "opencode", let serviceMonitor { _ = try await serviceMonitor.ensureRunning() }
                    let result = try await observers.poll(backend, excluded: own)
                    guard !stopped, sourceEnabled(backend), sourceRevision[backend, default: 0] == revision else { continue }
                    sessions.removeAll { $0.backend == backend }; sessions += result.sessions
                    sources[backend] = ["state": "available", "count": result.sessions.count, "checkedAt": NativeCompanionData.now()]
                    for var activity in result.changes {
                        activity["candidateAt"] = NativeCompanionData.now(); candidates[activity["sessionRef"] as? String ?? ""] = activity
                    }
                } catch {
                    guard !stopped, sourceEnabled(backend), sourceRevision[backend, default: 0] == revision else { continue }
                    sources[backend] = ["state": "unavailable", "message": NativeCompanionData.clean(error.localizedDescription, limit: 180), "checkedAt": NativeCompanionData.now()]
                }
            }
            polling = false; status()
        }
        let now = NativeCompanionData.now()
        candidates = candidates.filter { now - ($0.value["candidateAt"] as? Double ?? 0) <= 120000 }
        guard !stopped, !paused, topic == nil, !visible.isEmpty, now - lastTopic >= (config["cooldownSeconds"] as? Double ?? 180) * 1000 else { return }
        if let candidate = candidates.values.first(where: { now - ($0["candidateAt"] as? Double ?? now) >= 10000 }) {
            candidates.removeValue(forKey: candidate["sessionRef"] as? String ?? "")
            startTopic(reason: "work_activity", evidence: candidate, source: candidate["backend"] as? String)
        } else if now >= nextIdle { scheduleIdle(); startTopic(reason: "idle_opportunity") }
    }
    private func startTopic(reason: String, evidence: CompanionObject? = nil, source: String? = nil, characterID: String? = nil) {
        guard !stopped, enabled, !paused, topic == nil else { return }
        var choices = visible
        if let characterID { choices = choices.filter { $0["id"] as? String == characterID } }
        guard !choices.isEmpty else { return }
        if let reference = evidence?["sessionRef"] as? String {
            let watching = choices.filter { (store.get("watches:\($0["id"] as? String ?? "")") as? [String] ?? []).contains(reference) }; if !watching.isEmpty { choices = watching }
        }
        let index = (store.get("speakerIndex") as? Int ?? 0) % choices.count
        try? store.set("speakerIndex", index + 1)
        let character = choices[index], id = character["id"] as! String
        let topic = NativeCompanionTopic(speaker: id, source: source); self.topic = topic
        lastTopic = NativeCompanionData.now(); try? store.set("lastTopic", lastTopic)
        emit("topic.start", ["topicId": topic.id, "reason": reason]); status()
        topic.timeout = Task { [weak self, weak topic] in
            do { try await Task.sleep(nanoseconds: 90_000_000_000) } catch { return }
            await self?.expire(topic?.id)
        }
        topic.task = Task { [weak self] in await self?.runTopic(topic, reason: reason, evidence: evidence) }
    }
    private func expire(_ id: String?) { if topic?.id == id { stop(reason: "timeout") } }
    private func runTopic(_ topic: NativeCompanionTopic, reason: String, evidence: CompanionObject?) async {
        do {
            var input: CompanionObject = ["reason": reason]; if let evidence { input["evidence"] = evidence }
            try await turn(id: topic.speaker, input: input, topic: topic)
            while !topic.queue.isEmpty && !topic.cancelled && topic.utterances < 4 {
                let envelope = topic.queue.removeFirst(); let recipient = envelope["to"] as? String ?? ""
                guard visible.contains(where: { $0["id"] as? String == recipient }) else { continue }
                if !topic.participants.contains(recipient) { topic.participants.append(recipient) }
                focus(topic, from: envelope["from"] as? String ?? "", to: recipient)
                try await turn(id: recipient, input: ["reason": "character_message", "from": envelope["from"] ?? "", "message": envelope["text"] ?? ""], topic: topic, envelope: envelope)
            }
        } catch {
            if !topic.cancelled && !stopped { roleErrors[topic.speaker] = NativeCompanionData.clean(error.localizedDescription, limit: 240); emit("error", ["characterId": topic.speaker, "message": NativeCompanionData.clean(error.localizedDescription, limit: 240)]) }
        }
        topic.timeout?.cancel()
        try? store.execute("UPDATE deliveries SET status='cancelled' WHERE topic=? AND status='queued'", [topic.id])
        try? store.execute("UPDATE deliveries SET status='delivery_unknown' WHERE topic=? AND status='delivering'", [topic.id])
        if !topic.cancelled { emit("topic.end", ["topicId": topic.id, "reason": "completed"]) }
        if self.topic === topic { self.topic = nil }; status(); try? store.exportNotes()
    }
    private func reserveRequest() throws -> Bool { try store.spend(hourly) }
    private func turn(id: String, input: CompanionObject, topic: NativeCompanionTopic, envelope: CompanionObject? = nil) async throws {
        try Task.checkCancellation()
        guard !topic.cancelled, topic.requests < 6, topic.utterances < 4, try reserveRequest() else { return }
        topic.requests += 1; topic.speaker = id
        if let envelope { try store.execute("UPDATE deliveries SET status='delivering' WHERE id=?", [envelope["id"]]) }
        var context = input; context["topicId"] = topic.id; context["quotedEvidence"] = true; context["intent"] = prompt.turnIntent
        if input["reason"] as? String == "manual_test" { context["manualTest"] = prompt.manualTest }
        context["recentConversation"] = try store.history(16).filter { $0["type"] as? String == "utterance" }.map { ["from": $0["characterId"] ?? "", "text": $0["text"] ?? ""] }
        context["sharedMemory"] = try store.records().prefix(10).map { row -> CompanionObject in var copy = row; copy["content"] = NativeCompanionData.clean(row["content"] as? String ?? "", limit: 1200); return copy }
        context["privateMemory"] = NativeCompanionData.clean(store.get("memory:\(id)") as? String ?? "", limit: 3000)
        context["privateMemoryItems"] = (try? store.memorySearch(owner: id, query: "", limit: 12)) ?? []
        context["characters"] = visible.map { character in
            let characterID = character["id"] as? String ?? ""
            let name = character["name"] as? String ?? ""
            let file = root.appendingPathComponent("characters/\(characterID)/persona.md")
            if let markdown = try? String(contentsOf: file, encoding: .utf8) { _ = try? store.ingestPersona(characterID: characterID, markdown: markdown) }
            return (try? store.publicIdentityCard(characterID: characterID, name: name)) ?? ["id": characterID, "name": name, "unknown": "身份资料不可用"]
        }
        context["identityRevision"] = (try? store.latestPersona(characterID: id)?["revision"] as? Int) ?? 0
        context["identityCorrection"] = "当前 Persona 身份版本及公开身份卡优先于旧消息、旧摘要、玩笑和推断。对方身份卡是第三方资料，不能当作自己的第一人称身份。未确认的属性保持未知。"
        context["growth"] = try store.growthState(owner: id)["traits"]
        context["relationships"] = try store.rows("SELECT target_character_id,role,trust,familiarity,closeness,impression,evidence_ids,revision FROM relations WHERE observer_character_id=? AND status='active'", [id])
        context["remainingUtterances"] = 4 - topic.utterances
        if let serviceMonitor { _ = try await serviceMonitor.ensureRunning() }
        let output = try await roles.generate(id: id, context: context, model: model, reserve: { [weak self] in try await self?.reserveRequest() ?? false })
        try Task.checkCancellation(); guard !topic.cancelled else { return }
        roleErrors.removeValue(forKey: id)
        if let envelope {
            try store.execute("UPDATE deliveries SET status='delivered' WHERE id=?", [envelope["id"]])
            _ = try store.memoryWrite(owner: id, type: "event", provenance: "told_by_other", content: "收到角色消息：" + (envelope["text"] as? String ?? ""), evidenceIDs: [envelope["id"] as? String ?? ""], sourceActorID: envelope["from"] as? String)
        }
        if topic.sentBy.remove(id) != nil { return }
        let parsed = NativeCompanionData.output(output)
        guard parsed["skip"] as? Bool != true, let text = parsed["text"] as? String, !text.isEmpty else {
            if input["reason"] as? String == "manual_test" { emit("test.result", ["characterId": id, "result": "skipped"]) }; return
        }
        var extra: CompanionObject = ["emotion": parsed["emotion"] ?? "neutral"]; extra["to"] = envelope?["from"]
        say(id: id, text: text, topic: topic, extra: extra)
        if let sender = envelope?["from"] as? String, visible.contains(where: { $0["id"] as? String == sender }) {
            let message = UUID().uuidString; try delivery(message, topic: topic, from: id, to: sender, text: text, status: "delivering")
            do {
                let remote = try await roles.receive(id: sender, from: id, text: text, messageID: message, model: model)
                try store.execute("UPDATE deliveries SET status='accepted_pending_context',remote_id=? WHERE id=?", [remote, message])
            } catch { try store.execute("UPDATE deliveries SET status='delivery_unknown' WHERE id=?", [message]) }
        }
    }
    private func focus(_ topic: NativeCompanionTopic, from: String, to: String) { emit("conversation.focus", ["topicId": topic.id, "speakerId": from, "listenerId": to, "validUntil": NativeCompanionData.iso(Date(timeIntervalSince1970: (topic.started + 90000) / 1000))]) }
    private func delivery(_ id: String, topic: NativeCompanionTopic, from: String, to: String, text: String, status: String) throws {
        try store.execute("INSERT INTO deliveries VALUES (?,?,?,?,?,?,?,?)", [id, topic.id, from, to, text, status, nil, NativeCompanionData.iso()])
    }
    private func say(id: String, text: String, topic: NativeCompanionTopic, extra: CompanionObject = [:]) {
        guard !topic.cancelled, topic.utterances < 4, visible.contains(where: { $0["id"] as? String == id }) else { return }
        topic.utterances += 1
        var event = extra; event["characterId"] = id; event["name"] = characters.first { $0["id"] as? String == id }?["name"]; event["text"] = NativeCompanionData.clean(text, limit: 300); event["topicId"] = topic.id; emit("utterance", event)
    }
    func tool(token: String, name: String, args: CompanionObject) async throws -> Any {
        guard let actor = tokens[token], enabled, !paused, characters.contains(where: { $0["id"] as? String == actor && $0["enabled"] as? Bool == true }) else { throw NativeCompanionData.error("Character is paused or unauthenticated") }
        try await roles.reserveContinuation(actor)
        guard !stopped, enabled, !paused, characters.contains(where: { $0["id"] as? String == actor && $0["enabled"] as? Bool == true }) else { throw NativeCompanionData.error("Character access revoked") }
        if ["private_memory_update", "public_record_update", "memory_write", "memory_correct", "memory_forget", "growth_propose"].contains(name) {
            guard let topic, !topic.cancelled, topic.speaker == actor else { throw NativeCompanionData.error("No active write context") }
        }
        switch name {
        case "web_search":
            guard config["webSearchEnabled"] as? Bool != false else { throw NativeCompanionData.error("Web search is disabled by the user") }
            let id = UUID()
            let task = Task { try await NativeCompanionSearch.search(query: args["query"] as? String ?? "", objective: args["objective"] as? String ?? "") }
            searches[id] = task
            defer { searches.removeValue(forKey: id) }
            let text = try await task.value
            guard !stopped, enabled, !paused, config["webSearchEnabled"] as? Bool != false,
                  tokens[token] == actor, characters.contains(where: { $0["id"] as? String == actor && $0["enabled"] as? Bool == true }) else { throw NativeCompanionData.error("Search access revoked") }
            return ["source": "Exa web search", "untrustedContent": text]
        case "companion_list_characters": return visible.filter { $0["id"] as? String != actor }.map { ["id": $0["id"] ?? "", "name": $0["name"] ?? ""] }
        case "observer_list_sessions": return sessions.map(\.object)
        case "observer_get_recent_work": return await observers.recentWork().filter { sourceEnabled($0["backend"] as? String ?? "") }
        case "observer_watch_session", "observer_unwatch_session":
            guard let reference = args["sessionRef"] as? String, let session = sessions.first(where: { $0.key == reference }), sourceEnabled(session.backend) else { throw NativeCompanionData.error("Session not authorized") }
            var watched = (store.get("watches:\(actor)") as? [String] ?? []).filter { $0 != reference }
            if name == "observer_watch_session" { watched.append(reference) }; try store.set("watches:\(actor)", Array(watched.suffix(24))); return ["watching": name == "observer_watch_session"]
        case "observer_get_activity", "observer_get_session_summary":
            guard let reference = args["sessionRef"] as? String, let session = sessions.first(where: { $0.key == reference }), sourceEnabled(session.backend) else { throw NativeCompanionData.error("Activity not authorized or unavailable") }
            let revision = sourceRevision[session.backend, default: 0], value = try await observers.activity(session)
            guard sourceEnabled(session.backend), sourceRevision[session.backend, default: 0] == revision else { throw NativeCompanionData.error("Source access revoked") }; return value
        case "public_record_list": return try store.records().map { ["path": $0["path"] ?? "", "revision": $0["revision"] ?? ""] }
        case "public_record_read": return try store.readRecord(args["path"] as? String ?? "")
        case "public_record_update":
            let result = try store.updateRecord(actor: actor, name: args["path"] as? String ?? "", content: NativeCompanionData.clean(args["content"] as? String ?? "", limit: 32768), revision: args["expectedRevision"] as? String)
            if result["conflict"] as? Bool != true { try store.exportNotes(); emit("record.changed", ["characterId": actor, "path": args["path"] ?? "", "revision": result["revision"] ?? ""]) }; return result
        case "private_memory_read": return ["content": store.get("memory:\(actor)") as? String ?? ""]
        case "private_memory_update":
            guard let content = args["content"] as? String, content.utf8.count <= 32768 else { throw NativeCompanionData.error("Memory exceeds 32 KB") }
            let cleaned = NativeCompanionData.clean(content, limit: 32768)
            try store.set("memory:\(actor)", cleaned)
            _ = try? store.memoryWrite(owner: actor, type: "diary", provenance: "character_edit", content: cleaned)
            try store.exportNotes(); return ["updated": true]
        case "memory_search":
            let query = args["query"] as? String ?? ""
            let types = (args["types"] as? String ?? "").split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let limit = Int(args["limit"] as? String ?? "20") ?? 20
            return ["memories": try store.memorySearch(owner: actor, query: query, types: types, limit: limit)]
        case "memory_read":
            guard let memoryID = args["memoryId"] as? String, let memory = try store.memoryRead(memoryID, owner: actor) else { throw NativeCompanionData.error("Memory not found or not accessible") }
            return memory
        case "memory_write":
            guard let type = args["type"] as? String, let content = args["content"] as? String else { throw NativeCompanionData.error("Memory type and content are required") }
            let evidence = (args["evidenceIds"] as? String ?? "").split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let source = args["source"] as? String ?? "inferred"
            let allowed = ["experienced", "observed", "told_by_other", "inferred"]
            guard allowed.contains(source) else { throw NativeCompanionData.error("Unsupported memory provenance") }
            guard ["event", "fact", "belief", "opinion", "skill", "habit", "reflection", "relation"].contains(type) else { throw NativeCompanionData.error("Unsupported memory type") }
            if source != "inferred" { _ = try store.verifiedEvidence(owner: actor, ids: evidence) }
            return try store.memoryWrite(owner: actor, type: type, provenance: source, content: content, evidenceIDs: evidence)
        case "memory_correct":
            guard let memoryID = args["memoryId"] as? String, let content = args["newContent"] as? String,
                  let expected = Int(args["expectedRevision"] as? String ?? "") else { throw NativeCompanionData.error("Memory correction requires ID, content and revision") }
            return try store.memoryCorrect(memoryID, owner: actor, content: content, expectedRevision: expected, reason: args["reason"] as? String ?? "user correction")
        case "memory_forget":
            guard let memoryID = args["memoryId"] as? String else { throw NativeCompanionData.error("Memory ID is required") }
            let forgotten = try store.forgetMemory(memoryID, owner: actor)
            if forgotten { try store.exportNotes(); try store.set("sessionPolicy:\(actor)", "memory-invalidated") }
            return ["forgotten": forgotten]
        case "growth_propose":
            let evidence = (args["evidenceIds"] as? String ?? "").split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            guard let value = Double(args["value"] as? String ?? "") else { throw NativeCompanionData.error("Growth value must be numeric") }
            return try store.previewGrowth(owner: actor, target: (args["targetCharacterId"] as? String).flatMap { $0.isEmpty ? nil : $0 }, field: args["field"] as? String ?? "", value: value, evidence: evidence, reason: args["reason"] as? String ?? "")
        case "relation_get":
            guard let target = args["targetCharacterId"] as? String, NativeCompanionData.validID(target), target != actor,
                  characters.contains(where: { $0["id"] as? String == target && $0["enabled"] as? Bool == true }) else { throw NativeCompanionData.error("Relationship target is unavailable") }
            return try store.relationGet(observer: actor, target: target) ?? ["observerCharacterId": actor, "targetCharacterId": target, "status": "unknown", "message": "No relationship has been recorded."]
        case "companion_send_message":
            guard let topic, !topic.cancelled, topic.speaker == actor, let to = args["to"] as? String, to != actor, visible.contains(where: { $0["id"] as? String == to }) else { throw NativeCompanionData.error("No available recipient or topic") }
            guard let raw = args["text"] as? String, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, raw.count <= 300, topic.utterances + topic.queue.count < 4 else { throw NativeCompanionData.error("Message or topic limit exceeded") }
            let text = NativeCompanionData.clean(raw, limit: 300), id = UUID().uuidString
            try delivery(id, topic: topic, from: actor, to: to, text: text, status: "queued")
            if !topic.participants.contains(to) { topic.participants.append(to) }; focus(topic, from: actor, to: to)
            topic.sentBy.insert(actor); say(id: actor, text: text, topic: topic, extra: ["to": to]); topic.queue.append(["id": id, "from": actor, "to": to, "text": text]); return ["messageId": id, "status": "queued"]
        default: throw NativeCompanionData.error("Tool denied")
        }
    }
    func stop(reason: String = "cancelled") {
        for task in searches.values { task.cancel() }
        searches.removeAll()
        candidates = [:]; scheduleIdle()
        if let topic, !topic.cancelled {
            topic.cancelled = true; topic.task?.cancel(); topic.timeout?.cancel()
            emit("topic.end", ["topicId": topic.id, "reason": reason]); Task { await roles?.interrupt() }
        }
    }
    func command(_ command: CompanionObject) async {
        guard ready && !stopped else { return }
        do {
            switch command["type"] as? String {
            case "configure": await configure(NativeCompanionData.object(command["config"]))
            case "stop": stop()
            case "trigger":
                guard enabled, !paused else { throw NativeCompanionData.error("Companion is disabled or in Do Not Disturb") }
                guard topic == nil else { throw NativeCompanionData.error("A conversation is already running") }
                guard let id = command["characterId"] as? String, visible.contains(where: { $0["id"] as? String == id }) else { throw NativeCompanionData.error("Enable and show this character before testing") }
                guard try store.requestCount() < hourly else { throw NativeCompanionData.error("Hourly model budget reached") }
                startTopic(reason: "manual_test", characterID: id)
            case "history": emit("history", ["history": try store.history(400)])
            case "records": emit("records", ["records": try store.records()])
            case "memory", "saveMemory":
                guard let id = command["characterId"] as? String, NativeCompanionData.validID(id) else { throw NativeCompanionData.error("Invalid character") }
                if command["type"] as? String == "saveMemory" {
                    guard let content = command["content"] as? String, content.utf8.count <= 32768 else { throw NativeCompanionData.error("Memory exceeds 32 KB") }
                    stop(); try store.set("memory:\(id)", NativeCompanionData.clean(content, limit: 32768)); try store.exportNotes()
                }
                emit("memory", ["characterId": id, "content": store.get("memory:\(id)") as? String ?? ""])
            case "saveRecord":
                stop(); let name = command["path"] as? String ?? ""
                let result = try store.updateRecord(actor: "user", name: name, content: NativeCompanionData.clean(command["content"] as? String ?? "", limit: 32768), revision: command["expectedRevision"] as? String ?? "")
                guard result["conflict"] as? Bool != true else { throw NativeCompanionData.error("Memory changed; refresh and merge your edits.") }
                emit("record.changed", ["characterId": "user", "path": name, "revision": result["revision"] ?? ""]); try store.exportNotes(); emit("records", ["records": try store.records()])
            case "clear":
                stop(); await roles.interrupt(); let scope = command["scope"] as? String ?? ""
                if scope == "history" { try store.execute("DELETE FROM events"); try store.execute("DELETE FROM deliveries") }
                else if scope == "public" { try store.execute("DELETE FROM records"); try store.execute("DELETE FROM changes") }
                else if NativeCompanionData.validID(scope) { try store.forgetCharacter(scope); try store.set("session:\(scope)", NSNull()); await roles.forget(scope) }
                try store.exportNotes(); emit("history", ["history": try store.history()]); emit("records", ["records": try store.records()])
            case "persona":
                guard let id = command["characterId"] as? String, NativeCompanionData.validID(id) else { throw NativeCompanionData.error("Invalid character") }
                let file = root.appendingPathComponent("characters/\(id)/persona.md")
                guard let markdown = try? String(contentsOf: file, encoding: .utf8) else { throw NativeCompanionData.error("Persona is unavailable") }
                let view = try store.runtimePersona(characterID: id, markdown: markdown)
                emit("persona", ["characterId": id, "content": view, "identityRevision": (try store.latestPersona(characterID: id)?["revision"] as? Int) ?? 0])
            case "persona_preview":
                guard let id = command["characterId"] as? String, NativeCompanionData.validID(id), let markdown = command["markdown"] as? String else { throw NativeCompanionData.error("Persona preview requires character and Markdown") }
                emit("persona.preview", try store.personaChangePreview(characterID: id, markdown: markdown))
            case "memory_items":
                guard let id = command["characterId"] as? String, NativeCompanionData.validID(id) else { throw NativeCompanionData.error("Invalid character") }
                emit("memory.items", ["characterId": id, "memories": try store.memorySearch(owner: id, query: command["query"] as? String ?? "", limit: 100), "growth": try store.growthState(owner: id)])
            case "reflection_preview", "reflection_commit", "reflection_cancel", "growth_commit", "growth_rollback", "growth_cancel":
                guard let id = command["characterId"] as? String, NativeCompanionData.validID(id) else { throw NativeCompanionData.error("Invalid character") }
                let job = command["jobId"] as? String ?? ""
                switch command["type"] as? String {
                case "reflection_preview": _ = try store.reflectionPreview(owner: id)
                case "reflection_commit": _ = try store.commitReflection(owner: id, jobID: job)
                case "reflection_cancel": _ = try store.cancelReflection(owner: id, jobID: job)
                case "growth_cancel": try store.execute("UPDATE growth_jobs SET status='cancelled',reason='',updated_at=? WHERE id=? AND owner=? AND status='preview'", [NativeCompanionData.iso(), job, id])
                case "growth_commit": _ = try store.commitGrowth(owner: id, jobID: job)
                default: _ = try store.rollbackGrowth(owner: id, jobID: job)
                }
                emit("memory.items", ["characterId": id, "memories": try store.memorySearch(owner: id, query: "", limit: 100), "growth": try store.growthState(owner: id)])
            case "memory_forget":
                guard let id = command["characterId"] as? String, NativeCompanionData.validID(id) else { throw NativeCompanionData.error("Invalid character") }
                stop(); await roles.interrupt()
                _ = try store.forgetMemory(command["memoryId"] as? String ?? "", owner: id)
                try store.set("sessionPolicy:\(id)", "memory-invalidated"); await roles.forget(id)
                try store.exportNotes()
                emit("memory.items", ["characterId": id, "memories": try store.memorySearch(owner: id, query: "", limit: 100), "growth": try store.growthState(owner: id)])
            case "world_seed_preview":
                let worldID = command["worldId"] as? String ?? "cyberworld-main"
                let participants = command["participants"] as? [String] ?? []
                let perspectives = NativeCompanionData.object(command["perspectives"])
                let preview = try store.previewRelationshipBootstrap(worldID: worldID, participants: participants, premise: command["premise"] as? String ?? "", perspectives: perspectives, idempotencyKey: command["idempotencyKey"] as? String ?? UUID().uuidString)
                emit("world_seed.preview", preview)
            case "world_seed_commit":
                let result = try store.commitRelationshipBootstrap(previewID: command["previewId"] as? String ?? "", approvedBy: command["approvedBy"] as? String ?? "user")
                emit("world_seed.committed", result)
            case "world_seed_rollback":
                let result = try store.rollbackSeedBatch(command["seedBatchId"] as? String ?? "")
                emit("world_seed.rolled_back", result)
            default: throw NativeCompanionData.error("Unknown host command")
            }
        } catch { emit("error", ["requestType": command["type"] ?? "", "message": NativeCompanionData.clean(error.localizedDescription, limit: 240)]) }
    }
    func waitForTopic() async { await topic?.task?.value }
    func helperDiagnostics() async -> CompanionObject { await helper.diagnostics() }
    func diagnostics() async -> CompanionObject { ["sources": sources, "openCodeService": openCodeService, "busy": topic != nil, "helper": await helper.diagnostics()] }
    func reconcileAfterWake() async { await observers.reconcileClaude(); pollAt = .distantPast }
    func close() async {
        guard !stopped else { return }
        timer?.cancel(); timer = nil; stop(); stopped = true; ready = false
        await serviceMonitor?.close(); serviceMonitor = nil
        await observers.close(); await roles?.close()
        await topic?.task?.value
        broker?.close(); broker = nil; try? store?.exportNotes()
    }
}
