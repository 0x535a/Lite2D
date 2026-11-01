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
            later(0.35) { try self.afterNativeDuplicate() }
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
            try check(twin.settings.id != a && twin.settings.modelPath == manager.record(a)!.settings.modelPath, "Duplicate asset has a new UUID")
            try check(twin.controller!.view.bridge !== manager.record(a)!.controller!.view.bridge, "Duplicate asset has an independent engine bridge")
            later(0.35) { try self.beginTracking() }
    }
    private func beginTracking() throws {
            _ = try capture(duplicate, label: "duplicate-22")
            status.rebuild()
            try check(status.menu.item(at: 1)?.submenu?.items.count == 4, "Status menu lists all four instance submenus")
            manager.mutate(a) { $0.animationPaused = true; $0.trackingEnabled = false; $0.targetFPS = 30 }
            manager.mutate(b) { $0.animationPaused = true; $0.trackingEnabled = true; $0.targetFPS = 60 }
            frozenTime = try view(a).animationTime; nativeTime = try view(native).animationTime
            let window = manager.record(b)!.controller!.window
            SharedMouseTracker.shared.testPoint = NSPoint(x: window.frame.minX - 400, y: window.frame.maxY + 200)
            later(1) { try self.leftLook() }
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
            controller.window.setFrameOrigin(NSPoint(x: screen.visibleFrame.minX + 20, y: screen.visibleFrame.minY + 20))
            let point = NSPoint(x: screen.frame.midX, y: screen.frame.midY)
            let local = controller.window.convertPoint(fromScreen: point)
            let roundTrip = controller.window.convertPoint(toScreen: local)
            try check(abs(roundTrip.x - point.x) < 0.01 && abs(roundTrip.y - point.y) < 0.01, "Coordinate conversion round trip: \(screen.localizedName)")
        }
        let displaced = manager.record(a)!.controller!
        displaced.window.setFrameOrigin(NSPoint(x: 500_000, y: 500_000))
        manager.record(a)!.settings.windowFrame = WindowFrame(displaced.window.frame)
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        try check(NSScreen.screens.contains { displaced.window.frame.intersection($0.visibleFrame).width >= 80 && displaced.window.frame.intersection($0.visibleFrame).height >= 80 }, "Screen-change notification recovers an offscreen instance into a visible screen")
        manager.resetPosition(a)
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
        manager.mutate(a) { $0.animationPaused = false; $0.targetFPS = 30 }
        manager.mutate(b) { $0.targetFPS = 60 }
        later(0.5) { [self] in
            rememberFrames(); fpsStart = ProcessInfo.processInfo.systemUptime
            callbackCounters = [try view(a).displayCallbacks, try view(b).displayCallbacks, try view(a).scheduledFrames, try view(b).scheduledFrames]
            later(2) { try self.measureFPS() }
        }
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
        try check(first >= 22 && first <= 38, "A independently schedules approximately 30 FPS")
        try check(second >= 44 && second <= 75, "B independently schedules approximately 60 FPS")
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
        manager.mutate(a) { $0.displayName = "22 persistent A"; $0.trackingEnabled = false; $0.targetFPS = 30 }
        manager.mutate(b) { $0.displayName = "33 persistent B"; $0.trackingEnabled = true; $0.targetFPS = 60; $0.animationPaused = true }
        manager.mutate(duplicate) { $0.displayName = "22 hidden duplicate"; $0.isVisible = false; $0.trackingSmoothingSeconds = 0.3 }
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
                    if record.settings.isVisible { _ = try capture(record.settings.id, label: "restored-\(record.settings.id.uuidString.prefix(4))") }
                    else { try check(record.controller?.view.frames == 0, "Restored hidden instance draws zero frames") }
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
