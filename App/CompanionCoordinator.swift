import AppKit
import Combine
import UniformTypeIdentifiers

struct CompanionSourceSettings: Codable, Equatable {
    var enabled = false
    enum CodingKeys: String, CodingKey { case enabled }
    init(enabled: Bool = false) { self.enabled = enabled }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
    }
}
struct CompanionCharacterSettings: Codable, Equatable {
    var enabled = false
    var gaze = true
    var reactionMotionGroup: String?
    var bubbleOffset: BubbleOffset?
    enum CodingKeys: String, CodingKey { case enabled, gaze, reactionMotionGroup, bubbleOffset }
    init(enabled: Bool = false, gaze: Bool = true, reactionMotionGroup: String? = nil, bubbleOffset: BubbleOffset? = nil) {
        self.enabled = enabled; self.gaze = gaze; self.reactionMotionGroup = reactionMotionGroup; self.bubbleOffset = bubbleOffset
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
        gaze = (try? c.decodeIfPresent(Bool.self, forKey: .gaze)) ?? true
        reactionMotionGroup = try? c.decodeIfPresent(String.self, forKey: .reactionMotionGroup)
        bubbleOffset = try? c.decodeIfPresent(BubbleOffset.self, forKey: .bubbleOffset)
    }
}
struct BubbleOffset: Codable, Equatable {
    var x: Double = 0
    var y: Double = 0
}
struct CompanionSettings: Codable {
    var enabled = false
    var paused = false
    var intervalMinutes = 30
    var hourlyRequests = 12
    var model = ""
    var nodePath = ""
    var opencodePath = ""
    var codexPath = ""
    var sources: [String: CompanionSourceSettings] = ["opencode": .init(), "codex": .init(), "claude": .init()]
    var characters: [String: CompanionCharacterSettings] = [:]
    enum CodingKeys: String, CodingKey {
        case enabled, paused, intervalMinutes, hourlyRequests, model, nodePath, opencodePath, codexPath, sources, characters
    }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
        paused = (try? c.decodeIfPresent(Bool.self, forKey: .paused)) ?? false
        intervalMinutes = (try? c.decodeIfPresent(Int.self, forKey: .intervalMinutes)) ?? 30
        hourlyRequests = (try? c.decodeIfPresent(Int.self, forKey: .hourlyRequests)) ?? 12
        model = (try? c.decodeIfPresent(String.self, forKey: .model)) ?? ""
        nodePath = (try? c.decodeIfPresent(String.self, forKey: .nodePath)) ?? ""
        opencodePath = (try? c.decodeIfPresent(String.self, forKey: .opencodePath)) ?? ""
        codexPath = (try? c.decodeIfPresent(String.self, forKey: .codexPath)) ?? ""
        sources = (try? c.decodeIfPresent([String: CompanionSourceSettings].self, forKey: .sources)) ?? [:]
        for backend in ["opencode", "codex", "claude"] where sources[backend] == nil { sources[backend] = .init() }
        characters = (try? c.decodeIfPresent([String: CompanionCharacterSettings].self, forKey: .characters)) ?? [:]
    }
}
struct CompanionEntry: Identifiable {
    let id: Int
    let at: String
    let characterId: String?
    let text: String
    let type: String
    let name: String?
}

final class CompanionCoordinator: ObservableObject {
    weak var manager: ModelInstanceManager?
    let root: URL
    @Published var settings = CompanionSettings()
    @Published var runtimeState = "stopped"
    @Published var error: String?
    @Published var sources: [String: [String: Any]] = [:]
    @Published var entries: [CompanionEntry] = []
    @Published var busy = false
    @Published var roleErrors: [String: String] = [:]
    @Published var records: [[String: String]] = []
    @Published var memoryContents: [String: String] = [:]
    private var runtime: NativeCompanionRuntime?
    private var closingRuntime: Task<Void, Never>?
    private var runtimeGeneration = UUID()
    private var timer: Timer?
    private var lastSync = ""
    private var gaze: (a: UUID, b: UUID, until: Date, topic: String)?
    private var bubbles: [UUID: CompanionBubble] = [:]
    private var bubblePreview: CompanionBubble?
    private var bubblePreviewID: UUID?
    @Published private(set) var bubbleEditingID: UUID?
    private var pending: [[String: Any]] = []
    private var bubbleUntil = Date.distantPast
    private var bubbleTopic: String?
    private var cancelledTopics = Set<String>()
    private var expressionOverrides = Set<UUID>()
    private var historyWindow: NSWindow?
    private var historyCloseObserver: NSObjectProtocol?
    private var shutdownRequested = false
    private var previouslySleeping = false

