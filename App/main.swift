import AppKit
import OpenGL.GL

final class AppDelegate: NSObject, NSApplicationDelegate {
    var manager: ModelInstanceManager!
    var status: StatusBarController!
    var exitCode: Int32 = 0
    var selfTest: SelfTestRunner?
    var benchmark: BenchmarkRunner?
    var companionTest: CompanionSelfTest?
    private var terminating = false
    private var languageObserver: NSObjectProtocol?
    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--check-login-item-registration") {
            Task { @MainActor in
                do {
                    let result = try await LaunchAtLogin().checkRegistration()
                    let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
                    print(String(decoding: data, as: UTF8.self))
                } catch {
                    NSLog("登录项登记核验失败：%@", error.localizedDescription)
                    exitCode = 1
                }
                NSApp.terminate(nil)
            }
            return
        }
        if CommandLine.arguments.contains("--login-item-status") {
            let value: [String: Any] = ["status": LaunchAtLogin().statusName, "bundlePath": Bundle.main.bundlePath]
            if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
               let text = String(data: data, encoding: .utf8) { print(text) }
            NSApp.terminate(nil)
            return
        }
        do { try L2DBridge.startRuntime(at: Bundle.main.resourcePath!) }
        catch { NSLog("Runtime failed: %@", error.localizedDescription); exitCode = 1; NSApp.terminate(nil); return }
        let probeDirectory = ProcessInfo.processInfo.environment["LITE2D_PROBE_DIR"]
        let store = probeDirectory.map { SettingsStore(url: URL(fileURLWithPath: $0).appendingPathComponent("settings.json")) } ?? SettingsStore()
        manager = ModelInstanceManager(store: store)
        status = StatusBarController(manager: manager)
        installApplicationMenu()
        languageObserver = NotificationCenter.default.addObserver(forName: .appLanguageChanged, object: nil, queue: .main) { [weak self] _ in
            self?.installApplicationMenu()
        }
        if probeDirectory == nil { manager.restore() }
        let paths = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("--") }
        for path in paths {
            do { _ = try manager.add(URL(fileURLWithPath: path)) }
            catch { NSLog("模型载入失败：%@", error.localizedDescription); exitCode = 2 }
        }
        if CommandLine.arguments.contains("--companion-self-test") {
            let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LITE2D_TEST_OUTPUT"] ?? ".local/verification/companion")
            let test = CompanionSelfTest(manager: manager, status: status, output: output) { [weak self] code in self?.exitCode = code; NSApp.terminate(nil) }
            companionTest = test; test.run(); return
        }
        if CommandLine.arguments.contains("--self-test") || CommandLine.arguments.contains("--verify-restore") {
            let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LITE2D_TEST_OUTPUT"] ?? ".local/verification/integration")
            let runner = SelfTestRunner(manager: manager, status: status, output: output) { [weak self] code in
                self?.exitCode = code
                let hold = min(max(Double(ProcessInfo.processInfo.environment["LITE2D_LEAK_SCAN_HOLD_SECONDS"] ?? "0") ?? 0, 0), 60)
                if code == 0 && hold > 0 {
                    // A bounded, quiescent post-stress window for the external
                    // leaks scanner; normal app launches never enter this path.
                    self?.manager.setSleeping(true)
                    DispatchQueue.main.asyncAfter(deadline: .now() + hold) { NSApp.terminate(nil) }
                } else { NSApp.terminate(nil) }
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
        if probeDirectory == nil {
            let companion = CompanionCoordinator(manager: manager)
            manager.companion = companion
            companion.start()
        }
        if CommandLine.arguments.contains("--show-settings") { status.settingsWindow.show() }
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
    @objc private func openSettings(_ sender: Any?) { status.settingsWindow.show() }
    private func installApplicationMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); let appMenu = NSMenu(title: "Lite2D"); appItem.submenu = appMenu; main.addItem(appItem)
        let settingsItem = NSMenuItem(title: L10n.text("settings.open"), action: #selector(openSettings(_:)), keyEquivalent: ",")
        settingsItem.target = self; appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: L10n.text("app.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        let editItem = NSMenuItem(); let edit = NSMenu(title: L10n.text("menu.edit")); editItem.submenu = edit; main.addItem(editItem)
        for (title, selector, key) in [(L10n.text("action.undo"), Selector(("undo:")), "z"),
                                      (L10n.text("action.cut"), #selector(NSText.cut(_:)), "x"),
                                      (L10n.text("action.copy"), #selector(NSText.copy(_:)), "c"),
                                      (L10n.text("action.paste"), #selector(NSText.paste(_:)), "v"),
                                      (L10n.text("action.select_all"), #selector(NSText.selectAll(_:)), "a")] {
            edit.addItem(NSMenuItem(title: title, action: selector, keyEquivalent: key))
        }
        let windowItem = NSMenuItem(); let window = NSMenu(title: L10n.text("menu.window")); windowItem.submenu = window; main.addItem(windowItem)
        window.addItem(NSMenuItem(title: L10n.text("action.close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        window.addItem(NSMenuItem(title: L10n.text("action.minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        NSApp.mainMenu = main; NSApp.windowsMenu = window
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        status?.settingsWindow.show()
        return true
    }
    func applicationWillTerminate(_ notification: Notification) {
        guard !terminating else { return }; terminating = true
        manager?.shutdown()
        if manager != nil { L2DBridge.stopRuntime() }
        if exitCode != 0 { exit(exitCode) }
    }
}
L10n.configureSystemDialogs()
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
exit(delegate.exitCode)
