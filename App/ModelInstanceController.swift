import AppKit

final class PetWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class ModelRecord {
    var settings: ModelInstanceSettings
    var controller: ModelInstanceController?
    var error: String?
    var outfits: [ModelOutfit] = []
    init(_ settings: ModelInstanceSettings) { self.settings = settings }
}

final class ModelInstanceController: NSObject {
    unowned let record: ModelRecord
    let window: PetWindow
    let view: OpenGLModelView
    var onZoomRequested: ((Double) -> Void)?
    var onUserMoved: ((NSRect) -> Void)?

    init(record: ModelRecord) throws {
        self.record = record
        guard let view = OpenGLModelView(settings: record.settings) else {
            throw NSError(domain: "Lite2D", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法创建 OpenGL context。"])
        }
        record.outfits = (try? ModelOutfitCatalog.load(URL(fileURLWithPath: record.settings.modelPath))) ?? []
        self.view = view
        window = PetWindow(contentRect: record.settings.windowFrame.rect, styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = view
        do { try view.load() }
        catch { view.shutdown(); window.close(); throw error }
        view.onZoom = { [weak self] factor in self?.onZoomRequested?(factor) }
        view.onDragFinished = { [weak self] frame in self?.onUserMoved?(frame) }
        // The manager decides visibility after resolving the bound display.
        // A disconnected binding must never flash onto the primary screen.
    }
    func apply(visible: Bool, sleeping: Bool = false) {
        let changedFPS = view.settings.targetFPS != record.settings.targetFPS
        view.settings = record.settings
        if changedFPS { view.applyFPS() }
        window.title = record.settings.displayName
        window.ignoresMouseEvents = record.settings.interactionMode != .edit
        view.setActive(visible && !sleeping)
        if visible {
            if !window.isVisible { window.orderFrontRegardless() }
        } else if window.isVisible { window.orderOut(nil) }
    }
    func setLayoutFrame(_ frame: NSRect) {
        if window.frame != frame { window.setFrame(frame, display: false) }
    }
    func shutdown() {
        view.shutdown()
        window.orderOut(nil); window.contentView = nil; window.close()
        onZoomRequested = nil; onUserMoved = nil
    }
}