    init(manager: ModelInstanceManager) {
        self.manager = manager
        root = ProcessInfo.processInfo.environment["LITE2D_COMPANION_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? manager.store.url.deletingLastPathComponent().appendingPathComponent("Companion", isDirectory: true)
        do {
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("settings.json").path) {
                settings = try JSONDecoder().decode(CompanionSettings.self, from: Data(contentsOf: root.appendingPathComponent("settings.json")))
            }
        } catch { self.error = error.localizedDescription }
    }
    func start() {
        shutdownRequested = false
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        reconcile()
    }
    func character(_ id: UUID) -> CompanionCharacterSettings { settings.characters[id.uuidString] ?? .init() }
    func updateCharacter(_ id: UUID, _ edit: (inout CompanionCharacterSettings) -> Void) {
        var value = character(id); edit(&value); settings.characters[id.uuidString] = value; changed()
    }
    func changed() {
        settings.intervalMinutes = min(max(settings.intervalMinutes, 0), 1440)
        settings.hourlyRequests = min(max(settings.hourlyRequests, 1), 120)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(settings).write(to: root.appendingPathComponent("settings.json"), options: .atomic)
        } catch { self.error = error.localizedDescription }
        objectWillChange.send(); reconcile(); sync()
    }
    func personaURL(_ id: UUID) -> URL { root.appendingPathComponent("characters/\(id.uuidString)/persona.md") }
    func hasPersona(_ id: UUID) -> Bool { FileManager.default.fileExists(atPath: personaURL(id).path) }
    func importPersona(_ id: UUID) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText, .plainText]
        panel.message = L10n.text("companion.persona_help")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try installPersona(from: url, for: id) }
        catch { self.error = L10n.error(error) }
    }
    func installPersona(from url: URL, for id: UUID) throws {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= 65536 else { throw LocalizedFailure(message: .key("companion.invalid_persona", [])) }
        let data = try Data(contentsOf: url)
        guard data.count <= 65536, let text = String(data: data, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalizedFailure(message: .key("companion.invalid_persona", []))
        }
        let target = personaURL(id)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: target, options: .atomic)
        // A pack may optionally contain examples. Import only this Persona's speaker;
        // Markdown remains the only required input. Never run pack scripts.
        let corpus = url.deletingLastPathComponent().appendingPathComponent("original_style_corpus.jsonl")
        let examplesURL = target.deletingLastPathComponent().appendingPathComponent("style_examples.jsonl")
        try? FileManager.default.removeItem(at: examplesURL)
        let header = text.components(separatedBy: "\n").prefix(20).joined(separator: "\n")
        if let match = header.range(of: #"(?m)^character_id:\s*bili(22|33)\s*$"#, options: .regularExpression),
           let size = try? corpus.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1024 * 1024,
           let corpusData = try? Data(contentsOf: corpus), corpusData.count <= 1024 * 1024 {
            let speaker = String(header[match]).contains("bili22") ? "22" : "33"
            let selected = String(decoding: corpusData, as: UTF8.self).components(separatedBy: "\n").filter { line in
                guard let bytes = line.data(using: .utf8), let item = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return false }
                return item["speaker"] as? String == speaker && item["source_type"] as? String == "original_style_example" && item["is_official_quote"] as? Bool == false
            }
            try selected.joined(separator: "\n").write(to: examplesURL, atomically: true, encoding: .utf8)
        }
        error = nil; changed()
    }
    func editPersona(_ id: UUID) { if hasPersona(id) { NSWorkspace.shared.open(personaURL(id)) } }
    func executable(_ name: String, override: String = "") -> String? {
        if !override.isEmpty { return FileManager.default.isExecutableFile(atPath: override) ? override : nil }
        let home = FileManager.default.homeDirectoryForCurrentUser
        var directories = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        directories += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        let nvm = home.appendingPathComponent(".nvm/versions/node")
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: nvm.path)) ?? []
        directories += versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }.map { nvm.appendingPathComponent("\($0)/bin").path }
        return directories.map { ($0 as NSString).appendingPathComponent(name) }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    private func reconcile(readOnly: Bool = false) {
        guard !shutdownRequested else { return }
        guard settings.enabled || readOnly else { stopProcess(); return }
        guard runtime == nil, let resources = Bundle.main.resourceURL, let executable = Bundle.main.executableURL else { return }
        let prompt = resources.appendingPathComponent("Companion/prompt.json")
        guard FileManager.default.fileExists(atPath: prompt.path) else { runtimeState = "unavailable"; error = L10n.text("companion.runtime_missing"); return }
        let generation = UUID(); runtimeGeneration = generation
        let next = NativeCompanionRuntime(root: root, promptFile: prompt,
            opencode: self.executable("opencode", override: settings.opencodePath) ?? "/nonexistent/opencode",
            codex: self.executable("codex", override: settings.codexPath) ?? "/nonexistent/codex",
            node: self.executable("node", override: settings.nodePath) ?? "/nonexistent/node",
            helperScript: resources.appendingPathComponent("Companion/claude-helper.mjs"), executable: executable.path) { [weak self] event in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.runtimeGeneration == generation else { return }
                    self.receive(event)
                }
            }
        runtime = next; runtimeState = "starting"; lastSync = ""
        let previous = closingRuntime
        Task { [weak self] in
            await previous?.value
            do { try await next.start() }
            catch { await MainActor.run { [weak self] in
                guard let self, self.runtimeGeneration == generation else { return }
                self.runtimeState = "unavailable"; self.error = error.localizedDescription
            } }
        }
    }
    func send(_ command: [String: Any]) {
        guard let runtime else { return }
        Task { await runtime.command(command) }
    }
    func receive(_ event: [String: Any]) {
        guard let type = event["type"] as? String else { return }
        if type == "ready" { runtimeState = settings.enabled ? "running" : "stopped"; error = nil; loadHistory(event); sync(force: true) }
        if type == "status" {
            sources = event["sources"] as? [String: [String: Any]] ?? [:]; busy = event["busy"] as? Bool ?? false
            roleErrors = event["roleErrors"] as? [String: String] ?? [:]
        }
        if type == "topic.start" { busy = true }
        if type == "history" { loadHistory(event) }
        if type == "records" { records = event["records"] as? [[String: String]] ?? [] }
        if type == "memory", let id = event["characterId"] as? String, let content = event["content"] as? String { memoryContents[id] = content }
        if type == "error" {
            error = event["message"] as? String; append(event)
            if event["requestType"] as? String == "trigger" { busy = false }
        }
        if type == "test.result", event["result"] as? String == "skipped" { error = L10n.text("companion.test_skipped") }
        if type == "utterance" {
            append(event)
            if let topic = event["topicId"] as? String, cancelledTopics.contains(topic) { return }
            pending.append(event); presentNext()
        }
        if type == "conversation.focus", let a = (event["speakerId"] as? String).flatMap(UUID.init(uuidString:)),
           let b = (event["listenerId"] as? String).flatMap(UUID.init(uuidString:)),
           let until = (event["validUntil"] as? String).flatMap({ ISO8601DateFormatter().date(from: $0) }), let topic = event["topicId"] as? String,
           !cancelledTopics.contains(topic) {
            gaze = (a, b, until, topic)
        }
        if type == "topic.end" {
            busy = false
            if event["reason"] as? String != "completed", let topic = event["topicId"] as? String {
                cancelledTopics.insert(topic); if gaze?.topic == topic { clearGaze() }
                pending.removeAll { $0["topicId"] as? String == topic }
                if bubbleTopic == topic { for bubble in bubbles.values { bubble.hide() }; bubbleUntil = .distantPast }
            } else if pending.isEmpty && Date() >= bubbleUntil { clearGaze() }
        }
    }
    private func append(_ event: [String: Any]) {
        guard let text = event["text"] as? String ?? event["message"] as? String, let seq = event["sequence"] as? Int else { return }
        guard !entries.contains(where: { $0.id == seq }) else { return }
        entries.append(.init(id: seq, at: event["createdAt"] as? String ?? "", characterId: event["characterId"] as? String, text: text, type: event["type"] as? String ?? "", name: event["name"] as? String))
        if entries.count > 400 { entries.removeFirst(entries.count - 400) }
    }
    private func loadHistory(_ event: [String: Any]) {
        entries = []; for item in event["history"] as? [[String: Any]] ?? [] { append(item) }
    }
    func sync(force: Bool = false) {
        guard let manager else { return }
        let characters: [[String: Any]] = manager.records.map { record in
            let config = character(record.settings.id)
            return ["id": record.settings.id.uuidString, "name": record.settings.localizedDisplayName,
                    "enabled": config.enabled && hasPersona(record.settings.id), "gaze": config.gaze,
                    "visible": record.settings.isVisible && !manager.allHidden && !manager.sleeping && manager.isDisplayConnected(record) && record.error == nil]
        }
        let value: [String: Any] = ["enabled": settings.enabled, "paused": settings.paused || manager.sleeping,
            "intervalMinutes": settings.intervalMinutes, "hourlyRequests": settings.hourlyRequests, "model": settings.model,
            "sources": settings.sources.mapValues { ["enabled": $0.enabled] as [String: Any] }, "characters": characters]
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: .sortedKeys), let encoded = String(data: data, encoding: .utf8) else { return }
        if force || encoded != lastSync { lastSync = encoded; send(["type": "configure", "config": value]) }
    }
    func tick() {
        let sleeping = manager?.sleeping == true
        if previouslySleeping && !sleeping, let runtime { Task { await runtime.reconcileAfterWake() } }
        previouslySleeping = sleeping
        sync(); updateGaze()
        for (id, bubble) in bubbles {
            if let record = manager?.record(id), let window = record.controller?.window, visible(record) { bubble.position(near: window) }
            else { bubble.hide() }
        }
        if let id = bubblePreviewID, let preview = bubblePreview {
            if let record = manager?.record(id), let window = record.controller?.window { preview.position(near: window) }
            else { preview.hide() }
        }
        if Date() >= bubbleUntil {
            for bubble in bubbles.values { bubble.hide() }
            restoreExpressions()
            presentNext()
            if pending.isEmpty && !busy { clearGaze() }
        }
        if settings.paused || manager?.sleeping == true || manager?.allHidden == true { cancelPresentation() }
    }
    private func visible(_ record: ModelRecord) -> Bool {
        record.settings.isVisible && manager?.allHidden == false && manager?.sleeping == false && manager?.isDisplayConnected(record) == true && record.controller?.window.isVisible == true
    }
    private func presentNext() {
        guard Date() >= bubbleUntil, !settings.paused else { return }
        while !pending.isEmpty {
            let event = pending.removeFirst()
            guard let id = (event["characterId"] as? String).flatMap(UUID.init(uuidString:)), let text = event["text"] as? String,
                  let record = manager?.record(id), let window = record.controller?.window, visible(record) else { continue }
            let bubble = bubbles[id] ?? CompanionBubble(); bubbles[id] = bubble
            bubble.offset = bubblePoint(character(id).bubbleOffset)
            bubble.show(name: record.settings.localizedDisplayName, text: text, near: window)
            if !record.settings.animationPaused && record.settings.interactionMode != .edit,
               let group = character(id).reactionMotionGroup, let view = record.controller?.view,
               !view.bridge.interactionPlaying, Date() >= view.manualMotionUntil,
               (view.bridge.motionGroups[group]?.intValue ?? 0) > 0 {
                view.openGLContext?.makeCurrentContext(); _ = view.bridge.playInteraction(group)
            }
            if !record.settings.animationPaused && record.settings.interactionMode != .edit,
               let view = record.controller?.view, let emotion = event["emotion"] as? String, emotion != "neutral" {
                let names = view.bridge.expressionNames
                if let expression = names.first(where: { $0.lowercased() == emotion || $0.lowercased().contains(emotion) }) {
                    view.openGLContext?.makeCurrentContext()
                    if view.bridge.selectExpression(expression) { expressionOverrides.insert(id) }
                }
            }
            bubbleUntil = Date().addingTimeInterval(min(max(Double(text.count) / 12, 4), 15)); bubbleTopic = event["topicId"] as? String
            break
        }
    }
    private func updateGaze() {
        guard let gaze, gaze.until > Date(), !settings.paused,
              let a = manager?.record(gaze.a), let b = manager?.record(gaze.b), visible(a), visible(b) else { clearGaze(); return }
        for (record, target) in [(a, b), (b, a)] {
            guard let view = record.controller?.view, let targetWindow = target.controller?.window else { continue }
            let allowed = character(record.settings.id).gaze && !record.settings.animationPaused && record.settings.interactionMode != .edit && Date() >= view.manualMotionUntil
            view.companionLookTarget = allowed ? NSPoint(x: targetWindow.frame.midX, y: targetWindow.frame.minY + targetWindow.frame.height * 0.7) : nil
        }
    }
    private func clearGaze() { gaze = nil; for record in manager?.records ?? [] { record.controller?.view.companionLookTarget = nil } }
    private func restoreExpressions() {
        for id in expressionOverrides {
            guard let record = manager?.record(id), let view = record.controller?.view else { continue }
            view.openGLContext?.makeCurrentContext(); _ = view.bridge.selectExpression(record.settings.expressionId ?? "")
        }
        expressionOverrides.removeAll()
    }
    private func cancelPresentation() { pending.removeAll(); for bubble in bubbles.values { bubble.hide() }; restoreExpressions(); bubbleUntil = .distantPast; clearGaze() }
    func stopTopic() { send(["type": "stop"]); cancelPresentation() }
    func canPlaceBubble(_ id: UUID) -> Bool {
        guard let record = manager?.record(id), record.error == nil, record.controller != nil,
              manager?.isDisplayConnected(record) == true else { return false }
        return true
    }
    private func bubblePoint(_ offset: BubbleOffset?) -> NSPoint {
        NSPoint(x: offset?.x ?? 0, y: offset?.y ?? 0)
    }
    func beginBubblePlacement(_ id: UUID) {
        if let current = bubbleEditingID, current != id { finishBubblePlacement(current, save: true) }
        guard bubbleEditingID == nil, canPlaceBubble(id), let record = manager?.record(id), let window = record.controller?.window else { return }
        let preview = CompanionBubble(preview: true)
        preview.offset = bubblePoint(character(id).bubbleOffset)
        preview.show(name: record.settings.localizedDisplayName, text: L10n.text("companion.bubble_preview"), near: window)
        preview.onMoved = { [weak self, weak preview, weak window] in
            guard let self, let preview, let window else { return }
            self.syncPreviewOffset(preview, near: window)
        }
        preview.panel.makeKeyAndOrderFront(nil)
        bubblePreview = preview; bubblePreviewID = id; bubbleEditingID = id
        objectWillChange.send()
    }
    func finishBubblePlacement(_ id: UUID, save: Bool) {
        guard bubblePreviewID == id, let preview = bubblePreview, let window = manager?.record(id)?.controller?.window else { return }
        if save, let base = preview.baseOrigin(near: window), let screen = window.screen {
            let area = screen.visibleFrame, size = preview.panel.frame.size
            let x = min(max(preview.panel.frame.minX, area.minX + 8), area.maxX - size.width - 8)
            let y = min(max(preview.panel.frame.minY, area.minY + 8), area.maxY - size.height - 8)
            updateCharacter(id) { $0.bubbleOffset = BubbleOffset(x: x - base.x, y: y - base.y) }
        }
        preview.hide(); bubblePreview = nil; bubblePreviewID = nil; bubbleEditingID = nil
        bubbles[id]?.offset = bubblePoint(character(id).bubbleOffset)
        objectWillChange.send()
    }
    func resetBubblePlacement(_ id: UUID) {
        if bubbleEditingID == id { finishBubblePlacement(id, save: false) }
        updateCharacter(id) { $0.bubbleOffset = nil }
        bubbles[id]?.offset = .zero
    }
    var bubblePreviewFrame: NSRect? { bubblePreview?.panel.frame }
    var bubblePreviewWindow: NSWindow? { bubblePreview?.panel }
    var bubblePreviewIsInteractive: Bool { bubblePreview?.panel.ignoresMouseEvents == false }
    func moveBubblePreview(by delta: NSPoint) {
        guard let preview = bubblePreview else { return }
        preview.panel.setFrameOrigin(NSPoint(x: preview.panel.frame.minX + delta.x, y: preview.panel.frame.minY + delta.y))
        if let id = bubblePreviewID, let window = manager?.record(id)?.controller?.window { syncPreviewOffset(preview, near: window) }
    }
    private func syncPreviewOffset(_ preview: CompanionBubble, near window: NSWindow) {
        guard let base = preview.baseOrigin(near: window) else { return }
        preview.offset = NSPoint(x: preview.panel.frame.minX - base.x, y: preview.panel.frame.minY - base.y)
    }
    func canTrigger(_ id: UUID) -> Bool {
        guard settings.enabled, !settings.paused, runtimeState == "running", !busy,
              character(id).enabled, hasPersona(id), let record = manager?.record(id) else { return false }
        return visible(record)
    }
    func trigger(_ id: UUID) {
        guard canTrigger(id) else { return }
        error = nil; busy = true
        sync(force: true); send(["type": "trigger", "characterId": id.uuidString])
    }
    func retry() { stopProcess(); if settings.enabled { reconcile() } }
    func showHistory() {
        if runtime == nil { reconcile(readOnly: true) }
        send(["type": "history"])
        if historyWindow == nil {
            historyWindow = CompanionHistoryView.makeWindow(coordinator: self)
            historyCloseObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: historyWindow, queue: .main) { [weak self] _ in
                guard let self else { return }
                if !self.settings.enabled { self.stopProcess() }
            }
        }
        NSApp.activate(ignoringOtherApps: true); historyWindow?.makeKeyAndOrderFront(nil)
    }
    func exportMemory(_ id: UUID) { send(["type": "memory", "characterId": id.uuidString]) }
    private func stopProcess() {
        cancelPresentation(); runtimeGeneration = UUID()
        if let old = runtime {
            runtime = nil
            let previous = closingRuntime
            closingRuntime = Task { await previous?.value; await old.close() }
        }
        runtimeState = "stopped"; busy = false; sources = [:]
    }
    func shutdown() {
        shutdownRequested = true; timer?.invalidate(); timer = nil; stopProcess()
        if let historyCloseObserver { NotificationCenter.default.removeObserver(historyCloseObserver) }
        historyCloseObserver = nil; historyWindow?.close(); historyWindow = nil
    }
}

