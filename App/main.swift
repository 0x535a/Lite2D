import AppKit
import OpenGL.GL

final class AppDelegate: NSObject, NSApplicationDelegate {
    var manager: ModelInstanceManager!
    var status: StatusBarController!
    var exitCode: Int32 = 0
    var selfTest: SelfTestRunner?
    var benchmark: BenchmarkRunner?
    private var terminating = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        do { try L2DBridge.startRuntime(at: Bundle.main.resourcePath!) }
        catch { NSLog("Runtime failed: %@", error.localizedDescription); exitCode = 1; NSApp.terminate(nil); return }
        let probeDirectory = ProcessInfo.processInfo.environment["LITE2D_PROBE_DIR"]
        let store = probeDirectory.map { SettingsStore(url: URL(fileURLWithPath: $0).appendingPathComponent("settings.json")) } ?? SettingsStore()
        manager = ModelInstanceManager(store: store)
        status = StatusBarController(manager: manager)
        if probeDirectory == nil { manager.restore() }
        let paths = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("--") }
        for path in paths {
            do { _ = try manager.add(URL(fileURLWithPath: path)) }
            catch { NSLog("模型载入失败：%@", error.localizedDescription); exitCode = 2 }
        }
        if CommandLine.arguments.contains("--self-test") || CommandLine.arguments.contains("--verify-restore") {
            let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LITE2D_TEST_OUTPUT"] ?? ".local/verification/integration")
            let runner = SelfTestRunner(manager: manager, status: status, output: output) { [weak self] code in
                self?.exitCode = code; NSApp.terminate(nil)
            }
            selfTest = runner
            if CommandLine.arguments.contains("--verify-restore") { runner.verifyRestored() } else { runner.run() }
            return
        }
        if CommandLine.arguments.contains("--benchmark") {
            let env = ProcessInfo.processInfo.environment
            let output = URL(fileURLWithPath: env["LITE2D_BENCH_OUTPUT"] ?? ".local/verification/benchmark")
            let runner = BenchmarkRunner(manager: manager, output: output,
                                         staticSeconds: Double(env["LITE2D_STATIC_SECONDS"] ?? "300") ?? 300,
                                         movingSeconds: Double(env["LITE2D_MOVING_SECONDS"] ?? "120") ?? 120) { [weak self] code in
                self?.exitCode = code; NSApp.terminate(nil)
            }
            benchmark = runner; runner.run(); return
        }
        if let directory = probeDirectory {
            guard let controller = manager.records.first?.controller else { exitCode = 2; NSApp.terminate(nil); return }
            controller.view.onFrame = { [weak self] view in
                guard view.frames == 30, let frame = view.capture() else { return }
                do {
                    try frame.data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("app-frame.rgba"))
                    NSLog("APP_PROBE width=%d height=%d frames=%d glError=%u", frame.width, frame.height, view.frames, frame.glError)
                } catch { self?.exitCode = 3 }
                NSApp.terminate(nil)
            }
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        guard !terminating else { return }; terminating = true
        manager?.shutdown(); L2DBridge.stopRuntime()
        if exitCode != 0 { exit(exitCode) }
    }
}
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
exit(delegate.exitCode)
