import AppKit

final class SharedMouseTracker {
    static let shared = SharedMouseTracker()
    private var lastSample = -Double.infinity
    private var cached = NSPoint.zero
    private(set) var samples: UInt64 = 0
    // Only the program's self-test supplies this; no OS cursor events are sent.
    var testPoint: NSPoint?

    func point(at time: Double) -> NSPoint {
        if let testPoint { return testPoint }
        if time - lastSample >= 1.0 / 60 {
            cached = NSEvent.mouseLocation
            lastSample = time
            samples += 1
        }
        return cached
    }
}
