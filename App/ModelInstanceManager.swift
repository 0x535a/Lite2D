import AppKit

final class ModelInstanceManager {
    var companion: CompanionCoordinator?
    let store: SettingsStore
    let displayRegistry: DisplayRegistry
    private(set) var records: [ModelRecord] = []
    private(set) var allHidden = false
    private(set) var sleeping = false
    private(set) var removedSettings: ModelInstanceSettings?
    var onChange: (() -> Void)?
    private var notifications: [NSObjectProtocol] = []
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var clickStart: (id: UUID, point: NSPoint)?
    var clickInteractionSuspended = false {
        didSet { if clickInteractionSuspended { clickStart = nil } }
    }

    init(store: SettingsStore = SettingsStore(), displayRegistry: DisplayRegistry = DisplayRegistry()) {
        self.store = store
        self.displayRegistry = displayRegistry
        let workspace = NSWorkspace.shared.notificationCenter
        notifications.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.setSleeping(true) })
        notifications.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.setSleeping(false) })
        notifications.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.refreshDisplayBindings() })
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp, .leftMouseDragged]
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] event in
            self?.handleClickEvent(event)
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak self] event in
            // App menus and dialogs must not interact with models behind them.
            if event.window != nil && !(event.window is PetWindow) { self?.clickStart = nil }
            else { self?.handleClickEvent(event) }
            return event
        }
    }
    private func handleClickEvent(_ event: NSEvent) {
        let point = event.window.map { $0.convertPoint(toScreen: event.locationInWindow) } ?? NSEvent.mouseLocation
        handleClick(type: event.type, at: point)
    }
    // Shared by passive OS monitors and self-tests; never consumes or posts events.
    func handleClick(type: NSEvent.EventType, at point: NSPoint) {
        guard !clickInteractionSuspended, !sleeping, !allHidden, NSApp.modalWindow == nil else {
            clickStart = nil; return
        }
        switch type {
        case .leftMouseDown:
            clickStart = nil
            guard records.contains(where: { $0.controller?.view.canClickInteract == true }),
                  let record = clickedModel(at: point), record.controller?.view.canClickInteract == true else { return }
            clickStart = (record.settings.id, point)
        case .leftMouseDragged:
            if let start = clickStart, hypot(point.x - start.point.x, point.y - start.point.y) > 4 { clickStart = nil }
        case .leftMouseUp:
            let start = clickStart; clickStart = nil
            guard let start, hypot(point.x - start.point.x, point.y - start.point.y) <= 4,
                  let record = clickedModel(at: point), record.settings.id == start.id else { return }
            record.controller?.view.playClickInteraction()
        default: break
        }
    }
    private func clickedModel(at point: NSPoint) -> ModelRecord? {
        // Actual window order also covers edits and disabled models occluding
        // an enabled model. Transparent pixels allow the next model to respond.
        for window in NSApp.orderedWindows {
            guard let record = records.first(where: { $0.controller?.window === window }),
                  record.controller?.view.containsVisibleModel(at: point) == true else { continue }
            return record
        }
        return nil
    }
    func restore() {
        for var settings in store.load().instances {
            preparePlacement(&settings)
            let record = ModelRecord(settings)
            records.append(record)
            load(record)
        }
        // Only one instance resumes editing; all other independent state stays.
        var edited = false
        for record in records where record.settings.interactionMode == .edit {
            if edited { record.settings.interactionMode = .passthrough; apply(record) }
            edited = true
        }
        refreshDisplayBindings()
        onChange?()
    }
    private func load(_ record: ModelRecord) {
        do {
            record.controller = try ModelInstanceController(record: record)
            record.error = nil
            configure(record)
            apply(record)
        } catch { record.error = error; record.controller = nil; NSLog("模型载入失败：%@", error.localizedDescription) }
    }
    func record(_ id: UUID) -> ModelRecord? { records.first { $0.settings.id == id } }
    private func configure(_ record: ModelRecord) {
        let id = record.settings.id
        record.controller?.onZoomRequested = { [weak self] factor in self?.zoom(id, factor: factor) }
        record.controller?.onUserMoved = { [weak self] frame in self?.move(id, to: frame) }
    }
    private func preparePlacement(_ settings: inout ModelInstanceSettings) {
        let displays = displayRegistry.displays
        if settings.displayBindingVersion == 0 {
            // Legacy global frames have no physical identity. Infer only an
            // intersecting connected display once; never move an unknown frame
            // to the primary display as a fallback.
            if let display = DisplayLayout.matching(settings.windowFrame.rect, in: displays) {
                settings.displayUUID = display.id; settings.boundDisplayName = display.name
                settings.displayPosition = DisplayPosition(x: settings.windowFrame.x - display.frame.minX,
                                                          y: settings.windowFrame.y - display.frame.minY)
            }
            settings.displayBindingVersion = 1
        }
        if let id = settings.displayUUID, let display = displays.first(where: { $0.id == id }) {
            if settings.displayPosition == nil {
                settings.displayPosition = DisplayPosition(x: settings.windowFrame.x - display.frame.minX,
                                                          y: settings.windowFrame.y - display.frame.minY)
            }
            settings.boundDisplayName = display.name
        }
        if let frame = DisplayLayout.windowFrame(for: settings, in: displays) { settings.windowFrame = WindowFrame(frame) }
    }
    func isDisplayConnected(_ record: ModelRecord) -> Bool {
        DisplayLayout.windowFrame(for: record.settings, in: displayRegistry.displays) != nil
    }
    func bind(_ id: UUID, to displayID: String) {
        guard let record = record(id), let display = displayRegistry.displays.first(where: { $0.id == displayID }) else { return }
        record.settings.displayUUID = display.id; record.settings.boundDisplayName = display.name
        record.settings.displayBindingVersion = 1
        if record.settings.displayPosition == nil {
            record.settings.displayPosition = DisplayPosition(x: display.visibleFrame.minX - display.frame.minX + 60,
                                                             y: display.visibleFrame.minY - display.frame.minY + 50)
        }
        apply(record); changed()
    }
    func move(_ id: UUID, to frame: NSRect) {
        guard let record = record(id) else { return }
        if let display = DisplayLayout.matching(frame, in: displayRegistry.displays) {
            record.settings.displayUUID = display.id; record.settings.boundDisplayName = display.name
            record.settings.displayBindingVersion = 1
            record.settings.displayPosition = DisplayPosition(x: frame.minX - display.frame.minX,
                                                             y: frame.minY - display.frame.minY)
        } else if let oldPosition = record.settings.displayPosition {
            record.settings.displayPosition = DisplayPosition(x: oldPosition.x + frame.minX - record.settings.windowFrame.x,
                                                             y: oldPosition.y + frame.minY - record.settings.windowFrame.y)
        }
        record.settings.windowFrame = WindowFrame(frame)
        apply(record); changed()
    }
    private func uniqueName(_ base: String) -> String {
        let names = Set(records.map { $0.settings.localizedDisplayName })
        if !names.contains(base) { return base }
        var number = 2
        while names.contains("\(base) (\(number))") { number += 1 }
        return "\(base) (\(number))"
    }
    @discardableResult func add(_ url: URL, name: String? = nil, generatedName: GeneratedName? = nil) throws -> ModelRecord {
        let checked = try ModelFileValidator.validate(url)
        let base = name ?? url.deletingLastPathComponent().lastPathComponent
        var settings = ModelInstanceSettings(displayName: uniqueName(base), modelPath: checked.url.path)
        if var generatedName {
            let localized = generatedName.text
            let unique = uniqueName(localized)
            let suffix = String(unique.dropFirst(localized.count))
            settings.displayName = base + suffix
            generatedName.suffix += suffix
            settings.generatedName = generatedName
        }
        let display = displayRegistry.primary
        let origin = display?.visibleFrame.origin ?? .zero
        let offset = Double(records.count % 6) * 55
        settings.windowFrame = WindowFrame(NSRect(x: origin.x + 80 + offset, y: origin.y + 60 + offset, width: 360, height: 480))
        if let display {
            settings.displayUUID = display.id; settings.boundDisplayName = display.name
            settings.displayPosition = DisplayPosition(x: settings.windowFrame.x - display.frame.minX,
                                                      y: settings.windowFrame.y - display.frame.minY)
        }
        settings.zOrder = (records.map { $0.settings.zOrder }.max() ?? -1) + 1
        let record = ModelRecord(settings)
        // Commit to the instance list only after all engine/GPU loading succeeds.
        let controller = try ModelInstanceController(record: record)
        record.controller = controller
        records.append(record); configure(record); apply(record); changed()
        return record
    }
    @discardableResult func duplicate(_ id: UUID) throws -> ModelRecord? {
        guard let source = record(id) else { return nil }
        var settings = source.settings
        settings.id = UUID()
        let localized = source.settings.localizedDisplayName
        let unique = uniqueName(localized)
        if var generatedName = source.settings.generatedName {
            let suffix = String(unique.dropFirst(localized.count))
            settings.displayName = source.settings.displayName + suffix
            generatedName.suffix += suffix
            settings.generatedName = generatedName
        } else { settings.displayName = unique }
        settings.windowFrame.x += 45; settings.windowFrame.y += 35
        if let position = settings.displayPosition {
            settings.displayPosition = DisplayPosition(x: position.x + 45, y: position.y + 35)
        }
        settings.interactionMode = .passthrough
        settings.zOrder = (records.map { $0.settings.zOrder }.max() ?? -1) + 1
        let next = ModelRecord(settings)
        let controller = try ModelInstanceController(record: next)
        next.controller = controller
        records.append(next); configure(next); apply(next); changed(); return next
    }
    func remove(_ id: UUID) {
        guard let index = records.firstIndex(where: { $0.settings.id == id }) else { return }
        let record = records[index]
        removedSettings = record.settings
        // All scheduling/drawing occurs on the main thread; invalidating the
        // display link here cannot race another render callback.
        record.controller?.shutdown(); record.controller = nil
        records.remove(at: index); changed()
    }
    func undoRemove() {
        guard var settings = removedSettings else { return }
        if record(settings.id) != nil { settings.id = UUID() }
        let record = ModelRecord(settings); records.append(record); load(record)
        removedSettings = nil; changed()
    }
    func replace(_ id: UUID, with url: URL) throws {
        guard let old = record(id) else { return }
        let valid = try ModelFileValidator.validate(url)
        var settings = old.settings
        settings.modelPath = valid.url.path
        settings.motionWeightOverrides = [:]
        settings.idleMotionGroup = nil; settings.expressionId = nil; settings.outfitID = nil
        settings.clickInteractionEnabled = false; settings.clickMotionGroup = nil
        let replacement = ModelRecord(settings)
        let controller = try ModelInstanceController(record: replacement)
        replacement.controller = controller
        configure(replacement)
        guard let index = records.firstIndex(where: { $0.settings.id == id }) else { controller.shutdown(); return }
        old.controller?.shutdown(); old.controller = nil
        records[index] = replacement
        apply(replacement); changed()
    }
    func mutate(_ id: UUID, _ change: (inout ModelInstanceSettings) -> Void) {
        guard let record = record(id) else { return }
        change(&record.settings); record.settings.sanitize(); apply(record); changed()
    }
    func edit(_ id: UUID) {
        guard let selected = record(id) else { return }
        let next = selected.settings.interactionMode == .edit ? InteractionMode.passthrough : .edit
        if next == .edit {
            for other in records where other.settings.id != id && other.settings.interactionMode == .edit {
                other.settings.interactionMode = .passthrough; apply(other)
            }
        }
        selected.settings.interactionMode = next; apply(selected)
        if next == .edit { bringForward(id) }
        changed()
    }
    func play(_ id: UUID, group: String, index: Int) {
        guard let controller = record(id)?.controller else { return }
        controller.view.manualMotionUntil = Date().addingTimeInterval(10)
        controller.view.openGLContext?.makeCurrentContext()
        _ = controller.view.bridge.play(group: group, index: Int32(index))
    }
    func setIdle(_ id: UUID, group: String) {
        guard let record = record(id) else { return }
        record.settings.idleMotionGroup = group
        apply(record)
        record.controller?.view.bridge.setIdleGroup(group); changed()
    }
    func setMotionWeights(_ id: UUID, overrides: [String: Double]) {
        mutate(id) { $0.motionWeightOverrides = overrides }
        record(id)?.controller?.view.applyMotionWeights()
    }
    func setOutfit(_ id: UUID, outfitID: String) throws {
        guard let record = record(id) else { return }
        let entry = URL(fileURLWithPath: record.settings.modelPath)
        let outfits = try ModelOutfitCatalog.load(entry)
        let selected = try ModelOutfitCatalog.selectedURL(entry: entry, outfitID: outfitID, outfits: outfits)
        if let controller = record.controller {
            // Bridge loading is transactional: failed validation/decoding keeps the old engine.
            try controller.view.loadEntry(selected)
            record.settings.outfitID = outfitID.isEmpty ? nil : outfitID
            record.outfits = outfits
            apply(record)
        } else {
            var settings = record.settings
            settings.outfitID = outfitID.isEmpty ? nil : outfitID
            let replacement = ModelRecord(settings)
            replacement.controller = try ModelInstanceController(record: replacement)
            guard let index = records.firstIndex(where: { $0.settings.id == id }) else {
                replacement.controller?.shutdown(); return
            }
            records[index] = replacement; configure(replacement); apply(replacement)
        }
        changed()
    }
    func setExpression(_ id: UUID, expression: String) {
        guard let record = record(id), let controller = record.controller else { return }
        controller.view.openGLContext?.makeCurrentContext()
        if controller.view.bridge.selectExpression(expression) {
            record.settings.expressionId = expression.isEmpty ? nil : expression; changed()
        }
    }
    func zoom(_ id: UUID, factor: Double) {
        guard let record = record(id) else { return }
        let previous = record.settings.windowFrame.rect
        let resized = ZoomGeometry.resize(frame: previous, currentScale: record.settings.scale, factor: factor)
        record.settings.scale = resized.scale
        record.settings.windowFrame = WindowFrame(resized.frame)
        if let position = record.settings.displayPosition {
            record.settings.displayPosition = DisplayPosition(x: position.x + resized.frame.minX - previous.minX,
                                                             y: position.y + resized.frame.minY - previous.minY)
        }
        apply(record); changed()
    }
    func bringForward(_ id: UUID) {
        guard let record = record(id) else { return }
        record.settings.zOrder = (records.map { $0.settings.zOrder }.max() ?? 0) + 1
        if record.settings.isVisible && !allHidden && isDisplayConnected(record) { record.controller?.window.orderFrontRegardless() }
        changed()
    }
    func resetPosition(_ id: UUID) {
        guard let record = record(id) else { return }
        if let display = displayRegistry.displays.first(where: { $0.id == record.settings.displayUUID }) {
            record.settings.displayPosition = DisplayPosition(x: display.visibleFrame.minX - display.frame.minX + 60,
                                                             y: display.visibleFrame.minY - display.frame.minY + 50)
        } else { record.settings.displayPosition = DisplayPosition(x: 60, y: 50) }
        apply(record); changed()
    }
    func refreshDisplayBindings() {
        for record in records { apply(record) }
        restoreStacking()
        changed()
    }
    private func restoreStacking() {
        guard !allHidden else { return }
        for record in records.sorted(by: { $0.settings.zOrder < $1.settings.zOrder }) {
            if record.settings.isVisible && isDisplayConnected(record) { record.controller?.window.orderFrontRegardless() }
        }
    }
    func toggleAllHidden() { allHidden.toggle(); for record in records { apply(record) }; restoreStacking(); onChange?() }
    func setSleeping(_ value: Bool) { sleeping = value; for record in records { apply(record) } }
    private func apply(_ record: ModelRecord) {
        let displayFrame = DisplayLayout.windowFrame(for: record.settings, in: displayRegistry.displays)
        if let frame = displayFrame {
            if let display = displayRegistry.displays.first(where: { $0.id == record.settings.displayUUID }) {
                record.settings.boundDisplayName = display.name
            }
            record.settings.windowFrame = WindowFrame(frame)
            record.controller?.setLayoutFrame(frame)
        }
        record.controller?.apply(visible: displayFrame != nil && !allHidden && record.settings.isVisible, sleeping: sleeping)
    }
    func snapshot() -> AppSettings {
        var settings = AppSettings(); settings.instances = records.map(\.settings); return settings
    }
    func changed() { store.schedule(snapshot()); onChange?() }
    func save() { store.save(snapshot()) }
    func shutdown() {
        companion?.shutdown()
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        globalClickMonitor = nil; localClickMonitor = nil; clickStart = nil
        save()
        for record in records { record.controller?.shutdown(); record.controller = nil }
        for token in notifications { NotificationCenter.default.removeObserver(token); NSWorkspace.shared.notificationCenter.removeObserver(token) }
        notifications = []
    }
}
