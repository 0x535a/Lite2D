import Foundation
import Network

final class NativeAsyncValue<Value> {
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    private var continuation: CheckedContinuation<Value, Error>?
    func resolve(_ value: Result<Value, Error>) {
        let pending: CheckedContinuation<Value, Error>? = lock.withLock {
            guard result == nil else { return nil }; result = value
            let old = continuation; continuation = nil; return old
        }
        pending?.resume(with: value)
    }
    func wait(seconds: Double) async throws -> Value {
        let timer = DispatchWorkItem { [weak self] in self?.resolve(.failure(NativeCompanionData.error("Agent startup timeout"))) }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: timer)
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { cont in
            let ready: Result<Value, Error>? = lock.withLock {
                if let result { return result }; continuation = cont; return nil
            }
            if let ready { cont.resume(with: ready) }
        }
    }
}

struct NativeCompanionHTTP {
    let baseURL: URL
    var authorization: String?
    func request(_ method: String, _ path: String, query: [String: String] = [:], body: CompanionObject? = nil, timeout: Double = 20) async throws -> Any {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: components.url!, timeoutInterval: timeout)
        request.httpMethod = method; request.setValue(authorization, forHTTPHeaderField: "Authorization")
        if let body { request.httpBody = try NativeCompanionData.json(body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let object = (try? NativeCompanionData.decode(data)) as? CompanionObject
            let message = object?["message"] as? String ?? NativeCompanionData.object(object?["error"])["message"] as? String ?? "Agent request failed"
            throw NativeCompanionData.error(NativeCompanionData.clean("\(message) (\(status))", limit: 240))
        }
        return data.isEmpty ? [:] : try NativeCompanionData.decode(data)
    }
    func get(_ path: String, _ query: [String: String] = [:]) async throws -> CompanionObject { NativeCompanionData.object(try await request("GET", path, query: query)) }
    func post(_ path: String, _ body: CompanionObject = [:]) async throws -> CompanionObject { NativeCompanionData.object(try await request("POST", path, body: body)) }
    static func discover() throws -> Self {
        let base = ProcessInfo.processInfo.environment["XDG_STATE_HOME"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/state")
        let info = NativeCompanionData.object(try NativeCompanionData.decode(Data(contentsOf: base.appendingPathComponent("opencode/service.json"))))
        guard let value = info["url"] as? String, let url = URL(string: value), ["127.0.0.1", "localhost", "::1"].contains(url.host ?? ""), ["http", "https"].contains(url.scheme ?? "") else { throw NativeCompanionData.error("OpenCode local service unavailable") }
        let auth = (info["password"] as? String).map { "Basic " + Data("opencode:\($0)".utf8).base64EncodedString() }
        return Self(baseURL: url, authorization: auth)
    }
}

// Owns only explicitly spawned processes. JSON-RPC is a fixed read whitelist;
// no generic Agent mutation endpoint is exposed to observed work sessions.
final class NativeCompanionProcess {
    let process = Process()
    private let input = Pipe(), output = Pipe(), errors = Pipe()
    private let lock = NSLock()
    private var buffers: [Int32: Data] = [:]
    private var sequence = 0
    private var pending: [Int: (CheckedContinuation<Any, Error>, DispatchWorkItem)] = [:]
    var onLine: ((String) -> Void)?
    var onExit: (() -> Void)?
    func start(_ executable: String, arguments: [String], environment: [String: String]? = nil, directory: URL? = nil) throws {
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments; process.environment = environment; process.currentDirectoryURL = directory
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        for handle in [output.fileHandleForReading, errors.fileHandleForReading] {
            handle.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil; return }
                self?.consume(data, from: handle.fileDescriptor)
            }
        }
        process.terminationHandler = { [weak self] _ in self?.failed(NativeCompanionData.error("Agent process disconnected")); self?.onExit?() }
        try process.run()
    }
    private func consume(_ data: Data, from descriptor: Int32) {
        let lines: [String] = lock.withLock {
            var buffer = buffers[descriptor] ?? Data(); buffer.append(data)
            if buffer.count > 32 * 1024 * 1024 { buffers[descriptor] = Data(); return [] }
            var lines: [String] = []
            while let end = buffer.firstIndex(of: 10) {
                lines.append(String(decoding: buffer.prefix(upTo: end), as: UTF8.self)); buffer.removeSubrange(...end)
            }
            buffers[descriptor] = buffer; return lines
        }
        for line in lines {
            onLine?(line)
            guard let data = line.data(using: .utf8), let object = try? NativeCompanionData.decode(data) as? CompanionObject, let id = object["id"] as? Int,
                  let item = lock.withLock({ pending.removeValue(forKey: id) }) else { continue }
            item.1.cancel()
            if let error = object["error"] as? CompanionObject { item.0.resume(throwing: NativeCompanionData.error(NativeCompanionData.clean(error["message"] as? String ?? "Agent request failed", limit: 200))) }
            else { item.0.resume(returning: object["result"] ?? [:]) }
        }
    }
    func rpc(_ method: String, _ params: CompanionObject) async throws -> CompanionObject {
        guard ["initialize", "thread/list", "thread/read", "thread/turns/list", "thread/loaded/list"].contains(method) else { throw NativeCompanionData.error("Observer method denied") }
        return NativeCompanionData.object(try await call(method, params))
    }
    func helperRPC(_ method: String, _ params: CompanionObject) async throws -> Any {
        guard ["list", "info", "recent"].contains(method) else { throw NativeCompanionData.error("SDK helper method denied") }
        return try await call(method, params)
    }
    private func call(_ method: String, _ params: CompanionObject) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock(); sequence += 1; let id = sequence
            let timeout = DispatchWorkItem { [weak self] in self?.expire(id) }
            pending[id] = (continuation, timeout); lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: timeout)
            do { try write(["id": id, "method": method, "params": params]) } catch { expire(id) }
        }
    }
    func write(_ object: CompanionObject) throws {
        var data = try NativeCompanionData.json(object); data.append(10)
        try lock.withLock {
            guard process.isRunning else { throw NativeCompanionData.error("Agent unavailable") }
            try input.fileHandleForWriting.write(contentsOf: data)
        }
    }
    private func expire(_ id: Int) {
        let item = lock.withLock { pending.removeValue(forKey: id) }; item?.0.resume(throwing: NativeCompanionData.error("Agent request timeout"))
    }
    private func failed(_ error: Error) {
        let items = lock.withLock { let all = pending; pending = [:]; return all }
        for item in items.values { item.1.cancel(); item.0.resume(throwing: error) }
    }
    func close() {
        output.fileHandleForReading.readabilityHandler = nil; errors.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
            let child = process
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { if child.isRunning { kill(child.processIdentifier, SIGKILL) } }
        }
        failed(NativeCompanionData.error("Agent stopped"))
    }
}

