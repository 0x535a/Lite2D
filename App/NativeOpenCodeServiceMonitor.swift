import Foundation

// Service lifecycle is separate from read-only history observation. The only
// mutating CLI operation is the explicitly authorized `opencode service start`.
// Never stop/restart/upgrade the user's service or resume any work session.
actor NativeOpenCodeServiceMonitor {
    typealias Health = () async throws -> NativeCompanionHTTP
    typealias Starter = () async throws -> Void
    private let health: Health
    private let starter: Starter?
    private let executable: String
    private let environment: [String: String]?
    private let registration: URL?
    private let interval: Double
    private let changed: (CompanionObject) async -> Void
    private var enabled = false
    private var revision = 0
    private var loop: Task<Void, Never>?
    private var attempt: (id: UUID, task: Task<NativeCompanionHTTP, Error>)?
    private var command: NativeCompanionProcess?
    private var nextRetry = Date.distantPast
    private var failures = 0
    private var state: CompanionObject = ["state": "disabled"]

    init(executable: String, registration: URL? = nil, environment: [String: String]? = nil, interval: Double = 5,
         health: Health? = nil, starter: Starter? = nil, changed: @escaping (CompanionObject) async -> Void) {
        self.executable = executable; self.registration = registration; self.environment = environment; self.interval = interval
        self.health = health ?? { try await NativeCompanionHTTP.availableService(registration: registration) }
        self.starter = starter; self.changed = changed
    }
    private func publish(_ value: CompanionObject) async {
        guard NativeCompanionData.string(value) != NativeCompanionData.string(state) else { return }
        state = value; await changed(value)
    }
    func setEnabled(_ flag: Bool) async {
        guard enabled != flag else { return }
        enabled = flag; revision += 1
        loop?.cancel(); loop = nil
        if !flag {
            attempt?.task.cancel(); attempt = nil; command?.close(); command = nil
            failures = 0; nextRetry = .distantPast; await publish(["state": "disabled"]); return
        }
        await publish(["state": "checking"])
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                _ = try? await self.ensureRunning()
                do { try await Task.sleep(nanoseconds: UInt64(max(0.05, self.interval) * 1_000_000_000)) } catch { return }
            }
        }
    }
    func ensureRunning() async throws -> NativeCompanionHTTP {
        guard enabled else { throw NativeOpenCodeServiceError.monitoringDisabled }
        if let attempt { return try await attempt.task.value }
        let id = UUID(), expected = revision
        let work = Task<NativeCompanionHTTP, Error> {
            if let client = try? await health() {
                guard enabled && expected == revision else { throw CancellationError() }
                failures = 0; nextRetry = .distantPast
                await publish(running(client)); return client
            }
            guard enabled && expected == revision else { throw CancellationError() }
            guard Date() >= nextRetry else { throw NativeOpenCodeServiceError.startFailed }
            await publish(["state": "starting"])
            do {
                if let starter { try await starter() } else { try await startCommand() }
                for _ in 0..<40 {
                    try Task.checkCancellation()
                    guard enabled && expected == revision else { throw CancellationError() }
                    if let client = try? await health() {
                        failures = 0; nextRetry = .distantPast; await publish(running(client)); return client
                    }
                    try await Task.sleep(nanoseconds: 250_000_000)
                }
                throw NativeOpenCodeServiceError.startFailed
            } catch {
                guard enabled && expected == revision else { throw CancellationError() }
                failures += 1
                nextRetry = Date().addingTimeInterval(min(60, 5 * pow(2, Double(min(failures - 1, 4)))))
                let missing = (error as? NativeOpenCodeServiceError) == .executableMissing
                await publish(["state": "failed", "reason": missing ? "executable_missing" : "start_failed"])
                throw missing ? NativeOpenCodeServiceError.executableMissing : NativeOpenCodeServiceError.startFailed
            }
        }
        attempt = (id, work)
        do { let client = try await work.value; if attempt?.id == id { attempt = nil }; return client }
        catch { if attempt?.id == id { attempt = nil }; throw error }
    }
    private func running(_ client: NativeCompanionHTTP) -> CompanionObject {
        var value: CompanionObject = ["state": "running"]
        value["pid"] = client.registeredPID; value["version"] = client.registeredVersion
        return value
    }
    private func startCommand() async throws {
        guard FileManager.default.isExecutableFile(atPath: executable) else { throw NativeOpenCodeServiceError.executableMissing }
        let child = NativeCompanionProcess(), exit = NativeAsyncValue<Int32>()
        child.onExit = { [weak child] in exit.resolve(.success(child?.process.terminationStatus ?? -1)) }
        command = child
        do {
            try child.start(executable, arguments: ["service", "start"], environment: environment)
            let status = try await exit.wait(seconds: 25)
            child.close(); command = nil
            guard status == 0 else { throw NativeOpenCodeServiceError.startFailed }
        } catch { child.close(); command = nil; throw error }
    }
    func snapshot() -> CompanionObject { state }
    func close() async { await setEnabled(false) }
}
