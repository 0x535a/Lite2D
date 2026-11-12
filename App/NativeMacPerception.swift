import AppKit
import CoreGraphics
import IOKit.ps
import Network

struct CompanionPerceptionSettings: Codable, Equatable {
    var mode: CompanionProactiveMode = .off
    var workspace = false
    var idle = false
    var power = false
    var network = false
    var calendar = false
    var reminders = false
    var shareActivity = false
    var appOverrides: [String: CompanionActivityCategory] = [:]
    enum CodingKeys: String, CodingKey { case mode, workspace, idle, power, network, calendar, reminders, shareActivity, appOverrides }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = (try? c.decode(CompanionProactiveMode.self, forKey: .mode)) ?? .off
        workspace = (try? c.decode(Bool.self, forKey: .workspace)) ?? false
        idle = (try? c.decode(Bool.self, forKey: .idle)) ?? false
        power = (try? c.decode(Bool.self, forKey: .power)) ?? false
        network = (try? c.decode(Bool.self, forKey: .network)) ?? false
        calendar = (try? c.decode(Bool.self, forKey: .calendar)) ?? false
        reminders = (try? c.decode(Bool.self, forKey: .reminders)) ?? false
        shareActivity = (try? c.decode(Bool.self, forKey: .shareActivity)) ?? false
        appOverrides = (try? c.decode([String: CompanionActivityCategory].self, forKey: .appOverrides)) ?? [:]
    }
    static let sourceNames = ["macos.session", "macos.workspace", "macos.idle", "macos.power", "macos.network", "macos.calendar", "macos.reminders"]
    func enabled(_ source: String) -> Bool {
        guard mode != .off else { return false }
        switch source {
        case "macos.session": return true
        case "macos.workspace": return workspace
        case "macos.idle": return idle
        case "macos.power": return power
        case "macos.network": return network
        case "macos.calendar": return calendar
        case "macos.reminders": return reminders
        default: return false
        }
    }
}

enum CompanionActivityClassifier {
    static func classify(bundleID: String?, overrides: [String: CompanionActivityCategory] = [:]) -> (CompanionActivityCategory, Double) {
        guard let id = bundleID else { return (.unknown, 0) }
        if let category = overrides[id] { return (category, category == .unknown ? 0 : 1) }
        // Application identity is only a coarse signal. Browsers/editors are deliberately broad.
        let mappings: [CompanionActivityCategory: Set<String>] = [
            .programming: ["com.apple.dt.Xcode", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.jetbrains.intellij", "com.jetbrains.pycharm"],
            .browsing: ["com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox", "company.thebrowser.Browser"],
            .writing: ["com.apple.iWork.Pages", "com.microsoft.Word", "abnerworks.Typora", "md.obsidian"],
            .research: ["org.zotero.zotero"],
            .media: ["com.apple.Music", "com.apple.QuickTimePlayerX", "org.videolan.vlc", "com.colliderli.iina", "com.spotify.client"],
            .communication: ["com.apple.mail", "com.apple.MobileSMS", "com.tinyspeck.slackmacgap", "us.zoom.xos", "com.microsoft.teams2"]]
        for (category, ids) in mappings where ids.contains(id) { return (category, 0.75) }
        return (.unknown, 0)
    }
}

struct CompanionMacSignal {
    var source: String
    var type: String
    var category: CompanionActivityCategory?
    var confidence: Double = 1
    var subject: String
    var idleSeconds: Double?
    var sessionAvailable: Bool?
    var sleeping: Bool?
    var initial = false
    var health: String = "available"
    var epoch: Int
}

// All Cocoa callbacks/timers and teardown run on the main actor. The sink only sends bounded typed signals.
@MainActor final class NativeMacPerception {
    private var settings = CompanionPerceptionSettings()
    private var epochs: [String: Int] = [:]
    private var tokens: [NSObjectProtocol] = []
    private var idleTimer: Timer?
    private var powerSource: CFRunLoopSource?
    private var networkMonitor: NWPathMonitor?
    private var generation = 0
    private var asleep = false
    private let sink: (CompanionMacSignal) -> Void
    init(sink: @escaping (CompanionMacSignal) -> Void) { self.sink = sink }

