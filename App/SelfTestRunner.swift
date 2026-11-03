import AppKit

private final class WeakModelView {
    weak var value: OpenGLModelView?
    init(_ value: OpenGLModelView) { self.value = value }
}

// Exercises the same instance manager used by menu commands. It never sends
// keyboard/mouse events, automates another app, or captures the desktop.
final class SelfTestRunner {
    let manager: ModelInstanceManager
    let status: StatusBarController
    let output: URL
    let complete: (Int32) -> Void
    var results: [String] = []
    var a = UUID(), b = UUID(), native = UUID(), duplicate = UUID()
    var nativeDuplicate = UUID()
    var minimalID = UUID()
    var leftFrame: Data?
    var frozenTime = 0.0, nativeTime = 0.0
    var counters: [UUID: UInt64] = [:]
    var fpsStart = 0.0
    var fps: [String: Double] = [:]
    var callbackCounters: [UInt64] = []
    var memorySamples: [[String: Any]] = []
    var originalDisplays: [DisplayDescriptor] = []
    var offlineDisplayID = ""
    var savedDisplayPosition: DisplayPosition?
    private var removedViews: [WeakModelView] = []
    private var finished = false

    init(manager: ModelInstanceManager, status: StatusBarController, output: URL, complete: @escaping (Int32) -> Void) {
        self.manager = manager; self.status = status; self.output = output; self.complete = complete
    }
    private func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw NSError(domain: "Lite2D.SelfTest", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        results.append(message)
    }
    private func later(_ seconds: Double = 0.35, _ work: @escaping () throws -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [self] in
            guard !finished else { return }
            do { try work() } catch { finish(error) }
        }
    }
    private func view(_ id: UUID) throws -> OpenGLModelView {
        guard let view = manager.record(id)?.controller?.view else { throw NSError(domain: "Lite2D.SelfTest", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing instance \(id)"]) }
        return view
    }
    @discardableResult private func capture(_ id: UUID, label: String) throws -> Data {
        guard let frame = try view(id).capture() else { throw NSError(domain: "Lite2D.SelfTest", code: 3, userInfo: [NSLocalizedDescriptionKey: "No framebuffer for \(label)"]) }
        try check(frame.glError == 0, "\(label): OpenGL error is zero")
        let alpha = stride(from: 3, to: frame.data.count, by: 4).map { frame.data[$0] }
        try check(alpha.contains(0) && alpha.contains { $0 > 0 }, "\(label): both transparent background and visible model")
        try check(stride(from: 0, to: frame.data.count, by: 4).contains { frame.data[$0] > 20 && frame.data[$0+1] > 20 }, "\(label): textured color pixels exist")
        try frame.data.write(to: output.appendingPathComponent(label + ".rgba"))
        let metadata: [String: Any] = ["width": frame.width, "height": frame.height, "glError": frame.glError]
        try JSONSerialization.data(withJSONObject: metadata, options: .prettyPrinted).write(to: output.appendingPathComponent(label + ".json"))
        return frame.data
    }
    private func rememberFrames() { counters = Dictionary(uniqueKeysWithValues: manager.records.compactMap { r in r.controller.map { (r.settings.id, $0.view.frames) } }) }

    func run() {
        later(1) { [self] in
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try check(manager.records.count == 3, "Three initial instances loaded")
            a = manager.records[0].settings.id; b = manager.records[1].settings.id; native = manager.records[2].settings.id
            try check(manager.records.allSatisfy { $0.controller?.window.isVisible == true }, "All three have visible independent windows")
            for record in manager.records { try check(try view(record.settings.id).frames > 5, "\(record.settings.displayName): display link rendered frames") }
            _ = try capture(a, label: "initial-22"); _ = try capture(b, label: "initial-33"); _ = try capture(native, label: "initial-native")
            let copy = try manager.duplicate(native)!
            nativeDuplicate = copy.settings.id
            let contexts = manager.records.compactMap { $0.controller?.view.openGLContext }.map(ObjectIdentifier.init)
            try check(Set(contexts).count == 4, "Four distinct OpenGL context objects")
            testLocalization { try self.afterNativeDuplicate() }
        }
    }

    /// Screenshots cover the minimum supported window width in every language.
    /// Refresh the existing tree: replacing the root would discard editor state.
    private func testLocalization(complete: @escaping () throws -> Void) {
        let originalLanguage = L10n.language
        let snapshots = manager.records.map(\.settings)
        let controllers = manager.records.compactMap { $0.controller }.map(ObjectIdentifier.init)
        let settings = status.settingsWindow
        settings.show(role: a)
        settings.window?.setContentSize(NSSize(width: 820, height: 640))
        let languages: [AppLanguage] = [.english, .simplifiedChinese, .traditionalChinese, .japanese]
        let steps = languages.flatMap { language in
            ["general", "appearance", "interaction", "advanced"].map { (language, $0) }
        }
        func advance(_ index: Int) {
            if index == steps.count {
                later(0.1) { [self] in
                    try check(manager.records.map(\.settings) == snapshots, "Language switching preserves all model settings")
                    try check(manager.records.compactMap { $0.controller }.map(ObjectIdentifier.init) == controllers,
                              "Language switching keeps the same live model controllers")
                    testLocalizedInput {
                        LanguageStore.shared.selection = originalLanguage
                        settings.window?.orderOut(nil)
                        try complete()
                    }
                }
                return
            }
            let (language, page) = steps[index]
            let expectedSelection = page == "general" ? "general" : a.uuidString
            settings.model.selection = expectedSelection
            if let rolePage = RoleSettingsPage(rawValue: page) { settings.model.page = rolePage }
            let expectedPage = settings.model.page
            LanguageStore.shared.selection = language
            later(0.25) { [self] in
                try check(settings.model.selection == expectedSelection && settings.model.page == expectedPage,
                          "\(language.rawValue)/\(page): selected character and page survive language change")
                try check(settings.window?.title == L10n.text("settings.title") &&
                          status.menu.items.contains { $0.title == L10n.text("settings.open") },
                          "\(language.rawValue)/\(page): open window title and AppKit menu update immediately")
                if let window = settings.window {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    let path = output.appendingPathComponent("localization-\(language.rawValue)-\(page).png")
                    process.arguments = ["-x", "-o", "-l", String(window.windowNumber), path.path]
                    try process.run(); process.waitUntilExit()
                    try check(process.terminationStatus == 0 && FileManager.default.fileExists(atPath: path.path),
                              "\(language.rawValue)/\(page): settings screenshot saved")
                }
                advance(index + 1)
            }
        }
        advance(0)
    }


    private func testLocalizedInput(complete: @escaping () throws -> Void) {
        let settings = status.settingsWindow
        settings.model.selection = a.uuidString; settings.model.page = .appearance
        LanguageStore.shared.selection = .english
        later(0.2) { [self] in
            func fields(_ view: NSView) -> [NSTextField] {
                (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields)
            }
            guard let window = settings.window, let content = window.contentView,
                  let field = fields(content).first(where: { $0.isEditable }) else {
                throw NSError(domain: "Lite2D.SelfTest", code: 5, userInfo: [NSLocalizedDescriptionKey: "Missing native role name editor"])
            }
            let storedName = manager.record(a)!.settings.displayName
            window.makeFirstResponder(field)
            guard let editor = field.currentEditor() as? NSTextView else {
                throw NSError(domain: "Lite2D.SelfTest", code: 5, userInfo: [NSLocalizedDescriptionKey: "Could not focus role name editor"])
            }
            let draft = "Unsubmitted 名称"
            editor.string = draft
            field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
            editor.setSelectedRange(NSRange(location: 2, length: 3))
            LanguageStore.shared.selection = .japanese
            later(0.2) { [self] in
                try check(editor.string == draft && editor.selectedRange() == NSRange(location: 2, length: 3),
                          "Language switching preserves unsubmitted input and text selection")
                try check(manager.record(a)!.settings.displayName == storedName,
                          "Language switching does not submit a pending rename")
                editor.string = storedName
                field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
                window.makeFirstResponder(nil)
                try complete()
            }
        }
    }

    private func afterNativeDuplicate() throws {
            _ = try capture(nativeDuplicate, label: "duplicate-native")
            manager.remove(nativeDuplicate)
            _ = try capture(native, label: "native-after-duplicate-removal")
            let fixtures = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".local/verification/fixtures")
            let minimal = try manager.add(fixtures.appendingPathComponent("native-minimal/model.model3.json"), name: "minimal native")
            minimalID = minimal.settings.id
            for missing in ["native-missing-moc", "native-missing-texture"] {
                var rejected = false
                do { _ = try manager.add(fixtures.appendingPathComponent("\(missing)/model.model3.json")) }
                catch { rejected = true }
                try check(rejected && manager.records.count == 4, "\(missing): required resource failure is isolated")
            }
            later(0.35) { try self.afterMinimal() }
    }
    private func afterMinimal() throws {
            try check(try view(minimalID).bridge.motionGroups.isEmpty, "Native model without motions loads without fake idle resources")
            _ = try capture(minimalID, label: "native-no-motion-no-physics")
            manager.remove(minimalID)
            _ = try capture(native, label: "native-after-failed-adds")
            let twin = try manager.duplicate(a)!
            duplicate = twin.settings.id
            try testOutfits()
            try check(twin.settings.id != a && twin.settings.modelPath == manager.record(a)!.settings.modelPath, "Duplicate asset has a new UUID")
            try check(twin.controller!.view.bridge !== manager.record(a)!.controller!.view.bridge, "Duplicate asset has an independent engine bridge")
            later(0.35) { try self.beginTracking() }
    }
    private func beginTracking() throws {
            _ = try capture(duplicate, label: "duplicate-22")
            status.rebuild()
            try check(status.menu.items.filter { $0.submenu != nil }.count == 4, "Status menu lists all four instance submenus")
            manager.mutate(a) { $0.animationPaused = true; $0.trackingEnabled = false; $0.targetFPS = 30 }
            manager.mutate(b) { $0.animationPaused = true; $0.trackingEnabled = true; $0.targetFPS = 60 }
            frozenTime = try view(a).animationTime; nativeTime = try view(native).animationTime
            let window = manager.record(b)!.controller!.window
            SharedMouseTracker.shared.testPoint = NSPoint(x: window.frame.minX - 400, y: window.frame.maxY + 200)
            later(1) { try self.leftLook() }
    }
    private func testOutfits() throws {
        guard let record = manager.record(a), record.outfits.count > 1 else {
            throw NSError(domain: "Lite2D.SelfTest", code: 4, userInfo: [NSLocalizedDescriptionKey: "Outfit fixture required"])
        }
        let originalSettings = record.settings
        manager.mutate(a) { $0.animationPaused = true; $0.trackingEnabled = false }
        try manager.setOutfit(a, outfitID: "")
        let original = try capture(a, label: "outfit-default")
        let otherController = manager.record(b)!.controller!
        let duplicateController = manager.record(duplicate)!.controller!
        let otherSettings = manager.record(b)!.settings
        var frames = Set<Data>()
        for outfit in record.outfits {
            try manager.setOutfit(a, outfitID: outfit.id)
            let frame = try capture(a, label: "outfit-\(outfit.name.replacingOccurrences(of: "/", with: "-"))")
            frames.insert(frame)
            try check(manager.record(a)!.settings.outfitID == (outfit.id.isEmpty ? nil : outfit.id), "Outfit selection commits only to selected instance")
        }
        try check(frames.count == record.outfits.count, "All 19 outfits render distinct textured frames")
        try check(manager.record(b)!.controller === otherController && manager.record(b)!.settings == otherSettings && manager.record(duplicate)!.controller === duplicateController, "Outfit switching preserves other instance controllers and settings")
        try manager.setOutfit(a, outfitID: "")
        try check(try capture(a, label: "outfit-return-default") == original, "Returning to default restores original pixels while paused")
        let beforeFailure = manager.record(a)!.settings
        var rejected = false
        do { try manager.setOutfit(a, outfitID: "../invalid.json") } catch { rejected = true }
        try check(rejected && manager.record(a)!.settings == beforeFailure, "Invalid outfit leaves saved settings untouched")
        try check(try capture(a, label: "outfit-after-failure") == original, "Invalid outfit preserves current renderer")
        // A readable but corrupt texture reaches the engine decoder, beyond validation.
        let fixtureRoot = output.appendingPathComponent("outfit-failure-fixture")
        try? FileManager.default.removeItem(at: fixtureRoot)
        let sourceRoot = URL(fileURLWithPath: record.settings.modelPath).deletingLastPathComponent()
        try FileManager.default.copyItem(at: sourceRoot, to: fixtureRoot)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let fixtureEntry = fixtureRoot.appendingPathComponent(URL(fileURLWithPath: record.settings.modelPath).lastPathComponent)
        let fixtureRecord = try manager.add(fixtureEntry, name: "outfit decode failure")
        let fixtureID = fixtureRecord.settings.id
        defer { manager.remove(fixtureID) }
        manager.mutate(fixtureID) { $0.animationPaused = true; $0.trackingEnabled = false }
        try manager.setOutfit(fixtureID, outfitID: "")
        fixtureRecord.controller!.window.display()
        let fixtureBefore = try capture(fixtureID, label: "outfit-decode-before")
        let brokenOutfit = fixtureRecord.outfits[1]
        let brokenURL = try ModelOutfitCatalog.resolve(brokenOutfit.id, relativeTo: fixtureEntry)
        let baseJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureEntry)) as! [String: Any]
        let costumeJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: brokenURL)) as! [String: Any]
        let baseTextures = baseJSON["textures"] as! [String]
        let alternateTexture = (costumeJSON["textures"] as! [String]).first { !baseTextures.contains($0) }!
        try Data("invalid PNG".utf8).write(to: fixtureRoot.appendingPathComponent(alternateTexture))
        let beforeDecodeFailure = fixtureRecord.settings
        rejected = false
        do { try manager.setOutfit(fixtureID, outfitID: brokenOutfit.id) } catch { rejected = true }
        try check(rejected && fixtureRecord.settings == beforeDecodeFailure, "Texture decode failure leaves outfit settings unchanged")
        try check(try capture(fixtureID, label: "outfit-decode-after") == fixtureBefore, "Texture decode failure preserves the live engine and pixels")
        let selected = record.outfits[1]
        try manager.setOutfit(a, outfitID: selected.id)
        let copy = try manager.duplicate(a)!
        try check(copy.settings.outfitID == selected.id, "Duplicate preserves selected outfit independently")
        manager.remove(copy.settings.id)
        manager.save()
        try check(manager.store.load().instances.first { $0.id == a }?.outfitID == selected.id, "Selected outfit persists to disk")
        try manager.setOutfit(a, outfitID: "")
        manager.mutate(a) { $0.animationPaused = originalSettings.animationPaused; $0.trackingEnabled = originalSettings.trackingEnabled }
        status.rebuild()
        let instanceMenu = status.menu.item(at: 0)?.submenu
        let outfitMenu = instanceMenu?.items.first { $0.title == L10n.text("outfit.section") }?.submenu
        try check(outfitMenu?.items.count == 19 && outfitMenu?.items.first?.state == .on, "Status menu shows 19 named outfits and selected checkmark")
        try check(try view(a).bridge.motionGroups["1"] == nil, "Costume commands are excluded from playable motion groups")
    }
    private func leftLook() throws {
        try check(abs(try view(a).filteredLook.x) < 0.02, "Tracking disabled instance smoothly returns to center")
        try check(try view(b).filteredLook.x < -0.9, "Click-through non-focused instance follows left screen target")
        try check(try view(a).animationTime == frozenTime, "Only paused instance animation clock remains frozen")
        try check(try view(native).animationTime > nativeTime + 0.5, "Other instance animation keeps advancing")
        leftFrame = try capture(b, label: "look-left-33")
        let window = manager.record(b)!.controller!.window
        SharedMouseTracker.shared.testPoint = NSPoint(x: window.frame.maxX + 400, y: window.frame.maxY + 200)
        later(1) { try self.rightLook() }
    }
    private func rightLook() throws {
        try check(try view(b).filteredLook.x > 0.9, "Independent target follows right screen position")
        let right = try capture(b, label: "look-right-33")
        try check(right != leftFrame, "Frozen 33 model geometry changes with look direction")
        let priorB = manager.record(b)!.settings
        manager.edit(a)
        try check(manager.record(a)!.controller!.window.ignoresMouseEvents == false && manager.record(b)!.controller!.window.ignoresMouseEvents, "Editing A leaves B click-through")
        manager.zoom(a, factor: 1.2)
        try check(manager.record(b)!.settings == priorB, "Zooming A leaves B settings untouched")
        manager.edit(b)
        try check(manager.record(a)!.controller!.window.ignoresMouseEvents && !manager.record(b)!.controller!.window.ignoresMouseEvents, "Changing edit selection restores previous click-through")
        manager.edit(b)
        for screen in NSScreen.screens {
            let controller = manager.record(a)!.controller!
            let anchorBeforeSystemMove = manager.record(a)!.settings.displayPosition
            controller.window.setFrameOrigin(NSPoint(x: screen.visibleFrame.minX + 20, y: screen.visibleFrame.minY + 20))
            try check(manager.record(a)!.settings.displayPosition == anchorBeforeSystemMove, "System-originated window moves do not rewrite a saved display anchor")
            controller.view.onDragFinished?(controller.window.frame)
            let expectedDisplay = DisplayLayout.matching(controller.window.frame, in: manager.displayRegistry.displays)
            try check(manager.record(a)!.settings.displayUUID == expectedDisplay?.id, "User drag callback explicitly updates the physical display binding")
            let point = NSPoint(x: screen.frame.midX, y: screen.frame.midY)
            let local = controller.window.convertPoint(fromScreen: point)
            let roundTrip = controller.window.convertPoint(toScreen: local)
            try check(abs(roundTrip.x - point.x) < 0.01 && abs(roundTrip.y - point.y) < 0.01, "Coordinate conversion round trip: \(screen.localizedName)")
        }
        manager.resetPosition(a)
        originalDisplays = manager.displayRegistry.displays
        try check(originalDisplays.count >= 2, "Display binding integration uses two actual display identities")
        offlineDisplayID = originalDisplays[0].id
        manager.bind(a, to: offlineDisplayID)
        manager.bind(b, to: originalDisplays[1].id)
        savedDisplayPosition = manager.record(a)!.settings.displayPosition
        let cached = manager.record(a)!.settings.windowFrame
        manager.displayRegistry.testingDisplays = originalDisplays.filter { $0.id != offlineDisplayID }
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        try check(!manager.record(a)!.controller!.window.isVisible && !manager.record(a)!.controller!.view.active, "Disconnecting bound display hides and unschedules its instance")
        try check(manager.record(a)!.settings.windowFrame == cached && manager.record(a)!.settings.displayPosition == savedDisplayPosition, "Display absence preserves saved global cache and screen-local anchor")
        try check(manager.record(b)!.controller!.window.isVisible, "Instance bound to another display remains visible")
        rememberFrames()
        later(0.5) { try self.disconnectedDisplay() }
    }
    private func disconnectedDisplay() throws {
        try check(try view(a).frames == counters[a], "Disconnected display instance draws zero frames")
        try check(try view(b).frames > counters[b]!, "Other display instance continues rendering")
        manager.bringForward(a)
        manager.toggleAllHidden(); manager.toggleAllHidden()
        try check(!manager.record(a)!.controller!.window.isVisible, "Bring-forward and global restore cannot surface an offline-bound instance")
        let offlineCopy = try manager.duplicate(a)!
        try check(offlineCopy.settings.displayUUID == offlineDisplayID && !offlineCopy.controller!.window.isVisible, "Duplicating an offline binding stays on the absent display")
        manager.bind(offlineCopy.settings.id, to: originalDisplays[1].id)
        try check(offlineCopy.controller!.window.isVisible && manager.record(a)!.settings.displayUUID == offlineDisplayID, "Explicit rebind shows only the selected offline instance on the chosen display")
        manager.remove(offlineCopy.settings.id)
        manager.save()
        try check(manager.store.load().instances.first { $0.id == a }?.displayUUID == offlineDisplayID, "Disconnected binding persists without changing its display identity")
        let original = originalDisplays[0]
        let relocated = DisplayDescriptor(id: original.id, name: original.name, frame: original.frame.offsetBy(dx: 30, dy: -20), visibleFrame: original.visibleFrame.offsetBy(dx: 30, dy: -20))
        manager.mutate(a) { $0.isVisible = false }
        manager.displayRegistry.testingDisplays = [relocated] + originalDisplays.dropFirst()
        manager.refreshDisplayBindings()
        try check(!manager.record(a)!.controller!.window.isVisible, "Reconnecting a display preserves a user's explicit hidden preference")
        manager.mutate(a) { $0.isVisible = true }
        let frame = manager.record(a)!.controller!.window.frame
        try check(abs(frame.minX - relocated.frame.minX - savedDisplayPosition!.x) < 1 && abs(frame.minY - relocated.frame.minY - savedDisplayPosition!.y) < 1, "Reconnected and reordered display restores the same screen-local position")
        try check(manager.record(a)!.controller!.window.isVisible && manager.record(a)!.settings.displayUUID == offlineDisplayID, "Display reconnection restores visibility without rebinding")
        manager.displayRegistry.testingDisplays = nil
        manager.refreshDisplayBindings()
        try check(manager.record(a)!.settings.displayPosition == savedDisplayPosition, "Returning to actual topology preserves the anchor")
        manager.mutate(b) { $0.animationPaused = false }
        manager.mutate(a) { $0.isVisible = false }
        rememberFrames()
        later(0.6) { try self.hiddenOne() }
    }
    private func hiddenOne() throws {
        try check(try view(a).frames == counters[a], "Hidden instance performs zero draws")
        try check(try view(b).frames > counters[b]!, "Other visible instance keeps drawing")
        let visibility = manager.records.map { $0.settings.isVisible }
        manager.toggleAllHidden()
        try check(manager.records.map { $0.settings.isVisible } == visibility, "Global hide preserves per-instance visibility preferences")
        rememberFrames()
        later(0.5) { try self.hiddenAll() }
    }
    private func hiddenAll() throws {
        for record in manager.records { try check(try view(record.settings.id).frames == counters[record.settings.id], "All hidden: \(record.settings.displayName) zero draws") }
        manager.toggleAllHidden()
        try check(!manager.record(a)!.controller!.window.isVisible && manager.record(b)!.controller!.window.isVisible, "Global restore preserves previously hidden instance")
        manager.mutate(a) { $0.isVisible = true }
        manager.setSleeping(true); rememberFrames()
        later(0.4) { try self.wakeAndActions() }
    }
    private func wakeAndActions() throws {
        for record in manager.records { try check(try view(record.settings.id).frames == counters[record.settings.id], "Sleep notification path suspends instance rendering") }
        manager.setSleeping(false)
        let count = manager.records.count, oldController = manager.record(a)!.controller!
        do { _ = try manager.add(output.appendingPathComponent("missing-model.json")); throw NSError(domain: "test", code: 1) }
        catch { try check(manager.records.count == count, "Invalid add leaves existing instance list intact") }
        do { try manager.replace(a, with: output.appendingPathComponent("missing-model.json")); throw NSError(domain: "test", code: 1) }
        catch { try check(manager.record(a)!.controller === oldController, "Failed replacement preserves previous controller") }
        if let expression = try view(native).bridge.expressionNames.first {
            let before = manager.record(b)!.settings
            manager.setExpression(native, expression: expression)
            try check(manager.record(native)!.settings.expressionId == expression && manager.record(b)!.settings == before, "Native expression selection is instance-local")
        } else { throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Native test model must have expressions"]) }
        manager.play(a, group: "tap", index: 0)
        manager.setIdle(a, group: "idle")
        try testCharacterPicker()
        try testClickInteraction()
        let motion = try view(a).motions.first { $0.group == "idle" }!
        let otherWeights = manager.record(duplicate)!.settings.motionWeightOverrides
        manager.setMotionWeights(a, overrides: [motion.key: 0])
        try check(try view(a).settings.motionWeightOverrides[motion.key] == 0,
                  "Weight edits immediately reach the live view")
        try check(manager.record(duplicate)!.settings.motionWeightOverrides == otherWeights,
                  "Weight overrides remain instance-local")
        manager.save()
        try check(manager.store.load().instances.first { $0.id == a }?.motionWeightOverrides[motion.key] == 0,
                  "Zero weight override persists to disk")
        try check(status.menu.item(at: 0)?.submenu?.items.contains { $0.title == L10n.text("role.settings") } == true &&
                  status.menu.item(at: 0)?.submenu?.items.contains { $0.title == L10n.text("motion.weights") + "…" } == false,
                  "Quick menu links to role settings without detailed motion configuration")
        // Measure the two requested rates on the same fixed-refresh display;
        // the built-in ProMotion panel may adapt its callback rate separately.
        if let display = manager.displayRegistry.primary { manager.bind(b, to: display.id) }
        manager.mutate(a) { $0.animationPaused = false; $0.targetFPS = 30 }
        manager.mutate(b) { $0.targetFPS = 60 }
        later(0.5) { [self] in
            rememberFrames(); fpsStart = ProcessInfo.processInfo.systemUptime
            callbackCounters = [try view(a).displayCallbacks, try view(b).displayCallbacks, try view(a).scheduledFrames, try view(b).scheduledFrames]
            later(3) { try self.measureFPS() }
        }
    }
    private func testCharacterPicker() throws {
        let characters = ["角色甲", "角色乙"].enumerated().map {
            ImportedCharacter(name: $0.element, entry: output, outfitCount: $0.offset + 1)
        }
        let originalLanguage = L10n.language
        defer { LanguageStore.shared.selection = originalLanguage }
        let warnings: [LocalizedMessage] = [.key("error.optional_asset", [.literal("作者资源.png")])]
        let switchLanguage = Timer(timeInterval: 0.25, repeats: false) { _ in
            LanguageStore.shared.selection = .english
        }
        RunLoop.main.add(switchLanguage, forMode: .common)
        func capture(_ name: String) -> Bool {
            guard let window = CharacterPicker.window else { return false }
            let png = output.appendingPathComponent(name)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-o", "-l", String(window.windowNumber), png.path]
            try? process.run(); process.waitUntilExit()
            return FileManager.default.fileExists(atPath: png.path)
        }
        var shotsSaved = 0
        // Multi-select: everything starts selected; unchecking everything disables confirmation.
        let multi = Timer(timeInterval: 0.8, repeats: false) { _ in
            guard let model = CharacterPicker.current else { NSApp.stopModal(); return }
            if capture("character-picker-multi.png") { shotsSaved += 1 }
            model.toggleAll()
            let emptyBlocked = !model.canConfirm
            model.toggleAll(); model.set(0, selected: false)
            let updated = CharacterPicker.window?.title == L10n.text("import.title") && model.title == L10n.text("import.select_add")
            model.finish(emptyBlocked && updated ? model.selection.sorted() : [-1])
        }
        RunLoop.main.add(multi, forMode: .common)
        let chosen = CharacterPicker.run(sourceName: "multi.lpk", characters: characters, warnings: warnings, single: false)
        try check(chosen == [1] && shotsSaved == 1, "Open character picker updates language, preserves selection, blocks empty, and renders")
        // Single-select: exactly one row, first selected, choosing another replaces it.
        let single = Timer(timeInterval: 0.8, repeats: false) { _ in
            guard let model = CharacterPicker.current else { NSApp.stopModal(); return }
            if capture("character-picker-single.png") { shotsSaved += 1 }
            model.set(1, selected: true)
            model.finish(model.canConfirm ? model.selection.sorted() : [-1])
        }
        RunLoop.main.add(single, forMode: .common)
        let replaced = CharacterPicker.run(sourceName: "multi.lpk", characters: characters, warnings: [], single: true)
        try check(replaced == [1] && shotsSaved == 2, "Character picker single-select keeps exactly one character")
        let cancel = Timer(timeInterval: 0.4, repeats: false) { _ in CharacterPicker.current?.cancel() }
        RunLoop.main.add(cancel, forMode: .common)
        try check(CharacterPicker.run(sourceName: "multi.lpk", characters: characters, warnings: [], single: false) == nil,
                  "Character picker cancel returns no selection")
        // The import progress panel is non-modal: show it, capture it, and make sure it closes cleanly.
        let progressModel = ImportProgressModel()
        progressModel.detail = "multi.lpk"
        let progress = ImportProgressPanel.make(model: progressModel)
        progress.makeKeyAndOrderFront(nil)
        later(0.8) { [self] in
            let png = output.appendingPathComponent("import-progress.png")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-o", "-l", String(progress.windowNumber), png.path]
            try? process.run(); process.waitUntilExit()
            let visible = progress.isVisible
            progress.orderOut(nil)
            try check(visible && FileManager.default.fileExists(atPath: png.path), "Import progress panel is visible and renders")
        }
    }
    private func testClickInteraction() throws {
        let record = manager.record(a)!, other = manager.record(duplicate)!
        let original = record.settings, otherOriginal = other.settings
        let nativeOriginal = manager.record(native)!.settings
        defer {
            manager.mutate(a) { $0 = original }; manager.mutate(duplicate) { $0 = otherOriginal }
            manager.mutate(native) { $0 = nativeOriginal }
            manager.setIdle(a, group: original.idleMotionGroup ?? "idle")
            manager.setIdle(duplicate, group: otherOriginal.idleMotionGroup ?? "idle")
        }
        manager.mutate(a) {
            $0.interactionMode = .passthrough; $0.animationPaused = false
            $0.clickInteractionEnabled = true; $0.clickMotionGroup = "idle"
        }
        manager.bringForward(a)
        let model = try view(a), window = record.controller!.window
        guard let frame = model.capture(), let opaque = stride(from: 3, to: frame.data.count, by: 4).filter({ frame.data[$0] == 255 }).min(by: { lhs, rhs in
                  func distance(_ index: Int) -> Double {
                      let x = Double((index / 4) % frame.width) - Double(frame.width) / 2
                      let y = Double((index / 4) / frame.width) - Double(frame.height) / 2
                      return x*x + y*y
                  }
                  return distance(lhs) < distance(rhs)
              }),
              let transparent = stride(from: 3, to: frame.data.count, by: 4).first(where: { frame.data[$0] == 0 }) else {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Hit-test frame needs opaque and transparent pixels"])
        }
        func screenPoint(_ alphaIndex: Int) -> NSPoint {
            let pixel = alphaIndex / 4
            let local = model.convertFromBacking(NSPoint(x: Double(pixel % frame.width) + 0.5, y: Double(pixel / frame.width) + 0.5))
            return window.convertPoint(toScreen: model.convert(local, to: nil))
        }
        let hit = screenPoint(opaque), miss = screenPoint(transparent)
        func click(_ point: NSPoint) {
            manager.handleClick(type: .leftMouseDown, at: point)
            manager.handleClick(type: .leftMouseUp, at: point)
        }
        try check(window.ignoresMouseEvents && model.canClickInteract, "Interaction stays enabled while window always passes clicks through")
        try check(model.containsVisibleModel(at: hit) && !model.containsVisibleModel(at: miss), "Rendered alpha hit-test excludes transparent pixels at backing scale")
        click(miss)
        try check(!model.bridge.interactionPlaying, "Transparent click does not start interaction")
        manager.handleClick(type: .leftMouseDown, at: hit)
        manager.handleClick(type: .leftMouseDragged, at: NSPoint(x: hit.x + 20, y: hit.y))
        manager.handleClick(type: .leftMouseUp, at: hit)
        try check(!model.bridge.interactionPlaying, "Drag returning to original point does not count as click")
        click(hit)
        try check(model.bridge.interactionPlaying && !model.playClickInteraction(), "Arbitrary group plays and repeated interaction cannot interrupt it")
        manager.setIdle(a, group: "idle")
        manager.mutate(a) { $0.animationPaused = true }; click(hit)
        try check(!model.bridge.interactionPlaying, "Paused model ignores clicks")
        manager.mutate(a) { $0.animationPaused = false; $0.interactionMode = .edit }; click(hit)
        try check(!model.bridge.interactionPlaying, "Edit mode ignores interaction")
        manager.mutate(a) { $0.interactionMode = .passthrough; $0.clickMotionGroup = "missing-group" }; click(hit)
        try check(!model.bridge.interactionPlaying && !model.canClickInteract && record.settings.clickMotionGroup == "missing-group", "Unavailable outfit group suspends interaction and preserves selection")
        manager.mutate(a) { $0.clickMotionGroup = "idle" }
        manager.clickInteractionSuspended = true; click(hit); manager.clickInteractionSuspended = false
        try check(!model.bridge.interactionPlaying, "Open menu suppresses interaction")
        manager.setSleeping(true); click(hit); manager.setSleeping(false)
        try check(!model.bridge.interactionPlaying, "Sleeping model ignores clicks")
        manager.toggleAllHidden(); click(hit); manager.toggleAllHidden()
        try check(!model.bridge.interactionPlaying, "Globally hidden models ignore clicks")
        manager.mutate(duplicate) {
            $0.windowFrame = record.settings.windowFrame; $0.displayUUID = record.settings.displayUUID
            $0.displayPosition = record.settings.displayPosition; $0.isVisible = true
            $0.animationPaused = false; $0.interactionMode = .passthrough
            $0.clickInteractionEnabled = true; $0.clickMotionGroup = "idle"
        }
        manager.bringForward(duplicate)
        click(hit)
        try check(try view(duplicate).bridge.interactionPlaying && !model.bridge.interactionPlaying, "Only topmost visible overlapping model responds")
        manager.setIdle(duplicate, group: "idle")
        manager.mutate(duplicate) { $0.clickInteractionEnabled = false }; click(hit)
        try check(!model.bridge.interactionPlaying, "Disabled foreground model blocks interaction with covered model")
        let nativeView = try view(native)
        let group = nativeView.bridge.motionGroups.keys.sorted().first!
        manager.mutate(native) { $0.clickInteractionEnabled = true; $0.clickMotionGroup = group; $0.animationPaused = false; $0.interactionMode = .passthrough }
        try check(nativeView.playClickInteraction() && nativeView.bridge.interactionPlaying && !nativeView.playClickInteraction(), "Native engine supports selected interaction group and repeat suppression")
        for _ in 0..<3000 { nativeView.bridge.step(deltaTime: 0.1, lookX: 0, lookY: 0) }
        try check(!nativeView.bridge.interactionPlaying, "Native interaction finishes and releases lock while idle resumes")
        manager.save()
        try check(manager.store.load().instances.first { $0.id == a }?.clickMotionGroup == "idle", "Click interaction settings persist")
        status.rebuild()
        let menu = status.menu.item(at: 0)?.submenu
        try check(menu?.items.contains { $0.title == L10n.text("role.settings") } == true &&
                  menu?.items.contains { $0.title == L10n.text("click.section") } == false,
                  "Interaction configuration lives in settings rather than the quick menu")
    }
    private func measureFPS() throws {
        let duration = ProcessInfo.processInfo.systemUptime - fpsStart
        let first = Double(try view(a).frames - counters[a]!) / duration
        let second = Double(try view(b).frames - counters[b]!) / duration
        fps = ["A30": first, "B60": second, "seconds": duration]
        fps["A_callbacks"] = Double(try view(a).displayCallbacks - callbackCounters[0]) / duration
        fps["B_callbacks"] = Double(try view(b).displayCallbacks - callbackCounters[1]) / duration
        fps["A_scheduled"] = Double(try view(a).scheduledFrames - callbackCounters[2]) / duration
        fps["B_scheduled"] = Double(try view(b).scheduledFrames - callbackCounters[3]) / duration
        try check(first >= 27 && first <= 33, "A independently schedules approximately 30 FPS")
        try check(second >= 54 && second <= 66, "B independently schedules approximately 60 FPS")
        recordMemory("before-add-remove")
        stressAdd(0)
    }
    private func recordMemory(_ stage: String) {
        let memory = BenchmarkRunner.memory()
        memorySamples.append(["stage": stage, "residentBytes": memory.resident,
                              "physicalFootprintBytes": memory.footprint,
                              "instances": manager.records.count])
    }
    private func stressAdd(_ index: Int) {
        later(0.02) { [self] in
            if index == 30 { later(1) { try self.afterAdds() }; return }
            if index > 0 && index.isMultiple(of: 10) { recordMemory("after-\(index)-add-remove") }
            try autoreleasepool {
                let source = URL(fileURLWithPath: manager.record(a)!.settings.modelPath)
                let added = try manager.add(source, name: "stress")
                let view = added.controller!.view
                removedViews.append(WeakModelView(view))
                later(0.06) { [self] in
                    try check(try self.view(added.settings.id).frames > 0, "Stress instance \(index + 1) renders before removal")
                    manager.remove(added.settings.id)
                    stressAdd(index + 1)
                }
            }
        }
    }
    private func afterAdds() throws {
        recordMemory("after-30-add-remove-settled")
        try check(removedViews.allSatisfy { $0.value == nil }, "30 add/remove cycles release every removed render view")
        try check(manager.records.count == 4, "30 add/remove cycles preserve original four instances")
        stressReplace(0)
    }
    private func stressReplace(_ index: Int) {
        later(0.02) { [self] in
            if index == 20 { later(1) { try self.finishStress() }; return }
            if index > 0 && index.isMultiple(of: 10) { recordMemory("after-\(index)-replace") }
            let unaffected = manager.record(b)!.controller!
            let path = manager.record(index.isMultiple(of: 2) ? b : duplicate)!.settings.modelPath
            try manager.replace(a, with: URL(fileURLWithPath: path))
            try check(manager.record(b)!.controller === unaffected, "Replacement \(index + 1) leaves B controller intact")
            _ = try view(a).capture()
            stressReplace(index + 1)
        }
    }
    private func finishStress() throws {
        recordMemory("after-20-replace-settled")
        for record in manager.records {
            try check(try view(record.settings.id).glErrorCount == 0, "No transient GL errors accumulated for surviving instance")
        }
        for record in manager.records { _ = try capture(record.settings.id, label: "final-\(record.settings.id.uuidString.prefix(4))") }
        manager.mutate(a) {
            $0.displayName = "22 persistent A"; $0.trackingEnabled = false; $0.targetFPS = 30
            $0.clickInteractionEnabled = true; $0.clickMotionGroup = "idle"
        }
        manager.mutate(b) { $0.displayName = "33 persistent B"; $0.trackingEnabled = true; $0.targetFPS = 60; $0.animationPaused = true }
        manager.mutate(duplicate) { $0.displayName = "22 hidden duplicate"; $0.isVisible = false; $0.trackingSmoothingSeconds = 0.3 }
        if let outfit = manager.record(duplicate)?.outfits.dropFirst().first { try manager.setOutfit(duplicate, outfitID: outfit.id) }
        manager.save()
        try JSONEncoder().encode(manager.snapshot()).write(to: output.appendingPathComponent("expected-settings.json"))
        let toRemove = try manager.duplicate(a)!
        manager.remove(toRemove.settings.id); manager.undoRemove()
        try check(manager.record(toRemove.settings.id) != nil, "Removed instance can be restored with undo")
        manager.remove(toRemove.settings.id)
        let saved = manager.snapshot()
        for id in manager.records.map({ $0.settings.id }) { manager.remove(id) }
        status.rebuild()
        try check(manager.records.isEmpty && status.statusItem.button != nil && status.menu.items.count > 4, "Removing last instance leaves menu and add/quit commands alive")
        manager.store.save(saved)
        manager.restore()
        try check(manager.records.map(\.settings) == saved.instances, "All instance descriptors restore after deleting every renderer")
        later(1) { [self] in
            for record in manager.records where record.settings.isVisible {
                _ = try capture(record.settings.id, label: "after-zero-\(record.settings.id.uuidString.prefix(4))")
            }
            recordMemory("after-zero-and-restore-settled")
            SharedMouseTracker.shared.testPoint = nil
            finish(nil)
        }
    }
    func verifyRestored() {
        later(1) { [self] in
            let expected = try JSONDecoder().decode(AppSettings.self, from: Data(contentsOf: output.appendingPathComponent("expected-settings.json")))
            try check(manager.records.map(\.settings) == expected.instances, "Fresh process restores UUIDs, order, names, frames, scale, tracking, FPS, pause, idle and expression state")
            try check(manager.records.count >= 4, "Fresh process restores all independent instance descriptors")
            for record in manager.records {
                if FileManager.default.fileExists(atPath: record.settings.modelPath) {
                    try check(record.controller != nil, "Existing asset restores its renderer")
                    if record.settings.isVisible && manager.isDisplayConnected(record) { _ = try capture(record.settings.id, label: "restored-\(record.settings.id.uuidString.prefix(4))") }
                    else { try check(record.controller?.view.frames == 0 && record.controller?.window.isVisible == false, "Restored hidden or offline-bound instance draws zero frames") }
                } else { try check(record.error != nil && record.controller == nil, "Missing asset is isolated to its own failed descriptor") }
            }
            finish(nil)
        }
    }
    private func finish(_ error: Error?) {
        guard !finished else { return }; finished = true
        SharedMouseTracker.shared.testPoint = nil
        let report: [String: Any] = ["passed": error == nil, "checks": results, "fps": fps, "memorySamples": memorySamples,
                                    "failure": error?.localizedDescription ?? "", "instances": manager.records.count]
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent(error == nil ? "passed.json" : "failed.json"))
        NSLog("SELF_TEST %@ checks=%d %@", error == nil ? "PASS" : "FAIL", results.count, error?.localizedDescription ?? "")
        complete(error == nil ? 0 : 1)
    }
}
