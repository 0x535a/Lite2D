import Foundation

protocol NativeCompanionRoleClient: AnyObject {
    func generate(id: String, context: CompanionObject, model: String, reserve: @escaping () async throws -> Bool) async throws -> String
    func receive(id: String, from: String, text: String, messageID: String, model: String) async throws -> String
    func reserveContinuation(_ id: String) async throws
    func forget(_ id: String) async
    func interrupt() async
    func reapStale() async
    func close() async
    func consolidate(id: String, job: CompanionObject, model: String, hourlyLimit: Int) async throws -> CompanionObject
    func rotate(id: String, jobID: String, model: String) async throws -> String
}

actor NativeCompanionRoles: NativeCompanionRoleClient {
    struct Instance { let session: String; let digest: String; let model: String; let directory: URL }
    struct Budget { let reserve: () async throws -> Bool; var steps = Set<String>(); var retries = 0 }
    let root: URL
    let store: NativeCompanionStore
    let prompt: NativeCompanionPrompt
    let promptFile: URL
    let executable: String
    let helper: String
    let toolEndpoint: URL
    let register: (String) async -> String
    private let providersOverride: CompanionObject?
    private var client: NativeCompanionHTTP?
    private var child: NativeCompanionProcess?
    private var starting: Task<NativeCompanionHTTP, Error>?
    private var instances: [String: Instance] = [:]
    private var budgets: [String: Budget] = [:]
    private var stopped = false
    static var rules: [CompanionObject] {
        [["action": "*", "resource": "*", "effect": "deny"]] + NativeCompanionMCP.toolNames.flatMap { name in
            [name, "companion.\(name)", "companion_\(name)"].map { ["action": $0, "resource": "*", "effect": "allow"] }
        }
    }
    init(root: URL, store: NativeCompanionStore, prompt: NativeCompanionPrompt, promptFile: URL, executable: String, helper: String, toolEndpoint: URL, providers: CompanionObject? = nil, register: @escaping (String) async -> String) {
        self.root = root; self.store = store; self.prompt = prompt; self.promptFile = promptFile; self.executable = executable; self.helper = helper; self.toolEndpoint = toolEndpoint; self.providersOverride = providers; self.register = register
    }
    private func server() async throws -> NativeCompanionHTTP {
        guard !stopped else { throw NativeCompanionData.error("Role service stopped") }
        if let client, child?.process.isRunning == true { return client }
        if let starting { return try await starting.value }
        let task = Task<NativeCompanionHTTP, Error> {
            await reapStaleRoleService()
            let configDir = root.appendingPathComponent("runtime-config")
            try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var providers = providersOverride ?? [:]
            if providersOverride == nil, let user = try? NativeCompanionHTTP.discover() {
                if let configs = try await user.request("GET", "api/config") as? [CompanionObject] {
                    for entry in configs { providers.merge(NativeCompanionData.object(NativeCompanionData.object(entry["info"])["providers"]), uniquingKeysWith: { _, value in value }) }
                }
            }
            guard !stopped else { throw NativeCompanionData.error("Role service stopped") }
            let password = UUID().uuidString + UUID().uuidString
            let process = NativeCompanionProcess(), address = NativeAsyncValue<URL>()
            process.onLine = { line in
                if let range = line.range(of: #"http://127\.0\.0\.1:\d+"#, options: .regularExpression), let url = URL(string: String(line[range])) { address.resolve(.success(url)) }
            }
            process.onExit = { address.resolve(.failure(NativeCompanionData.error("Role service exited"))) }
            var env = ProcessInfo.processInfo.environment
            env["OPENCODE_CONFIG_DIR"] = configDir.path; env["OPENCODE_DISABLE_AUTOUPDATE"] = "1"
            env["OPENCODE_DISABLE_CLAUDE_CODE"] = "1"; env["OPENCODE_DISABLE_CLAUDE_CODE_SKILLS"] = "1"
            env["OPENCODE_SERVER_PASSWORD"] = password; env["OPENCODE_CONFIG_CONTENT"] = NativeCompanionData.string(["providers": providers])
            try process.start(executable, arguments: ["serve", "--hostname", "127.0.0.1", "--port", "0"], environment: env, directory: root)
            try store.set("roleServicePid", process.process.processIdentifier)
            child = process
            do {
                let url = try await address.wait(seconds: 20)
                guard !stopped else { process.close(); throw NativeCompanionData.error("Role service stopped") }
                let client = NativeCompanionHTTP(baseURL: url, authorization: "Basic " + Data("opencode:\(password)".utf8).base64EncodedString())
                self.client = client; return client
            } catch { process.close(); throw error }
        }
        starting = task
        do { let result = try await task.value; starting = nil; return result } catch { starting = nil; throw error }
    }
    private func reapStaleRoleService() async {
        guard let old = store.get("roleServicePid") as? Int, old > 1, old != Int(getpid()) else { return }
        // Match only this internal ephemeral-port role service, never the user's
        // registered `opencode serve --service` process.
        let check = Process(); check.executableURL = URL(fileURLWithPath: "/bin/ps"); check.arguments = ["-p", String(old), "-o", "command="]
        let pipe = Pipe(); check.standardOutput = pipe; check.standardError = FileHandle.nullDevice
        guard (try? check.run()) != nil else { return }; check.waitUntilExit()
        let command = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if check.terminationStatus == 0, command == "\(executable) serve --hostname 127.0.0.1 --port 0" {
            kill(pid_t(old), SIGTERM)
            for _ in 0..<20 { if kill(pid_t(old), 0) != 0 { break }; try? await Task.sleep(nanoseconds: 100_000_000) }
        }
        try? store.set("roleServicePid", NSNull())
    }
    func reapStale() async { await reapStaleRoleService() }
    func prepare(id: String, model: String) async throws -> Instance {
        guard NativeCompanionData.validID(id) else { throw NativeCompanionData.error("Invalid character") }
        let client = try await server(), directory = root.appendingPathComponent("characters/\(id)")
        guard try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
              try root.appendingPathComponent("characters").resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw NativeCompanionData.error("Invalid Persona directory") }
        let file = directory.appendingPathComponent("persona.md")
        let attributes = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true, (attributes.fileSize ?? Int.max) <= 65536,
              file.resolvingSymlinksInPath().deletingLastPathComponent() == directory.resolvingSymlinksInPath() else { throw NativeCompanionData.error("Persona must be regular Markdown under 64 KB") }
        let persona = try String(contentsOf: file, encoding: .utf8)
        guard !persona.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw NativeCompanionData.error("Persona is empty") }
        let runtimePersona = (try? store.runtimePersona(characterID: id, markdown: persona)) ?? persona
        let digest = NativeCompanionData.hash(prompt.system(persona: runtimePersona))
        if let existing = instances[id], existing.digest == digest, existing.model == model,
           store.get("sessionPolicy:\(id)") as? String == "initiative-v1",
           store.get("sessionPersona:\(id)") as? String == NativeCompanionData.hash(persona) { return existing }
        let hadInstance = instances[id] != nil
        let token = await register(id)
        let config: CompanionObject = ["default_agent": "companion", "permissions": Self.rules,
            "agents": ["companion": ["mode": "primary", "system": prompt.system(persona: runtimePersona), "permissions": Self.rules, "steps": 6]],
            "mcp": ["companion": ["type": "local", "command": [helper, "--companion-mcp"], "codemode": false,
                "environment": ["LITE2D_TOOL_ENDPOINT": toolEndpoint.absoluteString, "LITE2D_TOOL_TOKEN": token, "LITE2D_PROMPT_PATH": promptFile.path]]],
            "plugins": [], "snapshots": false]
        let configFile = directory.appendingPathComponent("opencode.json")
        try NativeCompanionData.json(config).write(to: configFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configFile.path)
        if hadInstance { _ = try await client.post("api/location/reload") }
        var session = store.get("session:\(id)") as? String
        if let old = session {
            if let response = try? await client.get("api/session/\(old)"), NativeCompanionData.object(NativeCompanionData.object(response["data"])["location"])["directory"] as? String == directory.path,
               store.get("sessionPolicy:\(id)") as? String == "initiative-v1",
               store.get("sessionPersona:\(id)") as? String == NativeCompanionData.hash(persona) { }
            else { session = nil }
        }
        var modelRef: CompanionObject?
        if let slash = model.firstIndex(of: "/") { modelRef = ["providerID": String(model[..<slash]), "id": String(model[model.index(after: slash)...])] }
        if session == nil {
            var input: CompanionObject = ["title": "Lite2D \(id)", "agent": "companion", "location": ["directory": directory.path], "permissions": Self.rules, "metadata": ["lite2dCompanion": true, "characterId": id]]
            input["model"] = modelRef
            let response = try await client.post("api/session", input)
            guard let created = NativeCompanionData.object(response["data"])["id"] as? String else { throw NativeCompanionData.error("OpenCode did not create a role session") }
            session = created; try store.set("session:\(id)", created)
            try store.set("sessionPolicy:\(id)", "initiative-v1")
            try store.set("sessionPersona:\(id)", NativeCompanionData.hash(persona))
        } else if let modelRef { _ = try await client.post("api/session/\(session!)/model", ["model": modelRef]) }
        let agents = try await client.get("api/agent", ["location[directory]": directory.path])
        let agent = NativeCompanionData.array(agents["data"]).first { $0["id"] as? String == "companion" }
        guard NativeCompanionData.array(agent?["permissions"]).contains(where: { $0["action"] as? String == "*" && $0["resource"] as? String == "*" && $0["effect"] as? String == "deny" }) else { throw NativeCompanionData.error("Role permission policy did not load") }
        let deadline = Date().addingTimeInterval(12)
        while true {
            let mcp = try await client.get("api/mcp", ["location[directory]": directory.path])
            let server = NativeCompanionData.array(mcp["data"]).first { $0["name"] as? String == "companion" }
            let state = NativeCompanionData.object(server?["status"])["status"] as? String
            if state == "connected" { break }
            if Date() >= deadline || ["failed", "disabled", "needs_auth"].contains(state ?? "") { throw NativeCompanionData.error("Companion tools failed to initialize") }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        let instance = Instance(session: session!, digest: digest, model: model, directory: directory); instances[id] = instance; return instance
    }
    func reserveContinuation(_ id: String) async throws {
        guard var budget = budgets[id], let instance = instances[id], let client else { return }
        let messages = NativeCompanionData.array(try await client.get("api/session/\(instance.session)/message", ["limit": "3", "order": "desc"])["data"])
        if let message = messages.first(where: { $0["type"] as? String == "assistant" }), let key = message["id"] as? String, !budget.steps.contains(key) {
            budget.steps.insert(key); budgets[id] = budget
            guard try await budget.reserve() else { _ = try? await client.post("api/session/\(instance.session)/interrupt", [:]); throw NativeCompanionData.error("Hourly model budget reached") }
        }
    }
    func generate(id: String, context input: CompanionObject, model: String, reserve: @escaping () async throws -> Bool) async throws -> String {
        let instance = try await prepare(id: id, model: model); guard let client else { throw NativeCompanionData.error("Role service stopped") }
        try Task.checkCancellation()
        var context = input
        if store.get("dailyWakeSession:\(id)") as? String != instance.session {
            var recollection = try store.dailyWake(id)
            if let since = store.get("dailyBridgeFrom:\(id)") as? Double {
                recollection["interveningDialogue"] = try store.dailyDialogue(owner: id, from: Date(timeIntervalSince1970: since), to: Date())
            }
            context["recollection"] = recollection
        }
        let exampleFile = instance.directory.appendingPathComponent("style_examples.jsonl")
        if let attributes = try? exampleFile.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey]), attributes.isSymbolicLink != true, (attributes.fileSize ?? Int.max) < 262144,
           let text = try? String(contentsOf: exampleFile, encoding: .utf8) {
            let reason = input["reason"] as? String
            let scenes = reason == "character_message" ? ["sister_conversation", "sister_support"] : ["spontaneous_chat", "anime", "gaming"]
            let examples = text.components(separatedBy: "\n").compactMap { $0.data(using: .utf8).flatMap { try? NativeCompanionData.decode($0) as? CompanionObject } }
                .filter { scenes.contains($0["scene"] as? String ?? "") && $0["source_type"] as? String == "original_style_example" && $0["is_official_quote"] as? Bool == false }
            let selected = Array(examples.prefix(3))
            context["styleExamples"] = selected.map { ["scene": $0["scene"] ?? "", "response": NativeCompanionData.clean($0["response"] as? String ?? "", limit: 250), "provenance": prompt.styleExample] }
        }
        let before = NativeCompanionData.array(try await client.get("api/session/\(instance.session)/message", ["limit": "4", "order": "desc"])["data"])
        let previous = Set(before.compactMap { $0["id"] as? String })
        let pending = try store.rows("SELECT id,sender,text,remote_id FROM deliveries WHERE recipient=? AND status='accepted_pending_context'", [id])
        if !pending.isEmpty {
            let inbox = NativeCompanionData.array(try await client.get("api/session/\(instance.session)/inbox")["data"])
            for row in pending {
                if let remote = row["remote_id"] as? String, inbox.contains(where: { $0["id"] as? String == remote }) { _ = try await client.request("DELETE", "api/session/\(instance.session)/inbox/\(remote)") }
            }
            context["pendingCompanionMessages"] = pending.map { ["messageId": $0["id"] ?? "", "from": $0["sender"] ?? "", "text": $0["text"] ?? "", "quotedEvidence": true] }
        }
        budgets[id] = Budget(reserve: reserve)
        let admitted = try await client.post("api/session/\(instance.session)/synthetic", ["text": NativeCompanionData.string(context), "delivery": "queue", "resume": true,
            "metadata": ["lite2d": true, "topicId": input["topicId"] ?? "", "synchronizedDeliveries": pending.compactMap { $0["id"] as? String }]])
        let inputID = NativeCompanionData.object(admitted["data"])["id"] as? String ?? ""
        try store.set("dailyWakeSession:\(id)", instance.session)
        for row in pending { try store.execute("UPDATE deliveries SET remote_id=? WHERE id=?", [inputID, row["id"]]) }
        let deadline = Date().addingTimeInterval(60)
        do {
            while Date() < deadline {
                try Task.checkCancellation()
                let messages = NativeCompanionData.array(try await client.get("api/session/\(instance.session)/message", ["limit": "12", "order": "desc"])["data"])
                let response = messages.first { $0["type"] as? String == "assistant" && !previous.contains($0["id"] as? String ?? "") }
                let retry = NativeCompanionData.object(response?["retry"])
                if var budget = budgets[id] {
                    while budget.retries < retry["attempt"] as? Int ?? 0 {
                        budget.retries += 1; budgets[id] = budget
                        guard try await reserve() else { throw NativeCompanionData.error("Hourly model budget reached") }
                    }
                }
                if (retry["attempt"] as? Int ?? 0) >= 2 { throw NativeCompanionData.error(NativeCompanionData.clean(NativeCompanionData.object(retry["error"])["message"] as? String ?? "Model provider unavailable", limit: 240)) }
                let active = NativeCompanionData.object(try await client.get("api/session/active")["data"])
                if active[instance.session] == nil, let response, NativeCompanionData.object(response["time"])["completed"] != nil {
                    let text = NativeCompanionData.text(response)
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        let delivered = Set(messages.compactMap { $0["id"] as? String })
                        for row in try store.rows("SELECT id,remote_id,sender,text FROM deliveries WHERE recipient=? AND status='accepted_pending_context'", [id]) where delivered.contains(row["remote_id"] as? String ?? "") {
                            try store.execute("UPDATE deliveries SET status='context_consumed' WHERE id=?", [row["id"]])
                            try store.execute("INSERT OR IGNORE INTO daily_receipts VALUES (?,?)", [row["id"], NativeCompanionData.iso()])
                            _ = try store.recordDirectMemory(owner: id, source: "told_by_other", eventID: row["id"] as? String ?? "", content: "收到角色消息：" + (row["text"] as? String ?? ""), sourceActorID: row["sender"] as? String)
                        }
                        budgets.removeValue(forKey: id); return text
                    }
                    if let error = response["error"] as? CompanionObject { throw NativeCompanionData.error(NativeCompanionData.clean(error["message"] as? String ?? "Companion generation failed", limit: 240)) }
                }
                try await Task.sleep(nanoseconds: 400_000_000)
            }
            throw NativeCompanionData.error("Companion response timeout")
        } catch {
            budgets.removeValue(forKey: id)
            _ = try? await client.request("POST", "api/session/\(instance.session)/interrupt", body: ["resume": false], timeout: 2.5)
            throw error
        }
    }
    func receive(id: String, from: String, text: String, messageID: String, model: String) async throws -> String {
        let instance = try await prepare(id: id, model: model)
        let response = try await client!.post("api/session/\(instance.session)/synthetic", ["text": NativeCompanionData.string(["from": from, "message": text, "instruction": prompt.peerReceipt]), "resume": false, "delivery": "steer", "metadata": ["lite2d": true, "messageId": messageID]])
        guard let id = NativeCompanionData.object(response["data"])["id"] as? String else { throw NativeCompanionData.error("No message receipt") }; return id
    }
    func forget(_ id: String) { instances.removeValue(forKey: id) }
    func rotate(id: String, jobID: String, model: String) async throws -> String {
        let instance = try await prepare(id: id, model: model)
        let client = self.client!
        if let saved = store.get("dailyRotation:\(jobID)") as? String { return saved }
        var input: CompanionObject = ["title": "Lite2D \(id)", "agent": "companion", "location": ["directory": instance.directory.path], "permissions": Self.rules,
            "metadata": ["lite2dCompanion": true, "characterId": id, "dailyArchive": jobID]]
        if let slash = model.firstIndex(of: "/") { input["model"] = ["providerID": String(model[..<slash]), "id": String(model[model.index(after: slash)...])] }
        let created = NativeCompanionData.object(try await client.post("api/session", input)["data"])
        guard let session = created["id"] as? String else { throw NativeCompanionData.error("Cannot create daily role session") }
        try Task.checkCancellation()
        try store.transaction {
            guard try store.dailyCanRotate(jobID, owner: id) else { throw NativeCompanionData.error("Daily archive changed before session rotation") }
            try store.set("session:\(id)", session)
            try store.set("dailyRotation:\(jobID)", session)
            if let end = try store.rows("SELECT end_at FROM daily_archives WHERE id=?", [jobID]).first?["end_at"] as? Double { try store.set("dailyBridgeFrom:\(id)", end) }
            try store.set("contextSince:\(id)", NativeCompanionData.iso())
        }
        instances[id] = Instance(session: session, digest: instance.digest, model: instance.model, directory: instance.directory)
        return session
    }
    private func archiveUsage(session: String, jobID: String) async {
        guard let client,
              let response = try? await client.request("GET", "api/session/\(session)/message", query: ["limit": "100", "order": "desc"], timeout: 3) else { return }
        let messages = NativeCompanionData.array(NativeCompanionData.object(response)["data"]).filter { $0["type"] as? String == "assistant" }
        let usage = messages.map { ["model": $0["model"] ?? [:], "tokens": $0["tokens"] ?? [:], "cost": $0["cost"] ?? 0, "retry": $0["retry"] ?? [:]] }
        let old = (try? store.rows("SELECT usage FROM daily_archives WHERE id=?", [jobID]).first?["usage"] as? String) ?? "[]"
        var attempts = NativeCompanionData.array(try? NativeCompanionData.decode(Data(old.utf8)))
        attempts.removeAll { $0["session"] as? String == session }
        attempts.append(["session": session, "calls": usage])
        try? store.execute("UPDATE daily_archives SET usage=? WHERE id=?", [NativeCompanionData.string(attempts), jobID])
    }
    func consolidate(id: String, job: CompanionObject, model: String, hourlyLimit: Int) async throws -> CompanionObject {
        let client = try await server(), jobID = job["id"] as! String
        // Independent location: no Companion MCP, inherited plugins or permitted tools.
        let directory = root.appendingPathComponent("daily/\(id)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let deny: [CompanionObject] = [["action": "*", "resource": "*", "effect": "deny"]]
        let cfg: CompanionObject = ["default_agent": "archivist", "agents": ["archivist": ["mode": "primary", "system": NativeCompanionDaily.instruction, "permissions": deny, "steps": 1]], "permissions": deny, "mcp": [:], "plugins": [], "snapshots": false]
        try NativeCompanionData.json(cfg).write(to: directory.appendingPathComponent("opencode.json"), options: .atomic)
        // A new attempt gets a fresh task session. An interrupted task's partial answer is never reused.
        var input: CompanionObject = ["title": "Lite2D memory archive \(id)", "agent": "archivist", "location": ["directory": directory.path], "permissions": deny,
            "metadata": ["lite2dCompanion": true, "characterId": id, "dailyArchive": jobID]]
        if let slash = model.firstIndex(of: "/") { input["model"] = ["providerID": String(model[..<slash]), "id": String(model[model.index(after: slash)...])] }
        guard let session = NativeCompanionData.object(try await client.post("api/session", input)["data"])["id"] as? String else { throw NativeCompanionData.error("Cannot create memory archive task") }
        try store.set("dailyTaskSession:\(session)", session)
        do {
            _ = try await client.post("api/session/\(session)/synthetic", ["text": job["input"] ?? "{}", "delivery": "queue", "resume": true, "metadata": ["lite2d": true]])
            let deadline = Date().addingTimeInterval(180)
            var reserved = 1
            while Date() < deadline {
                try Task.checkCancellation()
                let messages = NativeCompanionData.array(try await client.get("api/session/\(session)/message", ["limit": "20", "order": "desc"])["data"])
                let responses = messages.filter { $0["type"] as? String == "assistant" }
                let attempts = max(1, responses.count) + (NativeCompanionData.object(responses.first?["retry"])["attempt"] as? Int ?? 0)
                while reserved < attempts {
                    guard try store.spend(hourlyLimit) else { throw NativeCompanionData.error("Hourly model budget reached during daily consolidation") }
                    reserved += 1
                }
                let active = NativeCompanionData.object(try await client.get("api/session/active")["data"])
                if active[session] == nil, let response = responses.first, NativeCompanionData.object(response["time"])["completed"] != nil {
                    await archiveUsage(session: session, jobID: jobID)
                    if let error = response["error"] as? CompanionObject { throw NativeCompanionData.error(NativeCompanionData.clean(error["message"] as? String ?? "Daily archive failed")) }
                    let raw = NativeCompanionData.text(response).trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
                    guard let result = try NativeCompanionData.decode(Data(raw.utf8)) as? CompanionObject else { throw NativeCompanionData.error("Invalid daily archive JSON") }
                    return result
                }
                if (NativeCompanionData.object(responses.first?["retry"])["attempt"] as? Int ?? 0) >= 2 { throw NativeCompanionData.error("Daily archive provider unavailable") }
                try await Task.sleep(nanoseconds: 300_000_000)
            }
            throw NativeCompanionData.error("Daily archive timed out")
        } catch {
            // Cleanup must still reach the local service when the caller was cancelled.
            let cleanup = Task {
                _ = try? await client.request("POST", "api/session/\(session)/interrupt", body: ["resume": false], timeout: 2.5)
                await archiveUsage(session: session, jobID: jobID)
            }
            await cleanup.value
            throw error
        }
    }
    func interrupt() async {
        guard let client else { return }
        for instance in instances.values { _ = try? await client.request("POST", "api/session/\(instance.session)/interrupt", body: ["resume": false], timeout: 2.5) }
    }
    func close() async {
        stopped = true; await interrupt()
        if let pid = store.get("roleServicePid") as? Int32, pid == child?.process.processIdentifier { try? store.set("roleServicePid", NSNull()) }
        child?.close(); child = nil; client = nil; starting?.cancel(); starting = nil; instances = [:]
    }
}