    func configure(_ next: CompanionPerceptionSettings, epochs: [String: Int], suspended: Bool) {
        guard settings != next || self.epochs != epochs || asleep != suspended else { return }
        stop(); self.settings = next; self.epochs = epochs; asleep = suspended
        guard next.mode != .off else { return }
        let center = NSWorkspace.shared.notificationCenter
        let expected = generation
        // These are hard-gate lifecycle signals, never exact lock-screen assertions.
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                Task { @MainActor in guard let self, self.generation == expected else { return }; self.lifecycle(notification.name) }
            })
        }
        if let epoch = epochs["macos.session"] {
            sink(.init(source: "macos.session", type: "session.snapshot", subject: "user_session", sessionAvailable: !suspended && sessionAvailable(), sleeping: suspended, initial: true, epoch: epoch))
        }
        if suspended { return }
        if next.workspace {
            tokens.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in guard let self, self.generation == expected else { return }; self.sampleWorkspace(initial: false) }
            })
            sampleWorkspace(initial: true)
        }
        if next.idle {
            sampleIdle(initial: true)
            idleTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.sampleIdle(initial: false) }
            }
            idleTimer?.tolerance = 2
        }
        if next.network {
            let monitor = NWPathMonitor(), expected = generation
            monitor.pathUpdateHandler = { [weak self] path in
                let subject = path.status == .satisfied ? "path_available" : "path_unavailable"
                Task { @MainActor in
                    guard let self, self.generation == expected, !self.asleep, let epoch = self.epochs["macos.network"] else { return }
                    self.sink(.init(source: "macos.network", type: "network.path_changed", subject: subject, initial: true, epoch: epoch))
                }
            }
            networkMonitor = monitor; monitor.start(queue: .global(qos: .utility))
        }
        if next.power {
            let context = Unmanaged.passUnretained(self).toOpaque()
            powerSource = IOPSNotificationCreateRunLoopSource({ raw in
                guard let raw else { return }
                let sensor = Unmanaged<NativeMacPerception>.fromOpaque(raw).takeUnretainedValue()
                Task { @MainActor in sensor.samplePower(initial: false) }
            }, context)?.takeRetainedValue()
            if let powerSource { CFRunLoopAddSource(CFRunLoopGetMain(), powerSource, .commonModes) }
            for name in [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification] {
                tokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in guard let self, self.generation == expected else { return }; self.samplePower(initial: false) }
                })
            }
            samplePower(initial: true)
        }
    }
    private func lifecycle(_ name: Notification.Name) {
        guard settings.mode != .off else { return }
        let sleep = [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification].contains(name)
        let source = "macos.session"
        guard let epoch = epochs[source] else { return }
        sink(.init(source: source, type: sleep ? "session.suspended" : "session.resumed", subject: "user_session", sessionAvailable: !sleep && sessionAvailable(), sleeping: sleep, epoch: epoch))
        configure(settings, epochs: epochs, suspended: sleep)
    }
    private func sessionAvailable() -> Bool {
        guard let values = CGSessionCopyCurrentDictionary() as? [String: Any],
              values[kCGSessionOnConsoleKey as String] as? Bool == true,
              values[kCGSessionLoginDoneKey as String] as? Bool == true else { return false }
        return true // On-console is a weak visibility signal, never a claim that the screen is unlocked.
    }
    private func sampleWorkspace(initial: Bool) {
        guard !asleep, settings.workspace, let epoch = epochs["macos.workspace"] else { return }
        let category = CompanionActivityClassifier.classify(bundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier, overrides: settings.appOverrides)
        sink(.init(source: "macos.workspace", type: "activity.category_changed", category: category.0, confidence: category.1, subject: "foreground_activity", sessionAvailable: sessionAvailable(), initial: initial, epoch: epoch))
    }
    private func sampleIdle(initial: Bool) {
        guard !asleep, settings.idle, let epoch = epochs["macos.idle"] else { return }
        let seconds = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!)
        guard seconds.isFinite && seconds >= 0 else { return }
        if seconds < 120, settings.workspace { sampleWorkspace(initial: true) }
        sink(.init(source: "macos.idle", type: "activity.idle_changed", category: seconds >= 120 ? .idle : nil, subject: seconds >= 120 ? "idle" : "active", idleSeconds: seconds, sessionAvailable: sessionAvailable(), initial: initial, epoch: epoch))
    }
    private func samplePower(initial: Bool) {
        guard !asleep, settings.power, let epoch = epochs["macos.power"] else { return }
        let process = ProcessInfo.processInfo
        let severe = process.thermalState == .serious || process.thermalState == .critical
        let state = severe ? "thermal_pressure" : (process.isLowPowerModeEnabled ? "low_power" : "normal")
        sink(.init(source: "macos.power", type: "environment.power_changed", subject: state, initial: initial, epoch: epoch))
    }
    func stop() {
        generation += 1
        epochs = [:]
        let workspace = NSWorkspace.shared.notificationCenter
        for token in tokens { workspace.removeObserver(token); NotificationCenter.default.removeObserver(token) }
        tokens.removeAll(); idleTimer?.invalidate(); idleTimer = nil
        networkMonitor?.cancel(); networkMonitor = nil
        if let powerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .commonModes); CFRunLoopSourceInvalidate(powerSource) }
        powerSource = nil
    }
}
