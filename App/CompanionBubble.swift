import AppKit

/// Shared renderer for model-attached bubbles and fixed, vertically scrolling Groups.
final class CompanionBubble {
    let panel: NSPanel
    private let content = BubbleDragView()
    private struct Row {
        let id: UUID
        let text: String
        let speakerID: UUID?
        let isPreview: Bool
        let avatar: NSImage?
        let side: CompanionBubbleSide
        let view: NSView
        let size: NSSize
        let label: NSTextField
        let closeButton: NSButton
        var playback: CompanionSpeechPlayback?
        var presentationDeadline: Date? = nil
    }
    private var rows: [Row] = []
    private var timer: Timer?
    private var typingCompleted: (() -> Void)?
    private var presentationCallbacks: [UUID: () -> Void] = [:]
    private var cancellationCallbacks: [UUID: () -> Void] = [:]
    private weak var anchor: NSWindow?
    private var avatar: NSImage?
    private var retention = CompanionSpeechPlayback.defaultRetention
    private let preview: Bool
    private var side: CompanionBubbleSide = .left
    private let scroll: NSScrollView?
    private var resizeObserver: NSObjectProtocol?
    private var layingOut = false
    private var editing = false
    var isGroup: Bool { scroll != nil }
    private var actualRows: [Row] { rows.filter { !$0.isPreview } }
    private var visibleRows: [Row] { rows.filter { $0.isPreview == editing } }
    var groupPreviewTexts: [String] { rows.filter(\.isPreview).map(\.text) }
    var speakerIDs: Set<UUID> { Set(actualRows.compactMap(\.speakerID)) }
    var scrollView: NSScrollView? { scroll }
    var messageFrames: [NSRect] { visibleRows.map { $0.view.frame } }
    var messageSides: [CompanionBubbleSide] { visibleRows.map(\.side) }
    var messageAlignments: [NSTextAlignment] { visibleRows.map { $0.label.alignment } }
    var followsLatest: Bool { (scroll?.contentView.bounds.minY ?? 0) <= 2 }
    func texts(for speaker: UUID) -> [String] { actualRows.filter { $0.speakerID == speaker }.map { $0.label.stringValue } }
    var offset = NSPoint.zero
    var onMoved: (() -> Void)?
    var sentenceCount: Int { actualRows.count }
    var displayedTexts: [String] { actualRows.map { $0.label.stringValue } }
    init(preview: Bool = false, groupFrame: NSRect? = nil) {
        self.preview = preview
        scroll = groupFrame == nil ? nil : NSScrollView()
        content.draggable = preview
        panel = preview ? BubblePreviewPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            : NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.level = .floating; panel.ignoresMouseEvents = !preview; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        content.wantsLayer = true; content.autoresizesSubviews = false
        content.onMoved = { [weak self] in self?.onMoved?() }
        if let scroll {
            scroll.contentView = VerticalBubbleClipView()
            scroll.drawsBackground = false; scroll.contentView.drawsBackground = false
            scroll.hasVerticalScroller = false; scroll.hasHorizontalScroller = false
            scroll.autohidesScrollers = true; scroll.scrollerStyle = .overlay
            scroll.horizontalScrollElasticity = .none; scroll.verticalScrollElasticity = .allowed
            scroll.usesPredominantAxisScrolling = true
            scroll.documentView = content; panel.contentView = scroll
            panel.ignoresMouseEvents = false
            panel.setFrame(groupFrame!, display: false)
            panel.contentMinSize = NSSize(width: 240, height: 120)
            resizeObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: panel, queue: .main) { [weak self] _ in
                guard let self, !self.layingOut else { return }
                self.rebuildRows()
            }
        } else { panel.contentView = content }
    }
    deinit {
        timer?.invalidate()
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
    }
    func configure(avatar: NSImage?, retention: TimeInterval = CompanionSpeechPlayback.defaultRetention, side: CompanionBubbleSide = .left) {
        self.avatar = avatar; self.side = side
        self.retention = CompanionSpeechPlayback.normalizedRetention(retention)
        rebuildRows()
    }
    func refreshSpeakers(_ style: @escaping (UUID) -> (NSImage?, CompanionBubbleSide)) {
        rebuildRows(style: style)
    }
    private func rebuildRows(style: ((UUID) -> (NSImage?, CompanionBubbleSide))? = nil) {
        let previous = rows
        let anchor = scrollAnchor()
        rows.forEach { $0.view.removeFromSuperview() }; rows.removeAll()
        for row in previous {
            var image = isGroup ? row.avatar : avatar
            var direction = isGroup ? row.side : side
            if let id = row.speakerID, let style { (image, direction) = style(id) }
            append(row.text, speakerID: row.speakerID, avatar: image, side: direction, id: row.id, isPreview: row.isPreview)
            rows[rows.count - 1].presentationDeadline = row.presentationDeadline
            rows[rows.count - 1].playback = row.playback
            rows[rows.count - 1].playback?.setRetention(retention)
            rows.last?.label.stringValue = row.label.stringValue
        }
        layout(animated: false, anchor: anchor)
    }
    func setGroupFrame(_ frame: NSRect) {
        guard isGroup, !editing else { return }
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        layout(animated: false)
    }
    func beginGroupEditing(name: String, speakers: [CompanionGroupPreviewSpeaker] = []) {
        guard isGroup, !editing else { return }
        let frame = panel.frame
        editing = true
        panel.styleMask = [.titled, .resizable, .nonactivatingPanel]
        panel.title = name; panel.setContentSize(frame.size)
        panel.setFrameOrigin(frame.origin)
        scroll?.wantsLayer = true
        scroll?.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.3).cgColor
        updateGroupPreview(speakers)
        panel.orderFrontRegardless(); panel.display()
    }
    @discardableResult func finishGroupEditing() -> NSRect {
        guard isGroup, editing else { return panel.frame }
        let frame = panel.convertToScreen(panel.contentView!.bounds)
        rows.filter(\.isPreview).forEach { $0.view.removeFromSuperview() }
        rows.removeAll(where: \.isPreview)
        editing = false; panel.styleMask = [.borderless, .nonactivatingPanel]
        scroll?.layer?.backgroundColor = NSColor.clear.cgColor
        panel.setFrame(frame, display: true)
        layout(animated: false)
        if rows.isEmpty && !editing { panel.orderOut(nil) }
        flushPresentationCallbacks()
        return frame
    }
    func updateGroupPreview(_ speakers: [CompanionGroupPreviewSpeaker]) {
        guard isGroup, editing else { return }
        rows.filter(\.isPreview).forEach { $0.view.removeFromSuperview() }
        rows.removeAll(where: \.isPreview)
        let styles = speakers.isEmpty ? [CompanionGroupPreviewSpeaker(id: nil, avatar: nil, side: .left),
                                        CompanionGroupPreviewSpeaker(id: nil, avatar: nil, side: .right)] : speakers
        let messages = [L10n.text("companion.group_preview_short"), L10n.text("companion.group_preview_long"), L10n.text("companion.group_preview_resize")]
        for index in 0..<max(3, styles.count) {
            let style = styles[index % styles.count]
            append(messages[index % messages.count], speakerID: style.id, avatar: style.avatar, side: style.side, isPreview: true)
        }
        layout(animated: false)
    }
    /// Static content is used only by the draggable placement preview.
    func show(name: String, text: String, near window: NSWindow, speakerID: UUID? = nil, avatar: NSImage? = nil, side: CompanionBubbleSide? = nil) {
        anchor = window; append(text, speakerID: speakerID, avatar: isGroup ? avatar : self.avatar, side: side ?? self.side)
        layout(animated: panel.isVisible)
        position(near: window); panel.orderFrontRegardless(); panel.display()
    }
    func type(text: String, near window: NSWindow, speakerID: UUID? = nil, avatar: NSImage? = nil, side: CompanionBubbleSide? = nil, presentationDeadline: Date? = nil, onPresented: (() -> Void)? = nil, onCancelled: (() -> Void)? = nil, completion: @escaping () -> Void) {
        anchor = window; append(text, speakerID: speakerID, avatar: isGroup ? avatar : self.avatar, side: side ?? self.side)
        rows[rows.count - 1].presentationDeadline = presentationDeadline
        if let id = rows.last?.id {
            if let onPresented { presentationCallbacks[id] = onPresented }
            if let onCancelled { cancellationCallbacks[id] = onCancelled }
        }
        let playback = CompanionSpeechPlayback(text: text, retention: retention)
        rows[rows.count - 1].playback = playback
        rows.last?.label.stringValue = playback.visibleText(at: playback.startedAt)
        typingCompleted = completion
        layout(animated: panel.isVisible)
        position(near: window); panel.orderFrontRegardless(); panel.display()
        flushPresentationCallbacks()
        if timer == nil {
            let timer = Timer(timeInterval: 0.025, repeats: true) { [weak self] _ in self?.advance(to: Date()) }
            self.timer = timer; RunLoop.main.add(timer, forMode: .common)
        }
    }
    private func flushPresentationCallbacks() {
        guard !editing, panel.isVisible else { return }
        let expired = Set(actualRows.filter { presentationCallbacks[$0.id] != nil && ($0.presentationDeadline ?? .distantFuture) <= Date() }.map(\.id))
        for row in rows where expired.contains(row.id) {
            presentationCallbacks.removeValue(forKey: row.id); cancellationCallbacks.removeValue(forKey: row.id)?(); row.view.removeFromSuperview()
        }
        rows.removeAll { expired.contains($0.id) }
        if !expired.isEmpty { layout(animated: false) }
        for row in actualRows {
            if let callback = presentationCallbacks.removeValue(forKey: row.id) { callback() }
        }
    }
    func advance(to time: Date) {
        for row in rows {
            if let playback = row.playback { row.label.stringValue = playback.visibleText(at: time) }
        }
        let finished = rows.allSatisfy { $0.playback?.isTyping(at: time) != true }
        let completion = finished ? typingCompleted : nil
        if finished { typingCompleted = nil }
        let saved = scrollAnchor()
        let expired = rows.filter { $0.playback?.isExpired(at: time) == true }
        if !expired.isEmpty {
            expired.forEach { row in
                presentationCallbacks.removeValue(forKey: row.id); cancellationCallbacks.removeValue(forKey: row.id)?(); row.view.removeFromSuperview()
            }
            rows.removeAll { $0.playback?.isExpired(at: time) == true }
            if rows.isEmpty && !editing { panel.orderOut(nil) }
            layout(animated: true, anchor: saved)
            if let anchor { position(near: anchor) }
        }
        if rows.allSatisfy({ $0.playback == nil }) { timer?.invalidate(); timer = nil }
        updateHover(at: NSEvent.mouseLocation)
        completion?()
    }
    private func append(_ text: String, speakerID: UUID? = nil, avatar: NSImage?, side: CompanionBubbleSide, id: UUID = UUID(), isPreview: Bool = false) {
        let font = NSFont.systemFont(ofSize: 14)
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = font; label.textColor = .labelColor; label.alignment = .left; label.baseWritingDirection = .leftToRight
        // NSTextField cells add their own horizontal inset. Include it before
        // measuring wrapping, otherwise the last few characters land on a clipped line.
        let avatarSpace: CGFloat = avatar == nil ? 0 : 44
        let closeSpace: CGFloat = preview ? 0 : 22
        let available = scroll.map { max(48, $0.contentSize.width * 0.85 - avatarSpace - 6 - closeSpace - 28) } ?? 212
        let rect = (text as NSString).boundingRect(with: NSSize(width: available, height: 10000), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
        let width = max(48, min(available + 28, ceil(rect.width) + 28))
        let bodyWidth = width + closeSpace
        let labelHeight = ceil(label.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: width - 24, height: 2000)).height)
        let height = max(36, labelHeight + 20)
        let row = NSView(frame: NSRect(x: 0, y: 0, width: avatarSpace + bodyWidth + 6, height: height))
        row.wantsLayer = true
        let bubbleX: CGFloat = side == .left ? avatarSpace : 0
        let effect = NSVisualEffectView(frame: NSRect(x: bubbleX, y: 0, width: bodyWidth + 6, height: height))
        effect.material = .popover; effect.blendingMode = .behindWindow; effect.state = .active
        effect.wantsLayer = true
        // A single mask gives the body and iMessage-style curved tail the same blur.
        let path = CGMutablePath()
        path.addRoundedRect(in: CGRect(x: 6, y: 4, width: bodyWidth, height: height - 4), cornerWidth: 17, cornerHeight: 17)
        path.move(to: CGPoint(x: 10, y: 20))
        path.addCurve(to: CGPoint(x: 0, y: 0), control1: CGPoint(x: 10, y: 8), control2: CGPoint(x: 6, y: 3))
        path.addCurve(to: CGPoint(x: 26, y: 7), control1: CGPoint(x: 11, y: -1), control2: CGPoint(x: 19, y: 2))
        path.closeSubpath()
        let mask = CAShapeLayer()
        if side == .right {
            var mirror = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: bodyWidth + 6, ty: 0)
            mask.path = path.copy(using: &mirror)
        } else { mask.path = path }
        effect.layer?.mask = mask
        label.frame = NSRect(x: side == .left ? 18 : 12, y: 12, width: width - 24, height: height - 20)
        effect.addSubview(label); row.addSubview(effect)
        if let avatar {
            let image = NSImageView(frame: NSRect(x: side == .left ? 0 : bodyWidth + 16, y: 0, width: 34, height: 34))
            image.image = avatar; image.imageScaling = .scaleProportionallyUpOrDown
            image.wantsLayer = true; image.layer?.cornerRadius = 17; image.layer?.masksToBounds = true
            row.addSubview(image)
        }
        let close = BubbleCloseButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: L10n.text("companion.bubble_close"))!, target: nil, action: nil)
        close.frame = NSRect(x: bubbleX + bodyWidth - (side == .left ? 16 : 22), y: height - 28, width: 22, height: 22)
        close.isBordered = false; close.bezelStyle = .circular; close.controlSize = .small
        close.contentTintColor = .secondaryLabelColor; close.refusesFirstResponder = true
        close.toolTip = L10n.text("companion.bubble_close"); close.setAccessibilityLabel(L10n.text("companion.bubble_close"))
        close.isHidden = true
        close.connect { [weak self] in self?.dismiss(id) }
        row.addSubview(close)
        content.addSubview(row)
        rows.append(Row(id: id, text: text, speakerID: speakerID, isPreview: isPreview, avatar: avatar, side: side, view: row, size: NSSize(width: avatarSpace + bodyWidth + 6, height: height), label: label, closeButton: close))
    }
    /// Polling also detects hover while the passive window ignores mouse events.
    func updateHover(at screenPoint: NSPoint) {
        guard !preview else { return }
        if editing { rows.forEach { $0.closeButton.isHidden = true }; return }
        let point = content.convert(panel.convertPoint(fromScreen: screenPoint), from: nil)
        var overButton = false
        for row in rows {
            let local = row.view.convert(point, from: content)
            row.closeButton.isHidden = !row.view.bounds.contains(local)
            if !row.closeButton.isHidden && row.closeButton.frame.contains(local) { overButton = true }
        }
        panel.ignoresMouseEvents = isGroup ? false : !overButton
    }
    func closeButton(at index: Int) -> NSButton? {
        rows.indices.contains(index) ? rows[index].closeButton : nil
    }
    private func dismiss(_ id: UUID) {
        removeRows { $0.id == id }
    }
    func removeSpeaker(_ id: UUID) { removeRows { !$0.isPreview && $0.speakerID == id } }
    private func removeRows(where predicate: (Row) -> Bool) {
        let anchor = scrollAnchor()
        rows.filter(predicate).forEach { row in presentationCallbacks.removeValue(forKey: row.id); cancellationCallbacks.removeValue(forKey: row.id)?(); row.view.removeFromSuperview() }
        rows.removeAll(where: predicate)
        let completion = rows.allSatisfy { $0.playback?.isTyping(at: Date()) != true } ? typingCompleted : nil
        if completion != nil { typingCompleted = nil }
        if rows.isEmpty && !editing { panel.orderOut(nil) }
        layout(animated: true, anchor: anchor)
        if let anchorWindow = self.anchor { position(near: anchorWindow) }
        if rows.allSatisfy({ $0.playback == nil }) { timer?.invalidate(); timer = nil }
        updateHover(at: NSEvent.mouseLocation)
        completion?()
    }
    private struct ScrollAnchor {
        let following: Bool
        let id: UUID?
        let offset: CGFloat
        let oldOrigin: CGFloat
    }
    private func scrollAnchor() -> ScrollAnchor? {
        guard let scroll else { return nil }
        let bounds = scroll.contentView.bounds
        let first = visibleRows.first { $0.view.frame.intersects(bounds) }
        return ScrollAnchor(following: bounds.minY <= 2, id: first?.id,
                            offset: (first?.view.frame.minY ?? 0) - bounds.minY, oldOrigin: bounds.minY)
    }
    private func layout(animated: Bool, anchor: ScrollAnchor? = nil) {
        guard !layingOut else { return }
        layingOut = true; defer { layingOut = false }
        let saved = anchor ?? scrollAnchor()
        for row in rows { row.view.isHidden = row.isPreview != editing }
        let displayed = visibleRows
        let width = scroll?.contentSize.width ?? (displayed.map(\.size.width).max() ?? 0)
        let height = displayed.reduce(CGFloat(0)) { $0 + $1.size.height } + CGFloat(max(0, displayed.count - 1)) * 8
        if let scroll { content.setFrameSize(NSSize(width: width, height: max(height, scroll.contentSize.height))) }
        else { panel.setContentSize(NSSize(width: ceil(width / 2) * 2, height: ceil(height))) }
        var y = height
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated ? 0.2 : 0
            for row in displayed {
                y -= row.size.height
                let x = row.side == .right ? max(0, width - row.size.width) : 0
                let frame = NSRect(x: x, y: y, width: row.size.width, height: row.size.height)
                if animated { row.view.animator().setFrameOrigin(frame.origin) }
                else { row.view.frame = frame }
                y -= 8
            }
        }
        if let scroll, let saved {
            let origin: CGFloat
            if saved.following { origin = 0 }
            else if let row = displayed.first(where: { $0.id == saved.id }) { origin = row.view.frame.minY - saved.offset }
            else { origin = saved.oldOrigin }
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, origin)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }
    func position(near window: NSWindow) {
        guard !isGroup else { return }
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
        timer?.invalidate(); timer = nil; typingCompleted = nil; presentationCallbacks = [:]
        if !editing { panel.orderOut(nil) }
        let removed = rows.filter { !editing || !$0.isPreview }
        removed.forEach { row in cancellationCallbacks.removeValue(forKey: row.id)?(); row.view.removeFromSuperview() }
        rows.removeAll { !editing || !$0.isPreview }
        if editing { layout(animated: false) }
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
        guard draggable else { return }
        startMouse = NSEvent.mouseLocation; startOrigin = window?.frame.origin
        NSCursor.closedHand.set()
    }
    override func mouseDragged(with event: NSEvent) {
        guard draggable else { return }
        guard let startMouse, let startOrigin else { return }
        let point = NSEvent.mouseLocation
        window?.setFrameOrigin(NSPoint(x: startOrigin.x + point.x - startMouse.x, y: startOrigin.y + point.y - startMouse.y))
        onMoved?()
    }
    override func mouseUp(with event: NSEvent) {
        guard draggable else { return }
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

private final class VerticalBubbleClipView: NSClipView {
    override func scroll(to newOrigin: NSPoint) {
        super.scroll(to: NSPoint(x: 0, y: newOrigin.y))
    }
    override func setBoundsOrigin(_ newOrigin: NSPoint) {
        super.setBoundsOrigin(NSPoint(x: 0, y: newOrigin.y))
    }
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var bounds = super.constrainBoundsRect(proposedBounds)
        bounds.origin.x = 0
        return bounds
    }
}
