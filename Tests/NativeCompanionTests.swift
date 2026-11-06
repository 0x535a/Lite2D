import Foundation

private let a = "11111111-1111-4111-8111-111111111111"
private let b = "22222222-2222-4222-8222-222222222222"
private final class SearchProtocol: URLProtocol {
    static var responseData = Data()
    static var statusCode = 200
    static var lastRequest: URLRequest?
    static var lastBody = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRequest = request
        Self.lastBody = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }; Self.lastBody.append(contentsOf: buffer.prefix(count))
            }
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.statusCode, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
private final class Events {
    private let lock = NSLock(); private var values: [CompanionObject] = []
    func add(_ event: CompanionObject) { lock.withLock { values.append(event) } }
    func all() -> [CompanionObject] { lock.withLock { values } }
}
private actor FakeRoles: NativeCompanionRoleClient {
    var calls: [String] = []
    var contexts: [CompanionObject] = []
    var receipts = 0
    var handler: ((String, CompanionObject) async throws -> String)?
    func generate(id: String, context: CompanionObject, model: String, reserve: @escaping () async throws -> Bool) async throws -> String {
        calls.append(id); contexts.append(context)
        return try await handler?(id, context) ?? "{\"text\":\"hello\",\"emotion\":\"happy\"}"
    }
    func receive(id: String, from: String, text: String, messageID: String, model: String) async throws -> String { receipts += 1; return "msg_receipt" }
    func reserveContinuation(_ id: String) async throws {}
    func forget(_ id: String) {}
    func interrupt() {}
    func reapStale() {}
    func close() {}
    func setHandler(_ callback: @escaping (String, CompanionObject) async throws -> String) { handler = callback }
    func count() -> Int { calls.count }
    func last() -> String? { calls.last }
}
private actor ServiceFixture {
    var running = false
    var starts = 0
    var fail = false
    func health() throws -> NativeCompanionHTTP {
        guard running else { throw NativeOpenCodeServiceError.stopped }
        return NativeCompanionHTTP(baseURL: URL(string: "http://127.0.0.1:40000")!, registeredPID: 42, registeredVersion: "2.2.5")
    }
    func start() async throws {
        starts += 1
        try await Task.sleep(nanoseconds: 30_000_000)
        if fail { throw NativeOpenCodeServiceError.startFailed }; running = true
    }
    func stopService() { running = false }
    func setFail() { fail = true }
    func stats() -> (running: Bool, starts: Int) { (running, starts) }
}

