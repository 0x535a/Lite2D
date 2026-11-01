import AppKit
import OpenGL.GL
import QuartzCore

struct RenderedFrame {
    let data: Data
    let width: Int
    let height: Int
    let glError: UInt32
    var visiblePixels: Int { data.enumerated().filter { $0.offset % 4 == 3 && $0.element > 0 }.count }
}

final class OpenGLModelView: NSOpenGLView {
    let bridge = L2DBridge()
    var settings: ModelInstanceSettings
    var onZoom: ((Double) -> Void)?
    var onFrame: ((OpenGLModelView) -> Void)?
    private var displayLink: CADisplayLink?
    private var lastTime: Double?
    private var captureRequested = false
    private var renderRequested = false
    private var captured: RenderedFrame?
    private(set) var loaded = false
    private(set) var active = false
    private(set) var frames: UInt64 = 0
    private(set) var displayCallbacks: UInt64 = 0
    private(set) var scheduledFrames: UInt64 = 0
    private(set) var filteredLook = NSPoint.zero
    private(set) var animationTime = 0.0
    private(set) var lastGLError: UInt32 = 0
    override var isOpaque: Bool { false }

    init?(settings: ModelInstanceSettings) {
        self.settings = settings
        let attributes: [NSOpenGLPixelFormatAttribute] = [
            UInt32(NSOpenGLPFADoubleBuffer), UInt32(NSOpenGLPFAAlphaSize), 8,
            UInt32(NSOpenGLPFAColorSize), 24, UInt32(NSOpenGLPFAAccelerated), 0
        ]
        super.init(frame: NSRect(origin: .zero, size: settings.windowFrame.rect.size),
                   pixelFormat: NSOpenGLPixelFormat(attributes: attributes))
        wantsBestResolutionOpenGLSurface = true
        autoresizingMask = [.width, .height]
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override func prepareOpenGL() { super.prepareOpenGL(); configureSurface() }
    private func configureSurface() {
        openGLContext?.makeCurrentContext()
        var opacity: GLint = 0
        openGLContext?.setValues(&opacity, for: .surfaceOpacity)
        // CADisplayLink schedules the frame; avoid blocking the shared main
        // thread once per model on sequential vertical-sync waits.
        var swap: GLint = 0
        openGLContext?.setValues(&swap, for: .swapInterval)
    }
    func load() throws {
        configureSurface()
        let validated = try ModelFileValidator.validate(URL(fileURLWithPath: settings.modelPath))
        for warning in validated.warnings { NSLog("%@", warning) }
        let pixels = convertToBacking(bounds)
        try bridge.load(path: validated.url.path, width: Int32(max(pixels.width, 1)), height: Int32(max(pixels.height, 1)))
        if let idle = settings.idleMotionGroup { bridge.setIdleGroup(idle) }
        if let expression = settings.expressionId { _ = bridge.selectExpression(expression) }
        loaded = true
        displayLink = self.displayLink(target: self, selector: #selector(tick(_:)))
        applyFPS()
        displayLink?.isPaused = true
        displayLink?.add(to: .main, forMode: .common)
    }
    func applyFPS() {
        let fps = Float(settings.targetFPS)
        displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: fps, maximum: fps, preferred: fps)
        lastTime = nil
    }
    func setActive(_ value: Bool) {
        active = value && loaded
        lastTime = nil
        displayLink?.isPaused = !active
        if active { needsDisplay = true }
    }
    @objc private func tick(_ link: CADisplayLink) {
        displayCallbacks += 1
        guard active, window?.isVisible == true else { lastTime = nil; return }
        // Use the display clock, not callback delivery time. Delivery can be
        // delayed by another model's draw; throttling by that jitter skips
        // otherwise valid 30/60 Hz presentation slots.
        let now = link.timestamp
        if let lastTime, now - lastTime < 0.85 / Double(settings.targetFPS) { return }
        let dt = min(max(lastTime.map { now - $0 } ?? (1.0 / Double(settings.targetFPS)), 0.001), 0.1)
        lastTime = now
        scheduledFrames += 1
        renderFrame(deltaTime: dt, now: now)
    }
    func renderFrame(deltaTime: Double, now: Double = ProcessInfo.processInfo.systemUptime) {
        guard loaded, active, let window else { return }
        openGLContext?.makeCurrentContext()
        let point = window.convertPoint(fromScreen: SharedMouseTracker.shared.point(at: now))
        let raw = settings.trackingEnabled ? NSPoint(
            x: min(max((point.x - bounds.midX) / max(bounds.width * 0.5, 1), -1), 1),
            y: min(max((point.y - bounds.height * 0.7) / max(bounds.height * 0.35, 1), -1), 1)
        ) : .zero
        let alpha = 1 - exp(-max(deltaTime, 0) / settings.trackingSmoothingSeconds)
        filteredLook.x += (raw.x - filteredLook.x) * alpha
        filteredLook.y += (raw.y - filteredLook.y) * alpha
        let animationDelta = settings.animationPaused ? 0 : deltaTime
        animationTime += animationDelta
        bridge.step(deltaTime: animationDelta, lookX: Float(filteredLook.x), lookY: Float(filteredLook.y))
        renderRequested = true
        needsDisplay = true
        displayIfNeeded()
    }
    override func draw(_ dirtyRect: NSRect) {
        guard loaded, active, renderRequested else { return }
        renderRequested = false
        openGLContext?.makeCurrentContext()
        let pixels = convertToBacking(bounds)
        let w = Int32(pixels.width), h = Int32(pixels.height)
        guard w > 0, h > 0 else { return }
        glViewport(0, 0, w, h)
        glClearColor(0, 0, 0, 0)
        glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
        // Zoom is represented by a compact resized window; scaling the model
        // again here would double the zoom and clip the face.
        bridge.render(width: w, height: h, scale: 1)
        lastGLError = glGetError()
        frames += 1
        if captureRequested {
            var bytes = [UInt8](repeating: 0, count: Int(w) * Int(h) * 4)
            glFinish()
            glReadPixels(0, 0, w, h, GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), &bytes)
            let error = glGetError()
            captured = RenderedFrame(data: Data(bytes), width: Int(w), height: Int(h), glError: lastGLError == 0 ? error : lastGLError)
            captureRequested = false
        }
        openGLContext?.flushBuffer()
        onFrame?(self)
    }
    func capture() -> RenderedFrame? {
        guard loaded, active else { return nil }
        captureRequested = true
        renderRequested = true
        needsDisplay = true
        display()
        let result = captured
        captured = nil
        return result
    }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    override func scrollWheel(with event: NSEvent) {
        guard settings.interactionMode == .edit else { return }
        onZoom?(exp(-event.scrollingDeltaY * 0.012))
    }
    func shutdown() {
        active = false
        displayLink?.invalidate(); displayLink = nil
        onFrame = nil; onZoom = nil
        openGLContext?.makeCurrentContext()
        bridge.unload(); loaded = false
        NSOpenGLContext.clearCurrentContext()
    }
}
