import AppKit
import ApplicationServices

struct CompanionWindowResult {
    var category: CompanionActivityCategory
    var confidence: Double
    var health = "available"
}
enum CompanionWindowClassifier {
    static func sensitiveApp(_ bundle: String) -> Bool {
        ["password", "keychain", "authenticator", "bank", "mobilesms", "xinwechat", "telegram", "whatsapp", "signal"].contains { bundle.lowercased().contains($0) }
    }
    static func classify(_ title: String) -> CompanionWindowResult {
        guard title.utf8.count <= 4096 else { return .init(category: .unknown, confidence: 0) }
        let value = title.lowercased()
        if ["验证码", "密码", "verification code", "password", "bank account", "银行卡"].contains(where: value.contains) { return .init(category: .unknown, confidence: 0) }
        let rules: [(CompanionActivityCategory, [String])] = [
            (.media, ["youtube", "哔哩哔哩", "bilibili", "netflix", "disney+", "spotify"]),
            (.writing, ["overleaf", "manuscript", "latex", ".tex", "撰写论文"]),
            (.experiment, ["jupyter", ".ipynb", "实验记录"]),
            (.research, ["arxiv", "pubmed", "semantic scholar", "google scholar"])]
        for (category, words) in rules where words.contains(where: value.contains) { return .init(category: category, confidence: 0.75) }
        if value.range(of: #"\.(swift|rs|py|cpp|tsx?|jsx?|kt|java)\b"#, options: .regularExpression) != nil { return .init(category: .programming, confidence: 0.75) }
        return .init(category: .unknown, confidence: 0)
    }
    static func read(pid: pid_t) -> CompanionWindowResult {
        autoreleasepool {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.2)
            var windowValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &windowValue) == .success,
                  let windowValue, CFGetTypeID(windowValue) == AXUIElementGetTypeID() else { return .init(category: .unknown, confidence: 0, health: "temporarily_unavailable") }
            let window = unsafeBitCast(windowValue, to: AXUIElement.self)
            AXUIElementSetMessagingTimeout(window, 0.2)
            var titleValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue) == .success, let title = titleValue as? String else { return .init(category: .unknown, confidence: 0) }
            // No title string, selected text, AXValue, URL or document path escapes this function.
            return classify(title)
        }
    }
}

@MainActor final class NativeWindowPerception {
    private final class Context {
        weak var owner: NativeWindowPerception?
        let generation: Int
        init(_ owner: NativeWindowPerception, generation: Int) { self.owner = owner; self.generation = generation }
    }
    private let sink: (CompanionMacSignal) -> Void
    private var epoch: Int?
    private var apps: Set<String> = []
    private var generation = 0
    private var workspaceObserver: NSObjectProtocol?
    private var observer: AXObserver?
    private var observerContext: Context?
    private var observedPID: pid_t = 0
    private var timer: Timer?
    private var query: Task<Void, Never>?
    private var queryNonce = UUID()
    private var reading = false
    private var pendingRefresh = false
    init(sink: @escaping (CompanionMacSignal) -> Void) { self.sink = sink }
    static var hasAccess: Bool { AXIsProcessTrusted() }
    static func requestAccess() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }
    func configure(epoch: Int?, apps: [String], sleeping: Bool) {
        let desired = sleeping ? nil : epoch, selected = Set(apps)
        guard self.epoch != desired || self.apps != selected else { return }
        stop(); self.epoch = desired; self.apps = selected
        guard desired != nil else { return }
        let expected = generation
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in guard let self, self.generation == expected else { return }; self.refresh() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        timer?.tolerance = 3
        refresh()
    }
    private func clearObserver() {
        if let observer { let source = AXObserverGetRunLoopSource(observer); CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes); CFRunLoopSourceInvalidate(source) }
        observer = nil; observerContext = nil; observedPID = 0
    }
    private func observe(pid: pid_t) {
        guard observedPID != pid else { return }
        clearObserver()
        var value: AXObserver?
        let callback: AXObserverCallback = { _, _, _, raw in
            guard let raw else { return }
            let context = Unmanaged<Context>.fromOpaque(raw).takeUnretainedValue()
            Task { @MainActor in guard let owner = context.owner, owner.generation == context.generation else { return }; owner.refresh() }
        }
        guard AXObserverCreate(pid, callback, &value) == .success, let value else { return }
        let context = Context(self, generation: generation), app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        guard AXObserverAddNotification(value, app, kAXFocusedWindowChangedNotification as CFString, Unmanaged.passUnretained(context).toOpaque()) == .success else { return }
        observer = value; observerContext = context; observedPID = pid
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(value), .commonModes)
    }
    private func refresh() {
        guard let epoch else { return }
        if reading { pendingRefresh = true; return }
        guard !apps.isEmpty, apps.count <= 16 else { sink(.init(source: "macos.window", type: "activity.window_category", category: .unknown, confidence: 0, subject: "no_allowed_window", health: "needs_allowlist", epoch: epoch)); return }
        guard let app = NSWorkspace.shared.frontmostApplication, let bundle = app.bundleIdentifier, apps.contains(bundle), !CompanionWindowClassifier.sensitiveApp(bundle) else {
            clearObserver(); query?.cancel(); queryNonce = UUID()
            sink(.init(source: "macos.window", type: "activity.window_category", category: .unknown, confidence: 0, subject: "no_allowed_window", epoch: epoch)); return
        }
        guard Self.hasAccess else {
            clearObserver(); sink(.init(source: "macos.window", type: "activity.window_category", category: .unknown, confidence: 0, subject: "window_access_denied", health: "permission_denied", epoch: epoch)); return
        }
        let pid = app.processIdentifier, expected = generation, nonce = UUID()
        let scope = NativeCompanionData.hash(bundle + ":" + String(pid))
        observe(pid: pid); query?.cancel(); queryNonce = nonce; reading = true
        query = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { CompanionWindowClassifier.read(pid: pid) }.value
            guard let self, expected == self.generation else { return }
            self.reading = false
            if self.pendingRefresh { self.pendingRefresh = false; self.refresh(); return }
            guard !Task.isCancelled, nonce == self.queryNonce, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
            self.sink(.init(source: "macos.window", type: "activity.window_category", category: result.category, confidence: result.confidence,
                subject: "authorized_window_activity", health: result.health, epoch: epoch, contextScope: scope))
        }
    }
    func stop() {
        generation += 1; epoch = nil; query?.cancel(); query = nil; queryNonce = UUID(); reading = false; pendingRefresh = false
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }; workspaceObserver = nil
        timer?.invalidate(); timer = nil; clearObserver()
    }
}