final class NativeCompanionBroker {
    private let queue = DispatchQueue(label: "Lite2D.Companion.Tools", qos: .utility)
    private var listener: NWListener?
    private let handler: (String, CompanionObject) async throws -> Any
    init(handler: @escaping (String, CompanionObject) async throws -> Any) { self.handler = handler }
    func start() async throws -> URL {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters); self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        let value = NativeAsyncValue<URL>()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: value.resolve(.success(URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/tools")!))
            case .failed(let error): value.resolve(.failure(error))
            default: break
            }
        }
        listener.start(queue: queue)
        return try await value.wait(seconds: 10)
    }
    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, Data())
    }
    private func receive(_ connection: NWConnection, _ accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { connection.cancel(); return }
            var buffer = accumulated; if let data { buffer.append(data) }
            guard buffer.count < 75000 else { self.reply(connection, 400, ["error": "Tool input too large"]); return }
            guard let separator = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if done || error != nil { connection.cancel() } else { self.receive(connection, buffer) }; return
            }
            let header = String(decoding: buffer[..<separator.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            var fields: [String: String] = [:]
            for line in header.dropFirst() { let parts = line.split(separator: ":", maxSplits: 1); if parts.count == 2 { fields[String(parts[0]).lowercased()] = parts[1].trimmingCharacters(in: .whitespaces) } }
            guard header.first == "POST /tools HTTP/1.1", let size = fields["content-length"].flatMap(Int.init), (0...70000).contains(size),
                  let authorization = fields["authorization"], authorization.hasPrefix("Bearer ") else { self.reply(connection, 403, ["error": "Tool request denied"]); return }
            guard buffer.count - separator.upperBound >= size else {
                if done || error != nil { connection.cancel() } else { self.receive(connection, buffer) }; return
            }
            let body = buffer[separator.upperBound..<(separator.upperBound + size)]
            let token = String(authorization.dropFirst(7))
            Task {
                do {
                    let request = NativeCompanionData.object(try NativeCompanionData.decode(Data(body)))
                    let result = try await self.handler(token, request)
                    self.reply(connection, 200, result)
                } catch { self.reply(connection, 400, ["error": NativeCompanionData.clean(error.localizedDescription, limit: 250)]) }
            }
        }
    }
    private func reply(_ connection: NWConnection, _ code: Int, _ value: Any) {
        let body = (try? NativeCompanionData.json(value)) ?? Data("{}".utf8)
        var data = Data("HTTP/1.1 \(code) \(code == 200 ? "OK" : "Error")\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8); data.append(body)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }
    func close() { listener?.cancel(); listener = nil }
}

enum NativeCompanionMCP {
    static let toolNames = ["companion_list_characters", "companion_send_message", "observer_list_sessions", "observer_get_activity", "observer_get_recent_work", "observer_get_session_summary", "observer_watch_session", "observer_unwatch_session", "public_record_list", "public_record_read", "public_record_update", "private_memory_read", "private_memory_update"]
    static func tools(_ prompt: NativeCompanionPrompt) -> [CompanionObject] {
        func schema(_ properties: [String], _ required: [String]) -> CompanionObject {
            ["type": "object", "properties": Dictionary(uniqueKeysWithValues: properties.map { ($0, ["type": "string"]) }), "required": required, "additionalProperties": false]
        }
        let fields: [String: [String]] = [
            "companion_send_message": ["to", "text"], "observer_get_activity": ["sessionRef"], "observer_get_session_summary": ["sessionRef"],
            "observer_watch_session": ["sessionRef"], "observer_unwatch_session": ["sessionRef"], "public_record_read": ["path"],
            "public_record_update": ["path", "content", "expectedRevision"], "private_memory_update": ["content"]
        ]
        return toolNames.map { name in ["name": name, "description": prompt.toolDescriptions[name] ?? name, "inputSchema": schema(fields[name] ?? [], fields[name] ?? [])] }
    }
    static func run(promptFile: URL) {
        guard let prompt = try? NativeCompanionPrompt.load(promptFile) else { return }
        let tools = tools(prompt)
        while let line = readLine() {
            guard line.utf8.count < 75000, let data = line.data(using: .utf8), let request = try? NativeCompanionData.decode(data) as? CompanionObject, let id = request["id"] else { continue }
            var response: CompanionObject = ["jsonrpc": "2.0", "id": id]
            let params = NativeCompanionData.object(request["params"])
            switch request["method"] as? String {
            case "initialize": response["result"] = ["protocolVersion": params["protocolVersion"] ?? "2024-11-05", "capabilities": ["tools": [:]], "serverInfo": ["name": "lite2d-companion", "version": "1.2.0"]] as CompanionObject
            case "ping": response["result"] = [:] as CompanionObject
            case "tools/list": response["result"] = ["tools": tools]
            case "tools/call":
                guard let name = params["name"] as? String, tools.contains(where: { $0["name"] as? String == name }),
                      let endpoint = ProcessInfo.processInfo.environment["LITE2D_TOOL_ENDPOINT"].flatMap(URL.init(string:)), endpoint.host == "127.0.0.1",
                      let token = ProcessInfo.processInfo.environment["LITE2D_TOOL_TOKEN"] else { response["error"] = ["code": -32603, "message": "Companion tool unavailable"]; print(NativeCompanionData.string(response)); continue }
                var r = URLRequest(url: endpoint, timeoutInterval: 15); r.httpMethod = "POST"
                r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization"); r.setValue("application/json", forHTTPHeaderField: "Content-Type")
                r.httpBody = try? NativeCompanionData.json(["name": name, "arguments": params["arguments"] ?? [:]])
                let semaphore = DispatchSemaphore(value: 0)
                var result: CompanionObject = ["content": [["type": "text", "text": "Companion tool unavailable"]], "isError": true]
                let task = URLSession.shared.dataTask(with: r) { data, status, _ in
                    if let data, let object = try? NativeCompanionData.decode(data) {
                        result = ["content": [["type": "text", "text": NativeCompanionData.string(object)]], "isError": (status as? HTTPURLResponse)?.statusCode != 200]
                    }
                    semaphore.signal()
                }
                task.resume(); if semaphore.wait(timeout: .now() + 16) == .timedOut { task.cancel() }
                response["result"] = result
            default: response["error"] = ["code": -32601, "message": "Unsupported method"]
            }
            print(NativeCompanionData.string(response)); fflush(stdout)
        }
    }
}
