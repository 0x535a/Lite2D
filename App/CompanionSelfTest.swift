import AppKit
import SwiftUI

// Exercises our own view hierarchy and rendering inputs. No accessibility,
// desktop capture, keyboard/mouse automation, or external-app control.
final class CompanionSelfTest {
    let manager: ModelInstanceManager
    let status: StatusBarController
    let output: URL
    let complete: (Int32) -> Void
    var checks: [String] = []
    init(manager: ModelInstanceManager, status: StatusBarController, output: URL, complete: @escaping (Int32) -> Void) {
        self.manager = manager; self.status = status; self.output = output; self.complete = complete
    }
    func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw NSError(domain: "CompanionSelfTest", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        checks.append(message)
    }
    func capture(_ window: NSWindow, _ name: String) throws {
        if ProcessInfo.processInfo.environment["LITE2D_CAPTURE_OWN_WINDOW"] == "1" {
            let child = Process(); child.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            child.arguments = ["-x", "-o", "-l", String(window.windowNumber), output.appendingPathComponent(name + ".png").path]
            try child.run(); child.waitUntilExit()
            if child.terminationStatus == 0 { return }
        }
        guard let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw NSError(domain: "capture", code: 1) }
        view.layoutSubtreeIfNeeded(); view.cacheDisplay(in: view.bounds, to: bitmap)
        // Cached SwiftUI layers can retain transparency; composite our own view
        // over the window color so the artifact represents the actual appearance.
        let canvas = NSImage(size: view.bounds.size)
        canvas.lockFocus()
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            NSBezierPath.fill(NSRect(origin: .zero, size: view.bounds.size))
            bitmap.draw(in: NSRect(origin: .zero, size: view.bounds.size))
        }
        canvas.unlockFocus()
        guard let tiff = canvas.tiffRepresentation, let flat = NSBitmapImageRep(data: tiff),
              let data = flat.representation(using: .png, properties: [:]) else { throw NSError(domain: "capture", code: 2) }
        try data.write(to: output.appendingPathComponent(name + ".png"))
    }
    @MainActor private func verifyMonitorGeometry(_ window: NSWindow, model: CompanionMonitorController, name: String, browser: Bool, rowsExpected: Bool = false) async throws {
        for _ in 0..<100 {
            window.contentView?.layoutSubtreeIfNeeded()
            if let content = model.layoutFrames["content"], content.width > 0,
               (!browser || abs(content.height - window.contentLayoutRect.height) < 3), model.layoutFrames["header"] != nil,
               !browser || model.layoutFrames["split"] != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let frames = model.layoutFrames
        var rawFrames = frames.mapValues { ["x": $0.minX, "y": $0.minY, "width": $0.width, "height": $0.height] }
        if let view = window.contentView { rawFrames["host_bounds"] = ["width": view.bounds.width, "height": view.bounds.height, "safe_top": view.safeAreaInsets.top, "safe_bottom": view.safeAreaInsets.bottom, "layout_height": window.contentLayoutRect.height] }
        try JSONSerialization.data(withJSONObject: rawFrames, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("layout-raw-" + name + ".json"))
        guard let content = frames["content"], let header = frames["header"] else { throw NSError(domain: "MonitorGeometry", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing measured layout for \(name)"]) }
        let contentTop = window.frame.height - window.contentLayoutRect.maxY
        try check(abs(header.minY - contentTop) <= 3 && header.height < 115, "\(name): header is pinned immediately below the actual window chrome")
        let availableHeight = window.contentLayoutRect.height
        if browser {
            try check(abs(content.height - availableHeight) < 3, "\(name): browser fills the available window content height")
        } else if let root = window.contentView {
            // Native Form owns an NSScrollView that may extend past SwiftUI's
            // ideal-size preference. Measure its real AppKit viewport instead.
            func scrolls(_ view: NSView) -> [NSScrollView] { (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrolls) }
            let rects = scrolls(root).map { $0.convert($0.bounds, to: root) }.filter { $0.width > root.bounds.width * 0.5 }
            let fullHeight = rects.contains { rect in
                let bottom = root.isFlipped ? rect.maxY : root.bounds.height - rect.minY
                return abs(bottom - root.bounds.height) < 3 && rect.height >= availableHeight * 0.45
            }
            rawFrames["native_form"] = rects.first.map { ["x": $0.minX, "y": $0.minY, "width": $0.width, "height": $0.height] }
            try check(fullHeight, "\(name): native Form viewport reaches the actual bottom of the window")
        }
        var visibleRows = 0
        if browser {
            guard let split = frames["split"], let footer = frames["pagination"], let column = frames["list_column"] else { throw NSError(domain: "MonitorGeometry", code: 2) }
            try check(split.height >= content.height * 0.45 && abs(split.maxY - content.maxY) < 2, "\(name): data browser fills remaining height")
            try check(abs(column.height - split.height) < 2 && abs(footer.maxY - split.maxY) < 2, "\(name): pagination is anchored to the bottom of the list column")
            func tables(_ view: NSView) -> [NSTableView] { (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap(tables) }
            if rowsExpected, let view = window.contentView {
                let candidates = tables(view).filter { $0.numberOfRows >= 20 }
                visibleRows = candidates.map { table in
                    let range = table.rows(in: table.visibleRect)
                    return range.location == NSNotFound ? 0 : range.length
                }.max() ?? 0
                try check(visibleRows >= 4, "\(name): populated list exposes at least four native table rows (\(visibleRows))")
            }
        }
        var result: [String: Any] = ["visibleRows": visibleRows]
        result["frames"] = rawFrames
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("layout-" + name + ".json"))
    }
    @MainActor private func verifyMemoryMonitor(_ c: CompanionCoordinator, a: UUID, b: UUID) async throws {
        let store = try NativeCompanionStore(root: c.root)
        let owner = a.uuidString
        _ = try store.ingestPersona(characterID: owner, markdown: String(contentsOf: c.personaURL(a), encoding: .utf8))
        for index in 0..<35 { _ = try store.memoryWrite(owner: owner, type: "fact", provenance: "inferred", content: "监控测试 / Monitor fixture \(index): separate evidence, time and source.") }
        let original = L10n.language
        let model = c.monitor; model.companion = c
        func waitForRead() async throws {
            for _ in 0..<100 {
                if !model.loading { break }
                try await Task.sleep(nanoseconds: 30_000_000)
            }
            try check(!model.loading && model.error == nil && model.page != nil, "Monitor host query returns a typed page without model generation")
        }
        model.navigate(owner: owner, section: "L3")
        try await waitForRead()
        try check(model.page?.total == 35 && model.page?.items.count == 30, "Monitor UI consumes server totals and a bounded first page")
        let stalePage = model.page!
        model.navigate(owner: b.uuidString, section: "L3")
        model.receive(try CompanionMonitorCoding.object(stalePage).merging(["type": "monitor.page"], uniquingKeysWith: { _, new in new }))
        try check(model.page == nil, "A late response cannot replace the newly selected character")
        try await waitForRead()
        model.navigate(owner: owner, section: "L3"); try await waitForRead()
        model.select(model.page!.items[0]); model.begin("archive")
        for _ in 0..<100 {
            if !model.busy { break }; try await Task.sleep(nanoseconds: 30_000_000)
        }
        try check(model.plan?.action.operation == "archive", "Native management flow obtains an impact preview before confirmation")
        model.commit()
        for _ in 0..<100 {
            if !model.busy && !model.loading { break }; try await Task.sleep(nanoseconds: 30_000_000)
        }
        try check(model.error == nil && model.plan == nil && model.result == "completed", "Confirmed management refreshes the typed panel and reports completion")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 780), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        for lang in [AppLanguage.simplifiedChinese, .traditionalChinese, .english, .japanese] {
            LanguageStore.shared.selection = lang
            for dark in [false, true] {
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                model.navigate(owner: owner, section: "L3"); try await waitForRead()
                model.select(model.page!.items[0])
                model.layoutFrames = [:]
                let host = NSHostingController(rootView: CompanionHistoryView(companion: c, loadOnAppear: false, initialOwner: owner, initialSection: "L3")); host.sizingOptions = []
                window.contentViewController = host
                window.setContentSize(NSSize(width: 1160, height: 780)); window.orderFront(nil)
                try await Task.sleep(nanoseconds: 120_000_000)
                try await verifyMonitorGeometry(window, model: model, name: "\(lang.rawValue)-\(dark ? "dark" : "light")", browser: true, rowsExpected: true)
                try capture(window, "memory-monitor-\(lang.rawValue)-\(dark ? "dark" : "light")")
            }
        }
        for section in ["role_overview", "L0", "L1", "L2", "L3", "L4", "L5", "views", "relations", "traits", "reflections", "growth", "legacy"] {
            model.navigate(owner: owner, section: section); try await waitForRead()
            model.layoutFrames = [:]
            let host = NSHostingController(rootView: CompanionHistoryView(companion: c, loadOnAppear: false, initialOwner: owner, initialSection: section)); host.sizingOptions = []
                window.contentViewController = host
            window.setContentSize(NSSize(width: 920, height: 650))
            try await Task.sleep(nanoseconds: 80_000_000)
            try await verifyMonitorGeometry(window, model: model, name: section + "-minimum", browser: !["role_overview", "L1"].contains(section), rowsExpected: section == "L3")
            try capture(window, "memory-monitor-\(section)-minimum")
        }
        _ = try store.event("utterance", ["characterId": owner, "text": "Layout conversation fixture"])
        _ = try store.updateRecord(actor: owner, name: "layout-test.md", content: "Layout shared note", revision: try store.readRecord("layout-test.md")["revision"] as? String)
        for section in ["overview", "conversation", "public", "audit"] {
            model.navigate(section: section); try await waitForRead()
            model.layoutFrames = [:]
            let host = NSHostingController(rootView: CompanionHistoryView(companion: c, loadOnAppear: false, initialSection: section)); host.sizingOptions = []
                window.contentViewController = host
            window.setContentSize(NSSize(width: 1160, height: 780))
            try await Task.sleep(nanoseconds: 100_000_000)
            try await verifyMonitorGeometry(window, model: model, name: section, browser: section != "overview")
        }
        let action = CompanionMonitorAction(operation: "forget", owner: owner, kind: "memory", target: "fixture")
        let longPlan = CompanionMonitorPlan(id: "layout-confirmation", action: action, before: String(repeating: "Long source text ", count: 400), after: "", affected: (0..<200).map { .init(id: "evidence-\($0)", kind: "memory") }, expiresAt: "2099-01-01T00:00:00Z")
        var confirmationFrames: [String: CGRect] = [:]
        let confirmationHost = NSHostingController(rootView: CompanionMonitorConfirmationView(plan: longPlan, expandImpact: true, cancel: {}, confirm: {}, reportFrames: { confirmationFrames = $0 }))
        confirmationHost.sizingOptions = []; window.contentViewController = confirmationHost
        try await Task.sleep(nanoseconds: 180_000_000)
        guard let sheet = confirmationFrames["confirmation"], let footer = confirmationFrames["confirmation_footer"], let scroll = confirmationFrames["confirmation_scroll"] else { throw NSError(domain: "MonitorGeometry", code: 3) }
        try check(abs(footer.maxY - sheet.maxY) < 2 && scroll.maxY <= footer.minY + 2 && sheet.height <= 650, "Long confirmation with 200 affected items keeps its footer visible within bounded height")
        window.orderOut(nil)
        LanguageStore.shared.selection = original
        model.activate(); try check(model.isPolling, "Visible memory monitor enables bounded fallback refresh")
        model.deactivate(); try check(!model.isPolling && !model.visible, "Closing the monitor stops its dedicated polling")
        let spent = try store.rows("SELECT COUNT(*) AS n FROM requests").first?["n"] as? Int
        try check(spent == 0, "Monitoring and explicit memory management do not spend the model budget")
    }
    func run() {
        Task { @MainActor in
            do {
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                try check(manager.records.count >= 2, "Two model instances loaded")
                let c = CompanionCoordinator(manager: manager); manager.companion = c
                let legacySettings = try JSONDecoder().decode(CompanionSettings.self, from: Data("{}".utf8))
                try check(legacySettings.bubbleRetentionSeconds == 8, "Existing settings default to eight-second bubble retention")
                try check(legacySettings.webSearchEnabled, "Existing settings enable search-only MCP access")
                var searchSettings = CompanionSettings(); searchSettings.webSearchEnabled = false
                let restoredSearch = try JSONDecoder().decode(CompanionSettings.self, from: JSONEncoder().encode(searchSettings))
                try check(!restoredSearch.webSearchEnabled, "Disabling web search survives settings serialization")
                var durationSettings = CompanionSettings(); durationSettings.bubbleRetentionSeconds = 12
                let restoredDuration = try JSONDecoder().decode(CompanionSettings.self, from: JSONEncoder().encode(durationSettings))
                try check(restoredDuration.bubbleRetentionSeconds == 12, "Custom bubble duration survives settings serialization")
                c.receive(["type": "status", "sources": [:], "busy": false,
                    "openCodeService": ["state": "running", "pid": 42, "version": "2.2.5"]])
                try check(c.openCodeService["state"] as? String == "running" && c.openCodeService["pid"] as? Int == 42,
                    "Companion settings receive OpenCode service lifecycle status")
                let a = manager.records[0], b = manager.records[1]
                let plain = output.appendingPathComponent("plain-persona.md")
                try "A quiet companion, defined only by this Markdown.".write(to: plain, atomically: true, encoding: .utf8)
                try c.installPersona(from: plain, for: a.settings.id)
                try c.installPersona(from: plain, for: b.settings.id)
                try check(c.hasPersona(a.settings.id) && (try? String(contentsOf: c.personaURL(a.settings.id), encoding: .utf8)) == "A quiet companion, defined only by this Markdown.", "Plain Markdown imports as this model instance's independent Persona")
                if let packPath = ProcessInfo.processInfo.environment["LITE2D_PERSONA_PACK"] {
                    for (record, speaker) in [(a, "22"), (b, "33")] {
                        try c.installPersona(from: URL(fileURLWithPath: packPath).appendingPathComponent("persona_\(speaker).md"), for: record.settings.id)
                        let file = c.personaURL(record.settings.id).deletingLastPathComponent().appendingPathComponent("style_examples.jsonl")
                        let rows = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
                        try check(!rows.isEmpty && rows.allSatisfy { $0["speaker"] as? String == speaker }, "Persona \(speaker) imports only its own optional style examples")
                    }
                }
                let characterID = a.settings.id.uuidString
                c.receive(["type": "memory.items", "characterId": characterID,
                    "memories": [["id": "memory-fixture", "content": "A directly experienced event", "memory_type": "event", "provenance": "experienced", "evidence_ids": "[]"]],
                    "growth": ["reflections": [["id": "reflection-fixture", "status": "preview", "proposed_content": "Evidence summary awaiting review", "evidence_ids": "[memory-fixture]"]],
                               "proposals": [["id": "growth-fixture", "status": "preview", "field": "carefulness", "old_value": 0.5, "new_value": 0.53, "reason": "Repeated verification", "evidence_ids": "[memory-fixture]"]]]])
                try check(c.structuredMemories[characterID]?.count == 1 && c.growthStates[characterID] != nil, "Structured memory and review jobs arrive under the correct character")
                try check(c.structuredMemories[b.settings.id.uuidString] == nil, "Review state does not leak into another character's view")
                let memoryWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
                memoryWindow.contentView = NSHostingView(rootView: CompanionStructuredMemoryView(companion: c, characterID: characterID, loadOnAppear: false))
                memoryWindow.orderFront(nil)
                try await Task.sleep(nanoseconds: 200_000_000)
                try capture(memoryWindow, "companion-structured-memory")
                try check(memoryWindow.contentView?.bounds.width == 720, "Structured memory and growth review render in the native application")
                memoryWindow.orderOut(nil)
                if ProcessInfo.processInfo.environment["LITE2D_MONITOR_ONLY"] == "1" {
                    try await verifyMemoryMonitor(c, a: a.settings.id, b: b.settings.id)
                    c.shutdown()
                    try JSONSerialization.data(withJSONObject: ["passed": true, "checks": checks], options: .prettyPrinted).write(to: output.appendingPathComponent("passed.json"))
                    complete(0); return
                }
                let legacySource = try JSONDecoder().decode(CompanionSourceSettings.self, from: Data(#"{"enabled":true,"projects":["/old/project"]}"#.utf8))
                let migratedSource = String(decoding: try JSONEncoder().encode(legacySource), as: UTF8.self)
                try check(legacySource.enabled && !migratedSource.contains("projects"), "Old project scopes migrate to source-wide toggles")
                c.settings.sources = ["opencode": .init(enabled: true), "codex": .init(enabled: true), "claude": .init(enabled: true)]
                let snapshots = manager.records.map(\.settings)
                let originalLanguage = L10n.language
                let window = status.settingsWindow
                window.show(role: a.settings.id); window.model.page = .companion
                window.window?.setContentSize(NSSize(width: 820, height: 700))
                for language in [AppLanguage.simplifiedChinese, .traditionalChinese, .english, .japanese] {
                    LanguageStore.shared.selection = language
                    for page in ["role", "general"] {
                        window.model.selection = page == "role" ? a.settings.id.uuidString : "general"
                        try await Task.sleep(nanoseconds: 180_000_000)
                        if let w = window.window { try capture(w, "companion-\(language.rawValue)-\(page)") }
                    }
                }
                LanguageStore.shared.selection = originalLanguage
                try check(manager.records.map(\.settings) == snapshots, "Companion settings rendering does not mutate model state")
                window.window?.orderOut(nil)
                c.settings.characters[a.settings.id.uuidString] = .init(enabled: true, gaze: true)
                c.settings.characters[b.settings.id.uuidString] = .init(enabled: true, gaze: true)
                try check(!c.canTrigger(a.settings.id), "Test button is unavailable when Companion is disabled")
                c.settings.enabled = true; c.runtimeState = "running"
                try check(c.canTrigger(a.settings.id) && c.canTrigger(b.settings.id), "Each visible Persona has its own test action")
                c.settings.paused = true
                try check(!c.canTrigger(a.settings.id), "Do Not Disturb disables the test button")
                c.settings.paused = false; c.busy = true
                try check(!c.canTrigger(b.settings.id), "Ongoing conversation disables repeated test triggers")
                c.busy = false
                c.trigger(b.settings.id)
                try check(c.busy, "Manual trigger immediately blocks duplicate clicks")
                c.receive(["type": "error", "requestType": "trigger", "message": "Test budget response"])
                try check(!c.busy, "Rejected test command releases the busy state")
                c.error = nil; c.settings.enabled = false
                try check(c.canPlaceBubble(a.settings.id), "Bubble placement is available for a loaded visible model")
                c.beginBubblePlacement(a.settings.id)
                try check(c.bubbleEditingID == a.settings.id && c.bubblePreviewFrame != nil && c.bubblePreviewIsInteractive, "Adjust Position shows the draggable preview bubble")
                if let preview = c.bubblePreviewWindow { try capture(preview, "companion-bubble-placement-preview") }
                c.moveBubblePreview(by: NSPoint(x: 40, y: -25))
                let dragged = c.bubblePreviewFrame
                c.tick()
                try check(c.bubblePreviewFrame?.origin == dragged?.origin, "Background refresh does not snap the dragged preview back")
                c.finishBubblePlacement(a.settings.id, save: true)
                let offset = c.character(a.settings.id).bubbleOffset
                try check(abs((offset?.x ?? 0) - 40) < 0.6 && abs((offset?.y ?? 0) + 25) < 0.6, "Dragged bubble position is saved with the model")
                let savedCharacter = c.character(a.settings.id)
                let decodedCharacter = try JSONDecoder().decode(CompanionCharacterSettings.self, from: JSONEncoder().encode(savedCharacter))
                try check(decodedCharacter.bubbleOffset == offset, "Bubble position survives settings serialization")
                if let w = a.controller?.window {
                    let placed = CompanionBubble(); placed.offset = NSPoint(x: offset?.x ?? 0, y: offset?.y ?? 0)
                    placed.show(name: "22", text: "Bubble placement check", near: w)
                    let base = placed.baseOrigin(near: w)!, actual = placed.panel.frame.origin
                    try check(abs((actual.x - base.x) - 40) < 0.6 && abs((actual.y - base.y) + 25) < 0.6, "Normal speech uses the saved per-model bubble position: base=\(base) actual=\(actual) frame=\(placed.panel.frame) screen=\(w.screen?.visibleFrame ?? .zero)")
                    placed.hide()
                }
                c.resetBubblePlacement(a.settings.id)
                try check(c.character(a.settings.id).bubbleOffset == nil, "Bubble position can be reset to its default")
                let topic = UUID().uuidString
                c.receive(["type": "topic.start", "topicId": topic])
                c.receive(["type": "conversation.focus", "topicId": topic, "speakerId": a.settings.id.uuidString, "listenerId": b.settings.id.uuidString,
                    "validUntil": ISO8601DateFormatter().string(from: Date().addingTimeInterval(30))])
                c.tick()
                try check(a.controller?.view.companionLookTarget != nil && b.controller?.view.companionLookTarget != nil, "Both characters receive reciprocal gaze targets")
                // Drive the same frame path explicitly so occlusion/display-link
                // throttling during settings-window tests cannot hide a routing bug.
                for _ in 0..<12 {
                    a.controller?.view.renderFrame(deltaTime: 0.05)
                    b.controller?.view.renderFrame(deltaTime: 0.05)
                }
                let ax = a.controller?.view.filteredLook.x ?? 0, bx = b.controller?.view.filteredLook.x ?? 0
                try check(ax * bx < 0, "Rendered frames route reciprocal normalized gaze (\(ax), \(bx))")
                try check(manager.records.map(\.settings.trackingEnabled) == snapshots.map(\.trackingEnabled), "Conversation gaze preserves persisted mouse-follow preferences")
                let previous = a.controller?.view.companionLookTarget
                manager.move(b.settings.id, to: b.settings.windowFrame.rect.offsetBy(dx: 80, dy: 0)); c.tick()
                try check(a.controller?.view.companionLookTarget != previous, "Moving recipient updates gaze target")
                c.receive(["type": "topic.end", "topicId": topic, "reason": "cancelled"]); c.tick()
                try check(a.controller?.view.companionLookTarget == nil && b.controller?.view.companionLookTarget == nil, "Cancellation releases gaze")
                c.receive(["type": "conversation.focus", "topicId": topic, "speakerId": a.settings.id.uuidString, "listenerId": b.settings.id.uuidString,
                    "validUntil": ISO8601DateFormatter().string(from: Date().addingTimeInterval(30))]); c.tick()
                try check(a.controller?.view.companionLookTarget == nil, "Cancelled topic cannot reacquire gaze through late events")
                let bubble = CompanionBubble()
                if let w = a.controller?.window {
                    bubble.show(name: "22", text: "好耶，这次通过啦！三三，你也看到了吗？", near: w)
                    try await Task.sleep(nanoseconds: 100_000_000)
                    try check(bubble.panel.ignoresMouseEvents && !bubble.panel.isKeyWindow, "Speech bubble stays passive and does not steal focus")
                    try capture(bubble.panel, "companion-bubble")
                    bubble.show(name: "ignored", text: "然后测一下快速切换；", near: w)
                    bubble.show(name: "ignored", text: "最后检查播放器。", near: w)
                    bubble.show(name: "ignored", text: "这句出现时，最旧的一句消失。", near: w)
                    try await Task.sleep(nanoseconds: 250_000_000)
                    try check(bubble.sentenceCount == 4, "Speech rows have no sentence count limit")
                    try capture(bubble.panel, "companion-bubble-stack")
                    let withoutAvatar = bubble.panel.frame.width
                    try c.installAvatar(from: output.appendingPathComponent("companion-bubble.png"), for: a.settings.id)
                    try check(c.avatar(a.settings.id)?.size == NSSize(width: 128, height: 128), "Avatar is normalized to a local cropped PNG")
                    let avatarSettings = try JSONDecoder().decode(CompanionCharacterSettings.self, from: JSONEncoder().encode(c.character(a.settings.id)))
                    try check(avatarSettings.avatarFile == "avatar.png", "Avatar setting survives serialization")
                    bubble.configure(avatar: c.avatar(a.settings.id)); bubble.position(near: w)
                    try check(bubble.panel.frame.width == withoutAvatar + 44, "Avatar adds space only when configured")
                    try capture(bubble.panel, "companion-bubble-avatar")
                    bubble.configure(avatar: nil); bubble.position(near: w)
                    try check(bubble.sentenceCount == 4 && bubble.panel.frame.width == withoutAvatar, "Removing avatar preserves all rows without reserving space")
                    c.removeAvatar(a.settings.id)
                    try check(c.avatar(a.settings.id) == nil && c.character(a.settings.id).avatarFile == nil, "Avatar removal restores bubble-only presentation")
                    bubble.hide()
                    var completed = false
                    let typedText = "我现在正在测试逐字显示以及消失。"
                    let start = Date()
                    bubble.type(text: typedText, near: w) { completed = true }
                    try check(bubble.displayedTexts == ["我"], "Typewriter begins immediately with the first unit")
                    try await Task.sleep(nanoseconds: 160_000_000)
                    try check(bubble.displayedTexts.first != typedText && !completed, "Text appears progressively while typing")
                    try capture(bubble.panel, "companion-bubble-typing")
                    let playback = CompanionSpeechPlayback(text: typedText, startedAt: start)
                    bubble.advance(to: playback.completedAt.addingTimeInterval(0.1))
                    try check(completed && bubble.displayedTexts == [typedText], "Typing completion reveals the full sentence")
                    bubble.configure(avatar: nil)
                    bubble.advance(to: playback.expiresAt.addingTimeInterval(0.1))
                    try check(bubble.sentenceCount == 0 && !bubble.panel.isVisible, "Expiry removes the bubble and avatar even after reconfiguration")
                    bubble.hide()
                    bubble.configure(avatar: nil, retention: 12)
                    var dismissedTyping = false
                    bubble.type(text: "这个气泡可以在打字时手动关闭。", near: w) { dismissedTyping = true }
                    if let button = bubble.closeButton(at: 0) {
                        try check(button.isHidden && bubble.panel.ignoresMouseEvents, "Close control is hidden and speech remains click-through by default")
                        let center = NSPoint(x: button.bounds.midX, y: button.bounds.midY)
                        let point = bubble.panel.convertPoint(toScreen: button.convert(center, to: nil))
                        bubble.updateHover(at: point)
                        try check(!button.isHidden && !bubble.panel.ignoresMouseEvents && !bubble.panel.isKeyWindow, "Hover reveals a clickable native close control without taking focus")
                        let hit = bubble.panel.contentView?.hitTest(button.convert(center, to: bubble.panel.contentView))
                        try check(hit === button || hit?.isDescendant(of: button) == true, "Native hit testing routes the close control to its button")
                        bubble.panel.display(); CATransaction.flush()
                        try capture(bubble.panel, "companion-bubble-close")
                        button.performClick(nil)
                        try check(bubble.sentenceCount == 0 && dismissedTyping, "Closing the typing bubble removes it and releases the queue")
                    } else { try check(false, "A close button exists for each speech bubble") }
                    bubble.hide()

                }
                c.receive(["type": "utterance", "sequence": 1, "createdAt": "2026-11-04T00:00:00Z", "characterId": a.settings.id.uuidString, "text": "好耶，这次通过啦！"])
                c.receive(["type": "utterance", "sequence": 2, "createdAt": "2026-11-04T00:00:01Z", "characterId": b.settings.id.uuidString, "text": "嗯，记录里这次确实通过了。姐姐，别忘了保留测试结果。"])
                c.stopTopic()
                c.settings.bubbleRetentionSeconds = 1
                let original = "甲。乙！丙？丁；戊……己。"
                c.receive(["type": "utterance", "sequence": 3, "characterId": a.settings.id.uuidString, "text": original])
                try check(c.speechTexts(a.settings.id) == ["甲。"], "First sentence starts typing immediately")
                try await Task.sleep(nanoseconds: 600_000_000); c.tick()
                try check(c.speechTexts(a.settings.id) == ["甲。", "乙！", "丙？", "丁；", "戊……", "己。"], "Next sentence types during previous retention with no count limit")
                try check(c.entries.last?.text == original, "History retains the complete original utterance")
                try await Task.sleep(nanoseconds: 1_100_000_000); c.tick()
                try check(c.speechTexts(a.settings.id).isEmpty && !c.hasSpeech, "All sentences disappear on their own deadlines")
                c.receive(["type": "utterance", "sequence": 4, "characterId": a.settings.id.uuidString, "text": "停止时取消正在打字的句子。"])
                c.stopTopic()
                try await Task.sleep(nanoseconds: 150_000_000)
                try check(c.speechTexts(a.settings.id).isEmpty && !c.hasSpeech, "Stopping cancels typing and prevents late callbacks")
                try await verifyGroups(c, a: a, b: b)
                try await verifyMemoryMonitor(c, a: a.settings.id, b: b.settings.id)
                c.shutdown()
                try JSONSerialization.data(withJSONObject: ["passed": true, "checks": checks], options: .prettyPrinted).write(to: output.appendingPathComponent("passed.json"))
                complete(0)
            } catch {
                try? JSONSerialization.data(withJSONObject: ["passed": false, "checks": checks, "error": error.localizedDescription], options: .prettyPrinted).write(to: output.appendingPathComponent("failed.json"))
                complete(1)
            }
        }
    }
}
