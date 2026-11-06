import AppKit

/// A nonactivating, click-through window containing one character's recent sentences.
final class CompanionBubble {
    let panel: NSPanel
    private let content = BubbleDragView()
    private var rows: [(text: String, view: NSView, size: NSSize)] = []
    private var limit = 3
    private var avatar: NSImage?
    var offset = NSPoint.zero
    var onMoved: (() -> Void)?
    var sentenceCount: Int { rows.count }
    var displayedTexts: [String] { rows.map(\.text) }
    init(preview: Bool = false) {
        panel = preview ? BubblePreviewPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            : NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .floating; panel.ignoresMouseEvents = !preview; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        content.wantsLayer = true; content.autoresizesSubviews = false
        content.onMoved = { [weak self] in self?.onMoved?() }
        panel.contentView = content
    }
    func configure(limit: Int, avatar: NSImage?) {
        self.limit = min(max(limit, 1), 6); self.avatar = avatar
        let texts = rows.suffix(self.limit).map(\.text)
        rows.forEach { $0.view.removeFromSuperview() }; rows.removeAll()
        texts.forEach { append($0) }
        layout(animated: false)
    }
    func show(name: String, text: String, near window: NSWindow) {
        append(text)
        while rows.count > limit {
            let old = rows.removeFirst().view
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18; old.animator().alphaValue = 0
            } completionHandler: { old.removeFromSuperview() }
        }
        layout(animated: panel.isVisible)
        position(near: window); panel.orderFrontRegardless()
    }
    private func append(_ text: String) {
        let font = NSFont.systemFont(ofSize: 14)
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = font; label.textColor = .labelColor
        // NSTextField cells add their own horizontal inset. Include it before
        // measuring wrapping, otherwise the last few characters land on a clipped line.
        let rect = (text as NSString).boundingRect(with: NSSize(width: 212, height: 2000), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
        let width = max(48, min(240, ceil(rect.width) + 28))
        let labelHeight = ceil(label.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: width - 24, height: 2000)).height)
        let height = max(36, labelHeight + 20)
        let avatarSpace: CGFloat = avatar == nil ? 0 : 44
        let row = NSView(frame: NSRect(x: 0, y: 0, width: avatarSpace + width + 6, height: height))
        row.wantsLayer = true
        let effect = NSVisualEffectView(frame: NSRect(x: avatarSpace, y: 0, width: width + 6, height: height))
        effect.material = .popover; effect.blendingMode = .behindWindow; effect.state = .active
        effect.wantsLayer = true
        // A single mask gives the body and iMessage-style curved tail the same blur.
        let path = CGMutablePath()
        path.addRoundedRect(in: CGRect(x: 6, y: 4, width: width, height: height - 4), cornerWidth: 17, cornerHeight: 17)
        path.move(to: CGPoint(x: 10, y: 20))
        path.addCurve(to: CGPoint(x: 0, y: 0), control1: CGPoint(x: 10, y: 8), control2: CGPoint(x: 6, y: 3))
        path.addCurve(to: CGPoint(x: 26, y: 7), control1: CGPoint(x: 11, y: -1), control2: CGPoint(x: 19, y: 2))
        path.closeSubpath()
        let mask = CAShapeLayer(); mask.path = path; effect.layer?.mask = mask
        label.frame = NSRect(x: 18, y: 12, width: width - 24, height: height - 20)
        effect.addSubview(label); row.addSubview(effect)
        if let avatar {
            let image = NSImageView(frame: NSRect(x: 0, y: 0, width: 34, height: 34))
            image.image = avatar; image.imageScaling = .scaleProportionallyUpOrDown
            image.wantsLayer = true; image.layer?.cornerRadius = 17; image.layer?.masksToBounds = true
            row.addSubview(image)
        }
        content.addSubview(row)
        rows.append((text, row, NSSize(width: avatarSpace + width + 6, height: height)))
    }
    private func layout(animated: Bool) {
        let width = rows.map(\.size.width).max() ?? 0
        let height = rows.reduce(CGFloat(0)) { $0 + $1.size.height } + CGFloat(max(0, rows.count - 1)) * 8
        panel.setContentSize(NSSize(width: ceil(width / 2) * 2, height: ceil(height)))
        var y = height
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated ? 0.2 : 0
            for row in rows {
                y -= row.size.height
                let frame = NSRect(x: 0, y: y, width: row.size.width, height: row.size.height)
                if animated { row.view.animator().setFrameOrigin(frame.origin) }
                else { row.view.frame = frame }
                y -= 8
            }
        }
    }
    func position(near window: NSWindow) {
        guard let screen = window.screen, let base = baseOrigin(near: window) else { hide(); return }
        let area = screen.visibleFrame, size = panel.frame.size
        let x = min(max(base.x + offset.x, area.minX + 8), area.maxX - size.width - 8)
        let y = min(max(base.y + offset.y, area.minY + 8), area.maxY - size.height - 8)
        panel.setFrameOrigin(NSPoint(x: x.rounded(), y: y.rounded()))
    }
    func baseOrigin(near window: NSWindow) -> NSPoint? {
        guard window.screen != nil else { return nil }
        return NSPoint(x: window.frame.midX - panel.frame.width / 2, y: window.frame.maxY + 8)
    }
    func hide() {
        panel.orderOut(nil)
        rows.forEach { $0.view.removeFromSuperview() }; rows.removeAll()
    }
}

private final class BubblePreviewPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
private final class BubbleDragView: NSView {
    private var startMouse: NSPoint?
    private var startOrigin: NSPoint?
    var onMoved: (() -> Void)?
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(point) ? self : nil }
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
