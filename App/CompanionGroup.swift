import AppKit

enum CompanionBubbleSide: String, Codable, CaseIterable {
    case left, right
}

struct CompanionGroupSettings: Codable, Equatable, Identifiable {
    var id = UUID()
    var name = "Group"
    // Global macOS screen coordinates, in points, with a bottom-left origin.
    var x: Double = 100
    var y: Double = 100
    var width: Double = 480
    var height: Double = 360
    var frame: NSRect {
        get { NSRect(x: x, y: y, width: width, height: height) }
        set { x = newValue.minX; y = newValue.minY; width = newValue.width; height = newValue.height }
    }
    mutating func normalize() {
        width = min(max(width.isFinite ? width : 480, 240), 2400)
        height = min(max(height.isFinite ? height : 360, 120), 1800)
        if !x.isFinite { x = 100 }; if !y.isFinite { y = 100 }
    }
    func reachableFrame() -> NSRect {
        var value = self; value.normalize()
        let desired = value.frame
        let screen = NSScreen.screens.max { a, b in
            let ar = a.visibleFrame.intersection(desired), br = b.visibleFrame.intersection(desired)
            return (ar.isNull ? 0 : ar.width * ar.height) < (br.isNull ? 0 : br.width * br.height)
        }.flatMap { $0.visibleFrame.intersects(desired) ? $0 : NSScreen.main } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return desired }
        let width = min(desired.width, area.width), height = min(desired.height, area.height)
        return NSRect(x: min(max(desired.minX, area.minX), area.maxX - width),
                      y: min(max(desired.minY, area.minY), area.maxY - height), width: width, height: height)
    }
}
