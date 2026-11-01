import Foundation
import CoreGraphics

struct WindowFrame: Codable, Equatable {
    var x: Double = 100
    var y: Double = 100
    var width: Double = 360
    var height: Double = 480
    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    init() {}
    init(_ rect: CGRect) { x = rect.minX; y = rect.minY; width = rect.width; height = rect.height }
    mutating func sanitize() {
        x = x.isFinite ? min(max(x, -1_000_000), 1_000_000) : 100
        y = y.isFinite ? min(max(y, -1_000_000), 1_000_000) : 100
        width = width.isFinite ? min(max(width, 160), 1600) : 360
        height = height.isFinite ? min(max(height, 180), 1800) : 480
    }
}

enum InteractionMode: String, Codable { case passthrough, edit }

enum ZoomGeometry {
    static func resize(frame: CGRect, currentScale: Double, factor: Double) -> (frame: CGRect, scale: Double) {
        guard factor.isFinite, factor > 0, frame.width > 0, frame.height > 0 else { return (frame, currentScale) }
        let requestedScale = min(max(currentScale * factor, 0.25), 3)
        // Bound one common ratio. Clamping width and height independently
        // changes aspect ratio and compounds size drift after zooming back in.
        let smallestRatio = max(160 / frame.width, 180 / frame.height)
        let largestRatio = min(1600 / frame.width, 1800 / frame.height)
        let ratio = min(max(requestedScale / currentScale, smallestRatio), largestRatio)
        let width = frame.width * ratio, height = frame.height * ratio
        return (CGRect(x: frame.midX - width / 2, y: frame.minY, width: width, height: height), currentScale * ratio)
    }
}

struct ModelInstanceSettings: Codable, Identifiable, Equatable {
    var id = UUID()
    var displayName: String
    var modelPath: String
    var windowFrame = WindowFrame()
    var scale: Double = 1
    var isVisible = true
    var trackingEnabled = true
    var trackingSmoothingSeconds: Double = 0.14
    var interactionMode: InteractionMode = .passthrough
    var targetFPS = 30
    var animationPaused = false
    var idleMotionGroup: String?
    var expressionId: String?
    var zOrder = 0

    init(displayName: String, modelPath: String) {
        self.displayName = displayName; self.modelPath = modelPath
    }
    enum CodingKeys: String, CodingKey {
        case id, displayName, modelPath, windowFrame, scale, isVisible, trackingEnabled,
             trackingSmoothingSeconds, interactionMode, targetFPS, animationPaused, idleMotionGroup, expressionId, zOrder
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        displayName = (try? c.decode(String.self, forKey: .displayName)) ?? "模型"
        modelPath = try c.decode(String.self, forKey: .modelPath)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        windowFrame = (try? c.decode(WindowFrame.self, forKey: .windowFrame)) ?? WindowFrame()
        scale = (try? c.decode(Double.self, forKey: .scale)) ?? 1
        isVisible = (try? c.decode(Bool.self, forKey: .isVisible)) ?? true
        trackingEnabled = (try? c.decode(Bool.self, forKey: .trackingEnabled)) ?? true
        trackingSmoothingSeconds = (try? c.decode(Double.self, forKey: .trackingSmoothingSeconds)) ?? 0.14
        interactionMode = (try? c.decode(InteractionMode.self, forKey: .interactionMode)) ?? .passthrough
        targetFPS = (try? c.decode(Int.self, forKey: .targetFPS)) ?? 30
        animationPaused = (try? c.decode(Bool.self, forKey: .animationPaused)) ?? false
        idleMotionGroup = try? c.decode(String.self, forKey: .idleMotionGroup)
        expressionId = try? c.decode(String.self, forKey: .expressionId)
        zOrder = (try? c.decode(Int.self, forKey: .zOrder)) ?? 0
        sanitize()
    }
    mutating func sanitize() {
        if displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { displayName = "模型" }
        windowFrame.sanitize()
        scale = scale.isFinite ? min(max(scale, 0.25), 3) : 1
        trackingSmoothingSeconds = trackingSmoothingSeconds.isFinite ? min(max(trackingSmoothingSeconds, 0.03), 1) : 0.14
        targetFPS = targetFPS == 60 ? 60 : 30
        zOrder = min(max(zOrder, 0), 1_000_000)
    }
}

struct AppSettings: Codable {
    var schemaVersion = 2
    var instances: [ModelInstanceSettings] = []
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = (try? c.decode(Int.self, forKey: .schemaVersion)) ?? 1
        // Decode entries separately so one malformed item cannot discard others.
        if var items = try? c.nestedUnkeyedContainer(forKey: .instances) {
            while !items.isAtEnd {
                let itemDecoder = try items.superDecoder()
                if let entry = try? ModelInstanceSettings(from: itemDecoder) { instances.append(entry) }
            }
        }
        if instances.isEmpty, let legacy = try? c.decode(String.self, forKey: .modelPath) {
            instances = [ModelInstanceSettings(displayName: "模型", modelPath: legacy)]
        }
        var seen = Set<UUID>()
        for i in instances.indices {
            if !seen.insert(instances[i].id).inserted { instances[i].id = UUID(); seen.insert(instances[i].id) }
            instances[i].sanitize()
        }
        schemaVersion = 2
    }
    enum CodingKeys: String, CodingKey { case schemaVersion, instances, modelPath }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(instances, forKey: .instances)
    }
}
