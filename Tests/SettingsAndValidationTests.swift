import Foundation
import CoreGraphics

@main struct Tests {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Lite2D-tests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let payload: [String: Any] = ["schemaVersion": 2, "unknownFutureField": true, "instances": [
            ["id": id.uuidString, "displayName": "22", "modelPath": "/model-a", "targetFPS": 144, "scale": -3],
            ["id": id.uuidString, "displayName": "33", "modelPath": "/model-b", "trackingEnabled": false],
            ["id": UUID().uuidString, "displayName": "bad"],
            ["id": "broken UUID", "displayName": "duplicate asset", "modelPath": "/model-a", "isVisible": false]
        ]]
        let settings = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: payload))
        precondition(settings.instances.count == 3, "Bad entry must not discard valid entries")
        precondition(Set(settings.instances.map(\.id)).count == 3, "Duplicate and malformed UUIDs must be repaired")
        precondition(settings.instances[0].targetFPS == 30 && settings.instances[0].scale == 0.25)
        precondition(!settings.instances[1].trackingEnabled && !settings.instances[2].isVisible)
        let store = SettingsStore(url: directory.appendingPathComponent("nested/settings.json"))
        store.save(settings)
        precondition(store.load().instances == settings.instances, "All independent state must round-trip")
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"modelPath":"/old"}"#.utf8))
        precondition(old.schemaVersion == 3 && old.instances.count == 1)
        try Data("invalid JSON".utf8).write(to: store.url)
        precondition(store.load().instances.isEmpty && store.lastError != nil)
        let backups = try FileManager.default.contentsOfDirectory(at: store.url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        precondition(backups.contains { $0.lastPathComponent.contains("corrupt-") })
        for name in ["legacy-a", "legacy-b"] {
            let validated = try ModelFileValidator.validate(root.appendingPathComponent(".local/models/\(name)/model.json"))
            precondition(validated.legacy)
        }
        let native = try ModelFileValidator.validate(root.appendingPathComponent("vendor/CubismNativeSamples/Samples/Resources/Hiyori/Hiyori.model3.json"))
        precondition(!native.legacy)
        let minimal = try ModelFileValidator.validate(root.appendingPathComponent(".local/verification/fixtures/native-minimal/model.model3.json"))
        precondition(!minimal.legacy && minimal.warnings.isEmpty)
        for name in ["native-missing-moc", "native-missing-texture"] {
            do {
                _ = try ModelFileValidator.validate(root.appendingPathComponent(".local/verification/fixtures/\(name)/model.model3.json"))
                fatalError("Missing required native resource must be rejected")
            } catch { /* Both fail before entering the SDK. */ }
        }
        var extreme = ModelInstanceSettings(displayName: "extreme", modelPath: "/model")
        extreme.windowFrame.x = Double.greatestFiniteMagnitude
        extreme.windowFrame.y = -Double.greatestFiniteMagnitude
        extreme.zOrder = Int.max
        extreme.sanitize()
        precondition(extreme.windowFrame.x == 1_000_000 && extreme.windowFrame.y == -1_000_000 && extreme.zOrder == 1_000_000)
        var zoomFrame = CGRect(x: -500, y: 80, width: 360, height: 480)
        var zoomScale = 1.0
        for factor in [0.01, 100.0, 0.01, 100.0, 0.01, 100.0] {
            let resized = ZoomGeometry.resize(frame: zoomFrame, currentScale: zoomScale, factor: factor)
            precondition(abs(resized.frame.width / resized.frame.height - 0.75) < 0.0001, "Zoom limits must preserve model window aspect")
            precondition(resized.frame.width >= 160 && resized.frame.height >= 180 && resized.frame.width <= 1600 && resized.frame.height <= 1800)
            precondition(abs(resized.frame.midX - zoomFrame.midX) < 0.0001 && resized.frame.minY == zoomFrame.minY)
            zoomFrame = resized.frame; zoomScale = resized.scale
        }
        let first = DisplayDescriptor(id: "physical-A", name: "A", frame: CGRect(x: 0, y: 0, width: 1920, height: 1280), visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1255))
        let second = DisplayDescriptor(id: "physical-B", name: "B", frame: CGRect(x: -1080, y: -625, width: 1080, height: 1920), visibleFrame: CGRect(x: -1080, y: -625, width: 1080, height: 1895))
        var bound = ModelInstanceSettings(displayName: "bound", modelPath: "/model")
        bound.displayUUID = first.id; bound.boundDisplayName = first.name
        bound.displayPosition = DisplayPosition(x: 80, y: 50)
        precondition(DisplayLayout.windowFrame(for: bound, in: [first, second])?.origin == CGPoint(x: 80, y: 50))
        precondition(DisplayLayout.windowFrame(for: bound, in: [second]) == nil, "Disconnected target must never fall back to another display")
        let movedDisplay = DisplayDescriptor(id: first.id, name: first.name, frame: CGRect(x: 2160, y: -400, width: 1920, height: 1280), visibleFrame: CGRect(x: 2160, y: -400, width: 1920, height: 1255))
        precondition(DisplayLayout.windowFrame(for: bound, in: [second, movedDisplay])?.origin == CGPoint(x: 2240, y: -350), "Identity and local position survive screen reorder")
        let boundRoundTrip = try JSONDecoder().decode(ModelInstanceSettings.self, from: JSONEncoder().encode(bound))
        precondition(boundRoundTrip.displayUUID == first.id && boundRoundTrip.displayPosition == bound.displayPosition)
        let fixture = directory.appendingPathComponent("model.json")
        func rejects(_ json: [String: Any]) throws {
            try JSONSerialization.data(withJSONObject: json).write(to: fixture)
            do { _ = try ModelFileValidator.validate(fixture); fatalError("Expected invalid model to be rejected") }
            catch { /* Expected: rejected before passing untrusted paths to SDK. */ }
        }
        try rejects(["model": "../outside.moc", "textures": ["x.png"]])
        try rejects(["model": "https://example.com/model.moc", "textures": ["x.png"]])
        try rejects(["model": "/etc/passwd", "textures": ["x.png"]])
        try Data(repeating: 0, count: 64).write(to: directory.appendingPathComponent("bad.moc"))
        try rejects(["model": "bad.moc", "textures": ["x.png"]])
        print("PASS: settings repair/migration/round-trip/corruption backup; actual legacy/native validation; unsafe path/bad binary rejection")
    }
}