final class CompanionBubble {
    let panel: NSPanel
    var offset = NSPoint.zero
    var onMoved: (() -> Void)?
    init(preview: Bool = false) {
        panel = preview ? BubblePreviewPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            : NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .floating; panel.ignoresMouseEvents = !preview; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }
    func show(name: String, text: String, near window: NSWindow) {
        let drag = BubbleDragView(); drag.onMoved = { [weak self] in self?.onMoved?() }
        let effect: NSVisualEffectView = panel is BubblePreviewPanel ? drag : NSVisualEffectView()
        effect.material = .popover; effect.blendingMode = .behindWindow; effect.state = .active
        effect.wantsLayer = true; effect.layer?.cornerRadius = 12; effect.layer?.masksToBounds = true
        let title = NSTextField(labelWithString: name); title.font = .systemFont(ofSize: 11, weight: .semibold); title.textColor = .secondaryLabelColor
        let label = NSTextField(wrappingLabelWithString: text); label.font = .systemFont(ofSize: 14); label.maximumNumberOfLines = 12
        let stack = NSStackView(views: [title, label]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 5
        effect.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 14), stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -14), stack.topAnchor.constraint(equalTo: effect.topAnchor, constant: 12), stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -12)])
        panel.contentView = effect
        let rect = (text as NSString).boundingRect(with: NSSize(width: 272, height: 1000), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: NSFont.systemFont(ofSize: 14)])
        panel.setContentSize(NSSize(width: 300, height: min(max(ceil(rect.height) + 48, 78), 300)))
        position(near: window); panel.orderFrontRegardless()
    }
    func position(near window: NSWindow) {
        guard let screen = window.screen else { hide(); return }
        guard let base = baseOrigin(near: window) else { hide(); return }
        let area = screen.visibleFrame, size = panel.frame.size
        let x = min(max(base.x + offset.x, area.minX + 8), area.maxX - size.width - 8)
        let preferredY = base.y + offset.y
        let y = min(max(preferredY, area.minY + 8), area.maxY - size.height - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
    func baseOrigin(near window: NSWindow) -> NSPoint? {
        guard window.screen != nil else { return nil }
        let size = panel.frame.size
        return NSPoint(x: window.frame.midX - size.width / 2, y: window.frame.maxY + 8)
    }
    func hide() { panel.orderOut(nil) }
}

private final class BubblePreviewPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
private final class BubbleDragView: NSVisualEffectView {
    private var startMouse: NSPoint?
    private var startOrigin: NSPoint?
    var onMoved: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseDown(with event: NSEvent) {
        startMouse = NSEvent.mouseLocation; startOrigin = window?.frame.origin
        NSCursor.closedHand.set()
    }
    override func mouseDragged(with event: NSEvent) {
        guard let startMouse, let startOrigin else { return }
        let point = NSEvent.mouseLocation
        window?.setFrameOrigin(NSPoint(x: startOrigin.x + point.x - startMouse.x, y: startOrigin.y + point.y - startMouse.y))
        onMoved?()
    }
    override func mouseUp(with event: NSEvent) {
        startMouse = nil; startOrigin = nil; NSCursor.openHand.set()
    }
}
