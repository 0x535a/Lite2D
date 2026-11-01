import AppKit

final class PetWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class ModelRecord {
    var settings: ModelInstanceSettings
    var controller: ModelInstanceController?
    var error: String?
    init(_ settings: ModelInstanceSettings) { self.settings = settings }
}

final class ModelInstanceController: NSObject, NSWindowDelegate {
    unowned let record: ModelRecord
    let window: PetWindow
    let view: OpenGLModelView
    var onChange: (() -> Void)?
    private var closing = false

    init(record: ModelRecord) throws {
        self.record = record
        guard let view = OpenGLModelView(settings: record.settings) else {
            throw NSError(domain: "Lite2D", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法创建 OpenGL context。"])
        }
        self.view = view
        window = PetWindow(contentRect: record.settings.windowFrame.rect, styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = view
        window.delegate = self
        do { try view.load() }
        catch { view.shutdown(); window.delegate = nil; window.close(); throw error }
        view.onZoom = { [weak self] factor in self?.zoom(by: factor) }
        apply(visible: record.settings.isVisible)
    }
    func apply(visible: Bool, sleeping: Bool = false) {
        view.settings = record.settings
        view.applyFPS()
        window.title = record.settings.displayName
        window.ignoresMouseEvents = record.settings.interactionMode != .edit
        view.setActive(visible && !sleeping)
        if visible { window.orderFrontRegardless() } else { window.orderOut(nil) }
    }
    func zoom(by factor: Double) {
        let resized = ZoomGeometry.resize(frame: window.frame, currentScale: record.settings.scale, factor: factor)
        record.settings.scale = resized.scale
        window.setFrame(resized.frame, display: true)
        record.settings.windowFrame = WindowFrame(window.frame)
        view.settings = record.settings
        onChange?()
    }
    func windowDidMove(_ notification: Notification) { saveFrame() }
    func windowDidResize(_ notification: Notification) { saveFrame() }
    private func saveFrame() {
        guard !closing else { return }
        record.settings.windowFrame = WindowFrame(window.frame)
        onChange?()
    }
    func shutdown() {
        closing = true
        view.shutdown()
        window.delegate = nil
        window.orderOut(nil); window.contentView = nil; window.close()
        onChange = nil
    }
}
