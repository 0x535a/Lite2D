import AppKit

final class ModelInstanceManager {
    let store: SettingsStore
    private(set) var records: [ModelRecord] = []
    private(set) var allHidden = false
    private(set) var sleeping = false
    private(set) var removedSettings: ModelInstanceSettings?
    var onChange: (() -> Void)?
    private var notifications: [NSObjectProtocol] = []

    init(store: SettingsStore = SettingsStore()) {
        self.store = store
        let workspace = NSWorkspace.shared.notificationCenter
        notifications.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.setSleeping(true) })
        notifications.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.setSleeping(false) })
        notifications.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.recoverOffscreenWindows() })
    }
    func restore() {
        for settings in store.load().instances {
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
        recoverOffscreenWindows()
        for record in records.sorted(by: { $0.settings.zOrder < $1.settings.zOrder }) {
            if record.settings.isVisible { record.controller?.window.orderFrontRegardless() }
        }
        onChange?()
    }
    private func load(_ record: ModelRecord) {
        do {
            record.controller = try ModelInstanceController(record: record)
            record.error = nil
            record.controller?.onChange = { [weak self] in self?.changed() }
            apply(record)
        } catch { record.error = error.localizedDescription; record.controller = nil; NSLog("模型载入失败：%@", error.localizedDescription) }
    }
    func record(_ id: UUID) -> ModelRecord? { records.first { $0.settings.id == id } }
    private func uniqueName(_ base: String) -> String {
        let names = Set(records.map { $0.settings.displayName })
        if !names.contains(base) { return base }
        var number = 2
        while names.contains("\(base) (\(number))") { number += 1 }
        return "\(base) (\(number))"
    }
    @discardableResult func add(_ url: URL, name: String? = nil) throws -> ModelRecord {
        let checked = try ModelFileValidator.validate(url)
        let base = name ?? url.deletingLastPathComponent().lastPathComponent
        var settings = ModelInstanceSettings(displayName: uniqueName(base), modelPath: checked.url.path)
        let origin = NSScreen.main?.visibleFrame.origin ?? .zero
        let offset = Double(records.count % 6) * 55
        settings.windowFrame = WindowFrame(NSRect(x: origin.x + 80 + offset, y: origin.y + 60 + offset, width: 360, height: 480))
        settings.zOrder = (records.map { $0.settings.zOrder }.max() ?? -1) + 1
        let record = ModelRecord(settings)
        // Commit to the instance list only after all engine/GPU loading succeeds.
        let controller = try ModelInstanceController(record: record)
        record.controller = controller
        controller.onChange = { [weak self] in self?.changed() }
        records.append(record); apply(record); changed()
        return record
    }
    @discardableResult func duplicate(_ id: UUID) throws -> ModelRecord? {
        guard let source = record(id) else { return nil }
        var settings = source.settings
        settings.id = UUID(); settings.displayName = uniqueName(source.settings.displayName)
        settings.windowFrame.x += 45; settings.windowFrame.y += 35
        settings.interactionMode = .passthrough
        settings.zOrder = (records.map { $0.settings.zOrder }.max() ?? -1) + 1
        let next = ModelRecord(settings)
        let controller = try ModelInstanceController(record: next)
        next.controller = controller; controller.onChange = { [weak self] in self?.changed() }
        records.append(next); apply(next); changed(); return next
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
        settings.idleMotionGroup = nil; settings.expressionId = nil
        let replacement = ModelRecord(settings)
        let controller = try ModelInstanceController(record: replacement)
        replacement.controller = controller
        controller.onChange = { [weak self] in self?.changed() }
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
        controller.view.openGLContext?.makeCurrentContext()
        _ = controller.view.bridge.play(group: group, index: Int32(index))
    }
    func setIdle(_ id: UUID, group: String) {
        guard let record = record(id) else { return }
        record.settings.idleMotionGroup = group
        record.controller?.view.bridge.setIdleGroup(group); changed()
    }
    func setExpression(_ id: UUID, expression: String) {
        guard let record = record(id), let controller = record.controller else { return }
        controller.view.openGLContext?.makeCurrentContext()
        if controller.view.bridge.selectExpression(expression) {
            record.settings.expressionId = expression.isEmpty ? nil : expression; changed()
        }
    }
    func zoom(_ id: UUID, factor: Double) { record(id)?.controller?.zoom(by: factor) }
    func bringForward(_ id: UUID) {
        guard let record = record(id) else { return }
        record.settings.zOrder = (records.map { $0.settings.zOrder }.max() ?? 0) + 1
        if record.settings.isVisible && !allHidden { record.controller?.window.orderFrontRegardless() }
        changed()
    }
    func resetPosition(_ id: UUID) {
        guard let record = record(id), let window = record.controller?.window, let screen = NSScreen.main else { return }
        let bounds = screen.visibleFrame
        window.setFrameOrigin(NSPoint(x: bounds.minX + 60, y: bounds.minY + 50))
        record.settings.windowFrame = WindowFrame(window.frame); changed()
    }
    func recoverOffscreenWindows() {
        let screens = NSScreen.screens.map(\.visibleFrame)
        for record in records {
            let rect = record.settings.windowFrame.rect
            if !screens.contains(where: { rect.intersection($0).width >= 80 && rect.intersection($0).height >= 80 }) {
                resetPosition(record.settings.id)
            }
        }
    }
    func toggleAllHidden() { allHidden.toggle(); for record in records { apply(record) }; onChange?() }
    func setSleeping(_ value: Bool) { sleeping = value; for record in records { apply(record) } }
    private func apply(_ record: ModelRecord) {
        record.controller?.apply(visible: !allHidden && record.settings.isVisible, sleeping: sleeping)
    }
    func snapshot() -> AppSettings {
        var settings = AppSettings(); settings.instances = records.map(\.settings); return settings
    }
    func changed() { store.schedule(snapshot()); onChange?() }
    func save() { store.save(snapshot()) }
    func shutdown() {
        save()
        for record in records { record.controller?.shutdown(); record.controller = nil }
        for token in notifications { NotificationCenter.default.removeObserver(token); NSWorkspace.shared.notificationCenter.removeObserver(token) }
        notifications = []
    }
}
