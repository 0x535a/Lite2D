import Foundation

// Explicit headless test entrypoint. Requires an isolated data root, never falls
// back to the user's normal database, and does not initialize NSApplication.
enum NativeCompanionProbe {
    static func run() -> Never {
        Task.detached {
            let env = ProcessInfo.processInfo.environment
            guard let directory = env["LITE2D_NATIVE_PROBE_ROOT"], directory.hasPrefix("/"), let resources = Bundle.main.resourceURL, let executable = Bundle.main.executablePath else {
                fputs("Isolated LITE2D_NATIVE_PROBE_ROOT required\n", stderr); exit(2)
            }
            let root = URL(fileURLWithPath: directory)
            let providers = env["LITE2D_PROBE_PROVIDERS"].flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }.flatMap { try? NativeCompanionData.decode($0) as? CompanionObject }
            let runtime = NativeCompanionRuntime(root: root, promptFile: resources.appendingPathComponent("Companion/prompt.json"),
                opencode: env["LITE2D_OPENCODE"] ?? "/opt/homebrew/bin/opencode", codex: env["LITE2D_CODEX"] ?? "/opt/homebrew/bin/codex",
                node: env["LITE2D_NODE"] ?? "/opt/homebrew/bin/node", helperScript: resources.appendingPathComponent("Companion/claude-helper.mjs"), executable: executable,
                idleSeconds: Double(env["LITE2D_HELPER_IDLE_SECONDS"] ?? "60") ?? 60, providers: providers,
                manageOpenCodeService: env["LITE2D_PROBE_MANAGE_OPENCODE_SERVICE"] == "1") { event in
                    print(NativeCompanionData.string(event)); fflush(stdout)
                }
            do {
                try await runtime.start(automatic: false)
                while let line = readLine() {
                    guard let data = line.data(using: .utf8), let command = try NativeCompanionData.decode(data) as? CompanionObject else { continue }
                    switch command["type"] as? String {
                    case "daily-run":
                        let now = Date(timeIntervalSince1970: command["now"] as? Double ?? Date().timeIntervalSince1970)
                        await runtime.runDaily(now: now)
                        print(NativeCompanionData.string(["type": "daily.done", "data": await runtime.diagnostics()])); fflush(stdout)
                    case "poll": await runtime.tick()
                    case "wait": await runtime.waitForTopic()
                    case "diagnostics": print(NativeCompanionData.string(["type": "diagnostics", "data": await runtime.diagnostics()])); fflush(stdout)
                    case "sdk-list":
                        let start = Date()
                        let rows = NativeCompanionData.array(try await runtime.helper.call("list", ["limit": 100]))
                        print(NativeCompanionData.string(["type": "sdk.result", "count": rows.count, "durationMs": Date().timeIntervalSince(start) * 1000])); fflush(stdout)
                    case "sleep": try await Task.sleep(nanoseconds: UInt64(min(max(command["seconds"] as? Double ?? 0, 0), 60) * 1_000_000_000))
                    default: await runtime.command(command)
                    }
                }
                await runtime.close(); exit(0)
            } catch {
                print(NativeCompanionData.string(["type": "probe.error", "message": error.localizedDescription])); fflush(stdout)
                await runtime.close(); exit(1)
            }
        }
        RunLoop.main.run(); exit(0)
    }
}
