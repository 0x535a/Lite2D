import AppKit

enum CompanionBubbleSide: String, Codable, CaseIterable { case left, right }

enum CompanionGroupSelection {
    static func tag(_ id: UUID) -> String { "group:\(id.uuidString)" }
    static func id(_ selection: String?) -> UUID? {
        guard let selection, selection.hasPrefix("group:") else { return nil }
        return UUID(uuidString: String(selection.dropFirst(6)))
    }
}

struct CompanionGroupSettings: Codable, Equatable, Identifiable {
    var id = UUID()
    var name = "Group"
    // Last global frame is retained to migrate older, unbound Group settings.
    var x: Double = 100
    var y: Double = 100
    var width: Double = 480
    var height: Double = 360
    var displayUUID: String?
    var boundDisplayName: String?
    var displayPosition: DisplayPosition?
    var displayBindingVersion = 0
    enum CodingKeys: String, CodingKey {
        case id, name, x, y, width, height, displayUUID, boundDisplayName, displayPosition, displayBindingVersion
    }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decode(String.self, forKey: .name)) ?? "Group"
        x = (try? c.decode(Double.self, forKey: .x)) ?? 100
        y = (try? c.decode(Double.self, forKey: .y)) ?? 100
        width = (try? c.decode(Double.self, forKey: .width)) ?? 480
        height = (try? c.decode(Double.self, forKey: .height)) ?? 360
        displayUUID = try? c.decodeIfPresent(String.self, forKey: .displayUUID)
        boundDisplayName = try? c.decodeIfPresent(String.self, forKey: .boundDisplayName)
        displayPosition = try? c.decodeIfPresent(DisplayPosition.self, forKey: .displayPosition)
        displayBindingVersion = (try? c.decode(Int.self, forKey: .displayBindingVersion)) ?? 0
        normalize()
    }
    var frame: NSRect {
        get { NSRect(x: x, y: y, width: width, height: height) }
        set { x = newValue.minX; y = newValue.minY; width = newValue.width; height = newValue.height }
    }
    var positionX: Double {
        get { displayPosition?.x ?? x }
        set { displayPosition = DisplayPosition(x: newValue, y: positionY) }
    }
    var positionY: Double {
        get { displayPosition?.y ?? y }
        set { displayPosition = DisplayPosition(x: positionX, y: newValue) }
    }
    mutating func normalize() {
        width = min(max(width.isFinite ? width : 480, 240), 2400)
        height = min(max(height.isFinite ? height : 360, 120), 1800)
        if !x.isFinite { x = 100 }; if !y.isFinite { y = 100 }
        displayPosition?.sanitize()
    }
    mutating func migrate(in displays: [DisplayDescriptor]) {
        normalize()
        if displayBindingVersion == 0 {
            if let display = displays.first(where: { $0.id == displayUUID }) ?? DisplayLayout.matching(frame, in: displays) {
                displayUUID = display.id; boundDisplayName = display.name
                displayPosition = DisplayPosition(x: x - display.frame.minX, y: y - display.frame.minY)
            }
            displayBindingVersion = 1
        }
        if let display = displays.first(where: { $0.id == displayUUID }) { boundDisplayName = display.name }
    }
    func windowFrame(in displays: [DisplayDescriptor]) -> NSRect? {
        guard let display = displays.first(where: { $0.id == displayUUID }), let position = displayPosition else { return nil }
        let area = display.visibleFrame
        let width = min(width, area.width), height = min(height, area.height)
        return NSRect(x: min(max(display.frame.minX + position.x, area.minX), area.maxX - width),
                      y: min(max(display.frame.minY + position.y, area.minY), area.maxY - height), width: width, height: height)
    }
}

struct CompanionGroupPreviewSpeaker {
    let id: UUID?
    let avatar: NSImage?
    let side: CompanionBubbleSide
}
