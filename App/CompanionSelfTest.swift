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
                let a = manager.records[0], b = manager.records[1]
                let plain = output.appendingPathComponent("plain-persona.md")
                try "A quiet companion, defined only by this Markdown.".write(to: plain, atomically: true, encoding: .utf8)
                try c.installPersona(from: plain, for: a.settings.id)
                try check(c.hasPersona(a.settings.id) && (try? String(contentsOf: c.personaURL(a.settings.id), encoding: .utf8)) == "A quiet companion, defined only by this Markdown.", "Plain Markdown imports as this model instance's independent Persona")
                if let packPath = ProcessInfo.processInfo.environment["LITE2D_PERSONA_PACK"] {
                    for (record, speaker) in [(a, "22"), (b, "33")] {
                        try c.installPersona(from: URL(fileURLWithPath: packPath).appendingPathComponent("persona_\(speaker).md"), for: record.settings.id)
                        let file = c.personaURL(record.settings.id).deletingLastPathComponent().appendingPathComponent("style_examples.jsonl")
                        let rows = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
                        try check(!rows.isEmpty && rows.allSatisfy { $0["speaker"] as? String == speaker }, "Persona \(speaker) imports only its own optional style examples")
                    }
                }
                c.settings.sources = ["opencode": .init(enabled: true, projects: ["/Example/Project"]), "codex": .init(enabled: true, projects: ["/Example/Project"]), "claude": .init(enabled: true, projects: ["/Example/Project"])]
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
                    try capture(bubble.panel, "companion-bubble"); bubble.hide()
                }
                c.receive(["type": "utterance", "sequence": 1, "createdAt": "2026-11-04T00:00:00Z", "characterId": a.settings.id.uuidString, "text": "好耶，这次通过啦！"])
                c.receive(["type": "utterance", "sequence": 2, "createdAt": "2026-11-04T00:00:01Z", "characterId": b.settings.id.uuidString, "text": "嗯，记录里这次确实通过了。姐姐，别忘了保留测试结果。"])
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
