import AppKit

/// A nonactivating, click-through window containing one character's recent sentences.
final class CompanionBubble {
    let panel: NSPanel
    private let content = BubbleDragView()
    private struct Row {
        let id: UUID
        let text: String
        let view: NSView
        let size: NSSize
        let label: NSTextField
        let closeButton: NSButton
        var playback: CompanionSpeechPlayback?
    }
    private var rows: [Row] = []
    private var timer: Timer?
    private var typingCompleted: (() -> Void)?
    private weak var anchor: NSWindow?
    private var avatar: NSImage?
    private var retention = CompanionSpeechPlayback.defaultRetention
    private let preview: Bool
    var offset = NSPoint.zero
    var onMoved: (() -> Void)?
    var sentenceCount: Int { rows.count }
    var displayedTexts: [String] { rows.map { $0.label.stringValue } }
    init(preview: Bool = false) {
        self.preview = preview
        content.draggable = preview
        panel = preview ? BubblePreviewPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            : NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .floating; panel.ignoresMouseEvents = !preview; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        content.wantsLayer = true; content.autoresizesSubviews = false
        content.onMoved = { [weak self] in self?.onMoved?() }
        panel.contentView = content
    }
    deinit { timer?.invalidate() }
    func configure(avatar: NSImage?, retention: TimeInterval = CompanionSpeechPlayback.defaultRetention) {
        self.avatar = avatar; self.retention = CompanionSpeechPlayback.normalizedRetention(retention)
        let previous = rows
        rows.forEach { $0.view.removeFromSuperview() }; rows.removeAll()
        for row in previous {
            append(row.text)
            rows[rows.count - 1].playback = row.playback
            rows[rows.count - 1].playback?.setRetention(self.retention)
            rows.last?.label.stringValue = row.label.stringValue
        }
        layout(animated: false)
    }
    /// Static content is used only by the draggable placement preview.
    func show(name: String, text: String, near window: NSWindow) {
        anchor = window; append(text)
        layout(animated: panel.isVisible)
        position(near: window); panel.orderFrontRegardless(); panel.display()
    }
    func type(text: String, near window: NSWindow, completion: @escaping () -> Void) {
        anchor = window; append(text)
        let playback = CompanionSpeechPlayback(text: text, retention: retention)
        rows[rows.count - 1].playback = playback
        rows.last?.label.stringValue = playback.visibleText(at: playback.startedAt)
        typingCompleted = completion
        layout(animated: panel.isVisible)
        position(near: window); panel.orderFrontRegardless(); panel.display()
        if timer == nil {
            let timer = Timer(timeInterval: 0.025, repeats: true) { [weak self] _ in self?.advance(to: Date()) }
            self.timer = timer; RunLoop.main.add(timer, forMode: .common)
        }
    }
    func advance(to time: Date) {
        for row in rows {
            if let playback = row.playback { row.label.stringValue = playback.visibleText(at: time) }
        }
        let finished = rows.allSatisfy { $0.playback?.isTyping(at: time) != true }
        let completion = finished ? typingCompleted : nil
        if finished { typingCompleted = nil }
        let expired = rows.filter { $0.playback?.isExpired(at: time) == true }
        if !expired.isEmpty {
            expired.forEach { $0.view.removeFromSuperview() }
            rows.removeAll { $0.playback?.isExpired(at: time) == true }
            if rows.isEmpty { panel.orderOut(nil) }
            else {
                layout(animated: true)
                if let anchor { position(near: anchor) }
            }
        }
        if rows.allSatisfy({ $0.playback == nil }) { timer?.invalidate(); timer = nil }
        updateHover(at: NSEvent.mouseLocation)
        completion?()
    }
    private func append(_ text: String) {
        let font = NSFont.systemFont(ofSize: 14)
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = font; label.textColor = .labelColor
        // NSTextField cells add their own horizontal inset. Include it before
        // measuring wrapping, otherwise the last few characters land on a clipped line.
        let rect = (text as NSString).boundingRect(with: NSSize(width: 212, height: 2000), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
        let width = max(48, min(240, ceil(rect.width) + 28))
        let closeSpace: CGFloat = preview ? 0 : 22
        let bodyWidth = width + closeSpace
        let labelHeight = ceil(label.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: width - 24, height: 2000)).height)
        let height = max(36, labelHeight + 20)
        let avatarSpace: CGFloat = avatar == nil ? 0 : 44
        let row = NSView(frame: NSRect(x: 0, y: 0, width: avatarSpace + bodyWidth + 6, height: height))
        row.wantsLayer = true
        let effect = NSVisualEffectView(frame: NSRect(x: avatarSpace, y: 0, width: bodyWidth + 6, height: height))
        effect.material = .popover; effect.blendingMode = .behindWindow; effect.state = .active
        effect.wantsLayer = true
        // A single mask gives the body and iMessage-style curved tail the same blur.
        let path = CGMutablePath()
        path.addRoundedRect(in: CGRect(x: 6, y: 4, width: bodyWidth, height: height - 4), cornerWidth: 17, cornerHeight: 17)
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
        let id = UUID()
        let close = BubbleCloseButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: L10n.text("companion.bubble_close"))!, target: nil, action: nil)
        close.frame = NSRect(x: avatarSpace + bodyWidth - 16, y: height - 28, width: 22, height: 22)
        close.isBordered = false; close.bezelStyle = .circular; close.controlSize = .small
        close.contentTintColor = .secondaryLabelColor; close.refusesFirstResponder = true
        close.toolTip = L10n.text("companion.bubble_close"); close.setAccessibilityLabel(L10n.text("companion.bubble_close"))
        close.isHidden = true
        close.connect { [weak self] in self?.dismiss(id) }
        row.addSubview(close)
        content.addSubview(row)
        rows.append(Row(id: id, text: text, view: row, size: NSSize(width: avatarSpace + bodyWidth + 6, height: height), label: label, closeButton: close))
    }
    /// Polling also detects hover while the passive window ignores mouse events.
    func updateHover(at screenPoint: NSPoint) {
        guard !preview else { return }
        let point = content.convert(panel.convertPoint(fromScreen: screenPoint), from: nil)
        var overButton = false
        for row in rows {
            let local = row.view.convert(point, from: content)
            row.closeButton.isHidden = !row.view.bounds.contains(local)
            if !row.closeButton.isHidden && row.closeButton.frame.contains(local) { overButton = true }
        }
        panel.ignoresMouseEvents = !overButton
    }
    func closeButton(at index: Int) -> NSButton? {
        rows.indices.contains(index) ? rows[index].closeButton : nil
    }
    private func dismiss(_ id: UUID) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        let removed = rows.remove(at: index); removed.view.removeFromSuperview()
        let completion = rows.allSatisfy { $0.playback?.isTyping(at: Date()) != true } ? typingCompleted : nil
        if completion != nil { typingCompleted = nil }
        if rows.isEmpty { panel.orderOut(nil) }
        else {
            layout(animated: true)
            if let anchor { position(near: anchor) }
        }
        if rows.allSatisfy({ $0.playback == nil }) { timer?.invalidate(); timer = nil }
        updateHover(at: NSEvent.mouseLocation)
        completion?()
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
        timer?.invalidate(); timer = nil; typingCompleted = nil
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
    var draggable = false
    override func hitTest(_ point: NSPoint) -> NSView? {
        draggable ? (bounds.contains(point) ? self : nil) : super.hitTest(point)
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { if draggable { addCursorRect(bounds, cursor: .openHand) } }
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

private final class BubbleCloseButton: NSButton {
    var onClose: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        target = self; action = #selector(closeBubble)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func connect(_ action: @escaping () -> Void) {
        onClose = action; target = self; self.action = #selector(closeBubble)
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    @objc private func closeBubble() { onClose?() }
}
