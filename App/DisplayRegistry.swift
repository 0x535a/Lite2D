import AppKit
import CoreGraphics

final class DisplayRegistry {
    // Only in-process tests substitute topology; this never changes macOS
    // display configuration, sends events, or controls another application.
    var testingDisplays: [DisplayDescriptor]?

    static func identifier(_ displayID: CGDirectDisplayID) -> String {
        if let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() {
            return CFUUIDCreateString(nil, uuid) as String
        }
        return "session-display-\(displayID)"
    }
    var displays: [DisplayDescriptor] {
        if let testingDisplays { return testingDisplays }
        return NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return DisplayDescriptor(id: Self.identifier(number.uint32Value), name: screen.localizedName,
                                     frame: screen.frame, visibleFrame: screen.visibleFrame)
        }
    }
    var primary: DisplayDescriptor? {
        let screens = displays
        return screens.first { $0.id == Self.identifier(CGMainDisplayID()) } ?? screens.first
    }
}
