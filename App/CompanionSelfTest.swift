import AppKit

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
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw NSError(domain: "capture", code: 2) }
        try data.write(to: output.appendingPathComponent(name + ".png"))
    }
    func run() {
        Task { @MainActor in
            do {
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                try check(manager.records.count >= 2, "Two model instances loaded")
                let c = CompanionCoordinator(manager: manager); manager.companion = c
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

                }
                c.receive(["type": "utterance", "sequence": 1, "createdAt": "2026-11-04T00:00:00Z", "characterId": a.settings.id.uuidString, "text": "好耶，这次通过啦！"])
                c.receive(["type": "utterance", "sequence": 2, "createdAt": "2026-11-04T00:00:01Z", "characterId": b.settings.id.uuidString, "text": "嗯，记录里这次确实通过了。姐姐，别忘了保留测试结果。"])
                c.stopTopic()
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
                let history = CompanionHistoryView.makeWindow(coordinator: c)
                history.makeKeyAndOrderFront(nil)
                try await Task.sleep(nanoseconds: 160_000_000)
                try capture(history, "companion-history"); history.close()
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
