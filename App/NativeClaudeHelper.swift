import Foundation
import CoreServices

// SDK-only worker pool. It has no repeating timer; an idle deadline exists only
// after an actual request. Swift owns persistence, observation and scheduling.
actor NativeClaudeHelper {
    let node: String
    let script: URL
    let environment: [String: String]?
    let idleSeconds: Double
    private var process: NativeCompanionProcess?
    private var starting: Task<NativeCompanionProcess, Error>?
    private var idle: Task<Void, Never>?
    private var requests: [String: Task<Any, Error>] = [:]
    private var revision = 0
    private var inFlight = 0
    private var starts = 0
    private var calls = 0
    private var retryAfter = Date.distantPast
    private var failures = 0
    init(node: String, script: URL, idleSeconds: Double = 60, environment: [String: String]? = nil) {
        self.node = node; self.script = script; self.idleSeconds = idleSeconds; self.environment = environment
    }
    private func worker() async throws -> NativeCompanionProcess {
        if let process, process.process.isRunning { return process }
        if let starting { return try await starting.value }
        guard Date() >= retryAfter else { throw NativeCompanionData.error("Claude SDK helper is backing off after a failure") }
        let expected = revision
        let task = Task<NativeCompanionProcess, Error> {
            let child = NativeCompanionProcess(), ready = NativeAsyncValue<Bool>()
            child.onLine = { line in
                guard let data = line.data(using: .utf8), let value = try? NativeCompanionData.decode(data) as? CompanionObject, value["type"] as? String == "ready", value["protocolVersion"] as? Int == 1 else { return }
                ready.resolve(.success(true))
            }
            child.onExit = { ready.resolve(.failure(NativeCompanionData.error("Claude SDK helper exited"))) }
            do {
                try child.start(node, arguments: ["--disable-warning=ExperimentalWarning", script.path], environment: environment)
                _ = try await ready.wait(seconds: 12)
                guard revision == expected else { child.close(); throw NativeCompanionData.error("Claude access revoked") }
                process = child; starts += 1; return child
            } catch { child.close(); throw error }
        }
        starting = task
        do { let child = try await task.value; starting = nil; return child }
        catch { starting = nil; backoff(); throw error }
    }
    func call(_ method: String, _ params: CompanionObject = [:]) async throws -> Any {
        guard ["list", "info", "recent"].contains(method) else { throw NativeCompanionData.error("SDK helper method denied") }
        let key = method + NativeCompanionData.string(params)
        if let pending = requests[key] { return try await pending.value }
        idle?.cancel(); idle = nil
        let expected = revision
        let task = Task<Any, Error> {
            inFlight += 1
            defer { inFlight -= 1 }
            let child = try await worker(); calls += 1
            let value = try await child.helperRPC(method, params)
            guard expected == revision else { throw NativeCompanionData.error("Claude access revoked") }
            return value
        }
        requests[key] = task
        do {
            let value = try await task.value; requests.removeValue(forKey: key); failures = 0; retryAfter = .distantPast; scheduleIdle(); return value
        } catch {
            requests.removeValue(forKey: key)
            if expected == revision { backoff(); process?.close(); process = nil }
            scheduleIdle(); throw error
        }
    }
    private func backoff() {
        failures += 1
        let seconds = min(300.0, 5 * pow(2, Double(min(failures - 1, 6))))
        retryAfter = Date().addingTimeInterval(seconds)
    }
    private func scheduleIdle() {
        guard requests.isEmpty, inFlight == 0, process != nil else { return }
        idle?.cancel()
        let expected = revision, seconds = idleSeconds
        idle = Task {
            do { try await Task.sleep(nanoseconds: UInt64(max(0.05, seconds) * 1_000_000_000)) } catch { return }
            guard revision == expected, requests.isEmpty, inFlight == 0 else { return }
            let old = process; process = nil; idle = nil
            try? old?.write(["method": "shutdown"])
            Task {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if old?.process.isRunning == true { old?.close() }
            }
        }
    }
    func diagnostics() -> CompanionObject { ["running": process?.process.isRunning == true, "starts": starts, "requests": calls, "inFlight": inFlight, "pending": requests.count, "pid": process?.process.processIdentifier ?? 0] }
    func stop() {
        revision += 1; idle?.cancel(); idle = nil; starting?.cancel(); starting = nil
        for task in requests.values { task.cancel() }; requests = [:]
        process?.close(); process = nil
        failures = 0; retryAfter = .distantPast
    }
}

// FSEvents inspects paths only, never JSONL content. Dropped/root events cause a
// one-shot SDK reconciliation; quiet polling does not start the helper.
final class NativeClaudeWatcher {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "Lite2D.ClaudeChanges", qos: .utility)
    private let lock = NSLock()
    private var version = 0
    private var touched = Date.distantPast
    private var firstTouched = Date.distantPast
    let directory: URL
    private let canonicalPath: String
    init(directory: URL) {
        self.directory = directory.standardizedFileURL
        if let resolved = realpath(directory.path, nil) { canonicalPath = String(cString: resolved); free(resolved) }
        else { canonicalPath = directory.standardizedFileURL.path }
    }
    func start() throws {
        guard stream == nil else { return }
        var watch = directory
        while !FileManager.default.fileExists(atPath: watch.path), watch.path != "/" { watch.deleteLastPathComponent() }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<NativeClaudeWatcher>.fromOpaque(info).takeUnretainedValue()
            let values = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            for i in 0..<min(count, values.count) {
                let path = values[i]
                let dropped = flags[i] & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged) != 0
                if dropped || path == watcher.canonicalPath || path.hasPrefix(watcher.canonicalPath + "/") { watcher.markChanged(); break }
            }
        }
        guard let stream = FSEventStreamCreate(nil, callback, &context, [watch.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1, FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer)) else { throw NativeCompanionData.error("Cannot watch Claude history changes") }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else { stop(); throw NativeCompanionData.error("Cannot start Claude history watcher") }
    }
    func markChanged() { lock.withLock { if touched == .distantPast { firstTouched = Date() }; touched = Date(); version += 1 } }
    func snapshot() -> (version: Int, last: Date, first: Date) { lock.withLock { (version, touched, firstTouched) } }
    func resetQuietWindow(version: Int) { lock.withLock { if self.version == version { touched = .distantPast; firstTouched = .distantPast } } }
    func stop() { if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }; stream = nil }
    deinit { stop() }
}
