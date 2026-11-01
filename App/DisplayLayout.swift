import Foundation
import CoreGraphics

struct DisplayPosition: Codable, Equatable {
    var x: Double
    var y: Double
    mutating func sanitize() {
        x = x.isFinite ? min(max(x, -1_000_000), 1_000_000) : 60
        y = y.isFinite ? min(max(y, -1_000_000), 1_000_000) : 50
    }
}

struct DisplayDescriptor: Equatable {
    let id: String
    let name: String
    let frame: CGRect
    let visibleFrame: CGRect
}

enum DisplayLayout {
    static func matching(_ frame: CGRect, in displays: [DisplayDescriptor]) -> DisplayDescriptor? {
        displays.filter { !$0.frame.intersection(frame).isEmpty }
            .max { first, second in
                let a = first.frame.intersection(frame), b = second.frame.intersection(frame)
                return a.width * a.height < b.width * b.height
            }
    }
    static func windowFrame(for settings: ModelInstanceSettings, in displays: [DisplayDescriptor]) -> CGRect? {
        guard let id = settings.displayUUID, let position = settings.displayPosition,
              let display = displays.first(where: { $0.id == id }) else { return nil }
        return CGRect(x: display.frame.minX + position.x, y: display.frame.minY + position.y,
                      width: settings.windowFrame.width, height: settings.windowFrame.height)
    }
}