@main struct NativeCompanionTests {
    static var checks: [String] = []
    static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw NativeCompanionData.error(message) }; checks.append(message); print("PASS: \(message)")
    }
    static func main() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lite2d-native-tests-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let args = CommandLine.arguments
            guard args.count >= 5 else { throw NativeCompanionData.error("Expected helper, prompt, node and app paths") }
            let script = URL(fileURLWithPath: args[1]), promptFile = URL(fileURLWithPath: args[2]), node = args[3], executable = args[4]
            let store = try NativeCompanionStore(root: root.appendingPathComponent("store"))
            try store.set("session:\(a)", "ses_existing"); try store.set("memory:\(a)", "private")
            let first = try store.readRecord("shared.md"), revision = first["revision"] as! String
            let result = try store.updateRecord(actor: a, name: "shared.md", content: "A wrote this", revision: revision)
            try check(result["revision"] as? String != revision, "Native store retains transactional revisions")
            try check(try store.updateRecord(actor: b, name: "shared.md", content: "overwrite", revision: revision)["conflict"] as? Bool == true, "Concurrent record overwrite is refused")
            try check(try store.rows("SELECT actor FROM changes").first?["actor"] as? String == a, "Record audit preserves author")
            try check(try store.readRecord("shared.md")["exists"] as? Bool == true && store.readRecord("plans.md")["exists"] as? Bool == false, "Shared notes explicitly distinguish existing and new paths")
            let created = try store.updateRecord(actor: a, name: "plans.md", content: "A suggested a tea party.")
            try check(created["conflict"] == nil, "First shared note can be created without a prior revision read")
            try check(try store.updateRecord(actor: b, name: "plans.md", content: "Blind overwrite")["conflict"] as? Bool == true, "Omitting a revision cannot overwrite an existing shared note")
            let merged = try store.updateRecord(actor: b, name: "plans.md", content: "A suggested a tea party; B agreed.", revision: created["revision"] as? String)
            try check(merged["conflict"] == nil && (try store.readRecord("plans.md")["content"] as? String) == "A suggested a tea party; B agreed.", "Another companion can merge shared notes using the current revision")
            var rejected = false; do { _ = try store.readRecord("../bad.md") } catch { rejected = true }
            try check(rejected, "Record path traversal is rejected")
            try store.exportNotes()
            try check(try String(contentsOf: store.root.appendingPathComponent("characters/\(a)/memory.md"), encoding: .utf8) == "private", "Native memory projection matches existing file format")
            let reopened = try NativeCompanionStore(root: store.root)
            try check(reopened.get("session:\(a)") as? String == "ses_existing" && reopened.get("memory:\(a)") as? String == "private", "Existing database sessions and memory survive reopening")
            try check(try store.spend(1, now: 1_000_000) && !store.spend(1, now: 1_000_001), "Rolling request budget prevents overspend")
            try check(NativeCompanionData.text(["type": "thinking", "text": "secret"]).isEmpty && NativeCompanionData.text(["type": "tool_result", "content": "secret output"]) == "[tool completed]", "Observer normalization excludes reasoning and raw tool output")
            try check(NativeCompanionData.output("{\"command\":\"execute\"}")["skip"] as? Bool == true, "Malformed model JSON never becomes a command")
            let prompt = try NativeCompanionPrompt.load(promptFile)
            try check(NativeCompanionMCP.tools(prompt).count == 14 && prompt.system(persona: "raw ${persona}").hasSuffix("PERSONA:\nraw ${persona}"), "All 14 tool schemas and unchanged Persona composition load natively")
            let searchResult: CompanionObject = ["jsonrpc": "2.0", "id": 1, "result": ["content": [["type": "text", "text": "Title: Example\nURL: https://example.com"]]]]
            let searchJSON = try NativeCompanionData.json(searchResult)
            let searchSSE = Data(("event: message\r\ndata: " + String(decoding: searchJSON, as: UTF8.self) + "\r\n\r\n").utf8)
            try check(try NativeCompanionSearch.result(searchJSON) == NativeCompanionSearch.result(searchSSE), "Search decodes both JSON and MCP event streams while preserving source URLs")
            let searchConfig = URLSessionConfiguration.ephemeral; searchConfig.protocolClasses = [SearchProtocol.self]
            let searchSession = URLSession(configuration: searchConfig)
            defer { searchSession.invalidateAndCancel() }
            SearchProtocol.responseData = searchSSE
            let searchText = try await NativeCompanionSearch.search(query: "public topic", objective: "find facts", session: searchSession)
            let searchRequest = SearchProtocol.lastRequest!
            let body = NativeCompanionData.object(try NativeCompanionData.decode(SearchProtocol.lastBody))
            let searchParams = NativeCompanionData.object(body["params"])
            try check(searchRequest.url?.absoluteString == "https://mcp.exa.ai/mcp?tools=web_search_exa" && searchRequest.value(forHTTPHeaderField: "Authorization") == nil && searchParams["name"] as? String == "web_search_exa" && searchText.contains("https://example.com"), "Search pins its upstream endpoint and tool without forwarding local credentials")
            SearchProtocol.statusCode = 429
            var rateLimited = false
            do { _ = try await NativeCompanionSearch.search(query: "public topic", objective: "find facts", session: searchSession) } catch { rateLimited = true }
            try check(rateLimited, "Search HTTP failures return errors instead of invented results")
            let allowed = NativeCompanionRoles.rules.filter { $0["effect"] as? String == "allow" }.compactMap { $0["action"] as? String }
            try check(allowed.count == 42 && !allowed.contains(where: { $0.contains("*") || $0.contains("shell") || $0.contains("sonarqube") }), "Role permissions allow exact internal tool names and deny arbitrary third-party MCP tools")
            for invalid: CompanionObject in [["id": 1, "error": ["code": -1]], ["id": 1, "result": ["isError": true, "content": [["type": "text", "text": "failed"]]]], ["id": 2, "result": [:]]] {
                var rejected = false
                do { _ = try NativeCompanionSearch.result(NativeCompanionData.json(invalid)) } catch { rejected = true }
                try check(rejected, "Search rejects MCP errors and unrelated responses")
            }
            var invalidQuery = false
            do { _ = try await NativeCompanionSearch.search(query: " ", objective: "test") } catch { invalidQuery = true }
            try check(invalidQuery, "Empty search queries are rejected before networking")

            let registration = root.appendingPathComponent("service.json")
            var absent = false
            do { _ = try NativeCompanionHTTP.discover(registration: registration) } catch { absent = error as? NativeOpenCodeServiceError == .stopped }
            try check(absent, "Missing service registration reports stopped rather than a file error")
            try NativeCompanionData.json(["url": "http://example.com:40000", "pid": 42]).write(to: registration)
            var nonlocal = false
            do { _ = try NativeCompanionHTTP.discover(registration: registration) } catch { nonlocal = error as? NativeOpenCodeServiceError == .invalidRegistration }
            try check(nonlocal, "Service discovery rejects non-loopback registrations")
            let fixture = ServiceFixture(), serviceEvents = Events()
            let monitor = NativeOpenCodeServiceMonitor(executable: "/missing/opencode", interval: 0.08,
                health: { try await fixture.health() }, starter: { try await fixture.start() }, changed: { serviceEvents.add($0) })
            await monitor.setEnabled(true)
            async let client1 = monitor.ensureRunning()
            async let client2 = monitor.ensureRunning()
            _ = try await client1; _ = try await client2
            let firstStart = await fixture.stats()
            try check(firstStart.starts == 1 && serviceEvents.all().contains(where: { $0["state"] as? String == "starting" }), "Concurrent monitor and observer requests start the service only once")
            await fixture.stopService()
            for _ in 0..<30 {
                if await fixture.stats().running { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            let recovered = await fixture.stats()
            try check(recovered.running && recovered.starts == 2, "Monitor automatically restarts a stopped OpenCode service")
            await monitor.setEnabled(false)
            let leftRunning = await fixture.stats()
            let disabledState = await monitor.snapshot()
            try check(leftRunning.running && (disabledState["state"] as? String) == "disabled", "Disabling Companion stops monitoring without stopping OpenCode")
            await fixture.stopService()
            try await Task.sleep(nanoseconds: 200_000_000)
            try check(await fixture.stats().starts == 2, "Disabled monitoring never restarts the service")
            let failing = ServiceFixture(); await failing.setFail()
            let failedMonitor = NativeOpenCodeServiceMonitor(executable: "/missing/opencode", interval: 0.05,
                health: { try await failing.health() }, starter: { try await failing.start() }, changed: { _ in })
            await failedMonitor.setEnabled(true)
            do { _ = try await failedMonitor.ensureRunning() } catch { }
            do { _ = try await failedMonitor.ensureRunning() } catch { }
            let failedState = await failedMonitor.snapshot(), failedStats = await failing.stats()
            try check(failedState["state"] as? String == "failed" && failedStats.starts == 1, "Failed automatic startup is visible and retries use backoff")
            await failedMonitor.close(); await monitor.close()

            let claudeRoot = root.appendingPathComponent("claude"), directory = claudeRoot.appendingPathComponent("projects/-fixture")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("\(a).jsonl")
            let user: CompanionObject = ["uuid": "user-1", "parentUuid": NSNull(), "sessionId": a, "type": "user", "cwd": "/fixture", "timestamp": "2026-11-05T00:00:00.000Z", "isSidechain": false,
                "message": ["role": "user", "content": "fixture first message"]]
            let answer: CompanionObject = ["uuid": "answer-1", "parentUuid": "user-1", "sessionId": a, "type": "assistant", "cwd": "/fixture", "timestamp": "2026-11-05T00:00:01.000Z", "isSidechain": false,
                "message": ["role": "assistant", "content": [["type": "text", "text": "fixture reply"]]]]
            try (NativeCompanionData.string(user) + "\n" + NativeCompanionData.string(answer) + "\n").write(to: file, atomically: true, encoding: .utf8)
            var environment = ProcessInfo.processInfo.environment; environment["CLAUDE_CONFIG_DIR"] = claudeRoot.path
            let helper = NativeClaudeHelper(node: node, script: script, idleSeconds: 0.7, environment: environment)
            let before = await helper.diagnostics(); try check(before["starts"] as? Int == 0 && before["running"] as? Bool == false, "SDK helper is not started until requested")
            async let one = helper.call("list", ["limit": 100])
            async let two = helper.call("list", ["limit": 100])
            let listed = try await one; _ = try await two
            try check(NativeCompanionData.array(listed).contains { $0["sessionId"] as? String == a }, "Official Claude SDK lists the isolated fixture")
            let coalesced = await helper.diagnostics(); try check(coalesced["starts"] as? Int == 1 && coalesced["requests"] as? Int == 1, "Concurrent identical SDK requests coalesce into one worker call")
            let recent = NativeCompanionData.array(try await helper.call("recent", ["sessionId": a]))
            try check(recent.count == 2 && recent.last?["text"] as? String == "fixture reply", "SDK retains canonical message-chain reading")
            let reused = await helper.diagnostics(); try check(reused["starts"] as? Int == 1, "Consecutive SDK requests reuse the same Node process")
            try await Task.sleep(nanoseconds: 1_100_000_000)
            try check(await helper.diagnostics()["running"] as? Bool == false, "SDK helper exits after idle grace period")
            var denied = false; do { _ = try await helper.call("query") } catch { denied = true }
            try check(denied, "SDK worker whitelist refuses query and arbitrary methods")
            await helper.stop()

            let failureScript = root.appendingPathComponent("worker-fixture.mjs")
            try """
            import {createInterface} from 'node:readline';
            console.log(JSON.stringify({type:'ready',protocolVersion:1}));
            const lines=createInterface({input:process.stdin});
            lines.on('line',line=>{const m=JSON.parse(line);if(m.method==='info'){process.exit(7);}else if(m.method==='shutdown'){process.exit(0);}else setTimeout(()=>console.log(JSON.stringify({id:m.id,result:[]})),250);});
            """.write(to: failureScript, atomically: true, encoding: .utf8)
            let failureHelper = NativeClaudeHelper(node: node, script: failureScript, idleSeconds: 1)
            let pending = Task { try await failureHelper.call("recent", ["sessionId": a]) }
            try await Task.sleep(nanoseconds: 100_000_000)
            await failureHelper.stop()
            var revoked = false; do { _ = try await pending.value } catch { revoked = true }
            try check(revoked, "Source revocation rejects an in-flight SDK result")
            var crashed = false; do { _ = try await failureHelper.call("info", ["sessionId": a]) } catch { crashed = true }
            let beforeRetry = await failureHelper.diagnostics()["starts"] as? Int
            do { _ = try await failureHelper.call("list") } catch { }
            let afterRetry = await failureHelper.diagnostics()["starts"] as? Int
            try check(crashed && afterRetry == beforeRetry, "Worker crash applies backoff without repeated respawn")
            await failureHelper.stop()

            let observedHelper = NativeClaudeHelper(node: node, script: script, idleSeconds: 0.5, environment: environment)
            let observers = NativeCompanionObservers(codex: "/missing/codex", helper: observedHelper, claudeRoot: claudeRoot)
            try await observers.setClaudeEnabled(true)
            let firstPoll = try await observers.poll("claude", excluded: [])
            try check(firstPoll.sessions.count == 1 && firstPoll.changes.isEmpty, "First SDK baseline does not replay old history")
            let callsBefore = await observedHelper.diagnostics()["requests"] as? Int
            try await Task.sleep(nanoseconds: 1_100_000_000)
            _ = try await observers.poll("claude", excluded: []); _ = try await observers.poll("claude", excluded: [])
            let quiet = await observedHelper.diagnostics()
            try check(quiet["starts"] as? Int == 1 && quiet["running"] as? Bool == false && quiet["requests"] as? Int == callsBefore, "Quiet polls never restart Node or invoke SDK")
            let next: CompanionObject = ["uuid": "user-2", "parentUuid": "answer-1", "sessionId": a, "type": "user", "cwd": "/fixture", "timestamp": "2026-11-05T00:00:02.000Z", "message": ["role": "user", "content": "a real change"]]
            let reply: CompanionObject = ["uuid": "answer-2", "parentUuid": "user-2", "sessionId": a, "type": "assistant", "cwd": "/fixture", "timestamp": "2026-11-05T00:00:03.000Z", "isSidechain": false, "message": ["role": "assistant", "content": [["type": "text", "text": "a changed reply"]]]]
            let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd(); try handle.write(contentsOf: Data((NativeCompanionData.string(next) + "\n" + NativeCompanionData.string(reply) + "\n").utf8)); try handle.close()
            var changedPoll = (sessions: [NativeObservedSession](), changes: [CompanionObject]())
            for _ in 0..<16 {
                try await Task.sleep(nanoseconds: 500_000_000)
                changedPoll = try await observers.poll("claude", excluded: [])
                if !changedPoll.changes.isEmpty { break }
            }
            try check(changedPoll.changes.count == 1, "Swift FSEvents wakes SDK only after a real transcript change")
            let afterChange = await observedHelper.diagnostics()
            for _ in 0..<20 { _ = try await observers.poll("claude", excluded: []) }
            let afterBurst = await observedHelper.diagnostics()
            try check(afterChange["requests"] as? Int == afterBurst["requests"] as? Int && afterBurst["starts"] as? Int == 2, "Repeated change polls reuse the worker and never launch one process per poll")
            try await observers.setClaudeEnabled(false)
            try check(await observedHelper.diagnostics()["running"] as? Bool == false, "Revoking Claude source stops its helper")
            await observers.close()

            let events = Events(), fake = FakeRoles(), runtimeRoot = root.appendingPathComponent("runtime")
            let runtime = NativeCompanionRuntime(root: runtimeRoot, promptFile: promptFile, opencode: "/missing/opencode", codex: "/missing/codex", node: node, helperScript: script, executable: executable, roles: fake, manageOpenCodeService: false, emit: events.add)
            try await runtime.start(automatic: false)
            let chars: [CompanionObject] = [["id": a, "name": "A", "enabled": true, "visible": true], ["id": b, "name": "B", "enabled": true, "visible": true]]
            await runtime.command(["type": "configure", "config": ["enabled": true, "characters": chars, "intervalMinutes": 0, "hourlyRequests": 12]])
            await runtime.command(["type": "trigger", "characterId": b]); await runtime.waitForTopic()
            try check(await fake.last() == b && events.all().contains { $0["type"] as? String == "utterance" && $0["characterId"] as? String == b }, "Native manual trigger selects the requested Persona")
            await runtime.command(["type": "configure", "config": ["enabled": true, "paused": true, "characters": chars]])
            let count = await fake.count(); await runtime.command(["type": "trigger", "characterId": a])
            try check(await fake.count() == count && events.all().contains { $0["type"] as? String == "error" && $0["requestType"] as? String == "trigger" }, "Native Do Not Disturb rejects manual generation")
            await runtime.command(["type": "configure", "config": ["enabled": true, "hourlyRequests": 1, "characters": chars]])
            await runtime.command(["type": "trigger", "characterId": a])
            try check(await fake.count() == count && events.all().contains { ($0["message"] as? String ?? "").contains("budget") }, "Native manual triggers retain the shared request budget")
            await runtime.command(["type": "configure", "config": ["enabled": true, "hourlyRequests": 12, "characters": chars]])
            await fake.setHandler { _, _ in try await Task.sleep(nanoseconds: 30_000_000_000); return "late speech" }
            await runtime.command(["type": "trigger", "characterId": a])
            try await Task.sleep(nanoseconds: 30_000_000)
            await runtime.command(["type": "stop"]); await runtime.waitForTopic()
            try check(!events.all().contains { $0["text"] as? String == "late speech" }, "Cancellation prevents delayed generated speech from appearing")
            await runtime.close()
            print("PASS: \(checks.count) native Companion checks")
            try FileManager.default.removeItem(at: root)
        } catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }
}
