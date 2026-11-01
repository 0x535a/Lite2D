import AppKit
import OpenGL.GL

final class ModelView: NSOpenGLView {
    let bridge = L2DBridge()
    var timer: Timer?
    var lastTime = ProcessInfo.processInfo.systemUptime
    var frames = 0
    var modelPath: String?
    override var isOpaque: Bool { false }

    init?(frame: NSRect, path: String?) {
        modelPath = path
        let attributes: [NSOpenGLPixelFormatAttribute] = [
            UInt32(NSOpenGLPFADoubleBuffer), UInt32(NSOpenGLPFAAlphaSize), 8,
            UInt32(NSOpenGLPFAColorSize), 24, UInt32(NSOpenGLPFAAccelerated), 0
        ]
        super.init(frame: frame, pixelFormat: NSOpenGLPixelFormat(attributes: attributes))
        wantsBestResolutionOpenGLSurface = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override func prepareOpenGL() {
        super.prepareOpenGL()
        openGLContext?.makeCurrentContext()
        var opacity: GLint = 0
        openGLContext?.setValues(&opacity, for: .surfaceOpacity)
        var swap: GLint = 1
        openGLContext?.setValues(&swap, for: .swapInterval)
        do {
            if let path = modelPath {
                let pixels = convertToBacking(bounds)
                try bridge.load(path: path, width: Int32(pixels.width), height: Int32(pixels.height))
            }
        } catch { NSLog("Model load failed: %@", error.localizedDescription) }
        timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.needsDisplay = true }
        RunLoop.main.add(timer!, forMode: .common)
    }
    override func draw(_ dirtyRect: NSRect) {
        openGLContext?.makeCurrentContext()
        let pixels = convertToBacking(bounds)
        let w = Int32(pixels.width), h = Int32(pixels.height)
        glViewport(0, 0, w, h)
        glClearColor(0, 0, 0, 0)
        glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
        let now = ProcessInfo.processInfo.systemUptime
        bridge.step(deltaTime: min(max(now - lastTime, 0), 0.1), lookX: 0, lookY: 0)
        lastTime = now
        bridge.render(width: w, height: h, scale: 1)
        frames += 1
        if let directory = ProcessInfo.processInfo.environment["LITE2D_PROBE_DIR"], frames == 30 {
            var bytes = [UInt8](repeating: 0, count: Int(w * h * 4))
            glFinish(); glReadPixels(0, 0, w, h, GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), &bytes)
            try? Data(bytes).write(to: URL(fileURLWithPath: directory).appendingPathComponent("app-frame.rgba"))
            NSLog("APP_PROBE width=%d height=%d frames=%d glError=%u", w, h, frames, glGetError())
            NSApp.terminate(nil)
        }
        openGLContext?.flushBuffer()
    }
    func shutdown() {
        timer?.invalidate(); timer = nil
        openGLContext?.makeCurrentContext(); bridge.unload()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var status: NSStatusItem!
    var window: NSWindow!
    var model: ModelView!
    func applicationDidFinishLaunching(_ notification: Notification) {
        do { try L2DBridge.startRuntime(at: Bundle.main.resourcePath!) }
        catch { NSLog("Runtime failed: %@", error.localizedDescription); NSApp.terminate(nil); return }
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.title = "L2D"
        let menu = NSMenu()
        menu.addItem(withTitle: "退出 Lite2D", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        status.menu = menu
        let arguments = CommandLine.arguments
        let path = arguments.count > 1 ? arguments[1] : nil
        let frame = NSRect(x: 250, y: 150, width: 360, height: 540)
        window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = false
        window.level = .floating; window.ignoresMouseEvents = true
        model = ModelView(frame: NSRect(origin: .zero, size: frame.size), path: path)
        window.contentView = model
        window.orderFrontRegardless()
    }
    func applicationWillTerminate(_ notification: Notification) {
        model?.shutdown(); window?.close(); L2DBridge.stopRuntime()
    }
}
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
