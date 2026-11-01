import Foundation

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
        precondition(old.schemaVersion == 2 && old.instances.count == 1)
        try Data("invalid JSON".utf8).write(to: store.url)
        precondition(store.load().instances.isEmpty && store.lastError != nil)
        let backups = try FileManager.default.contentsOfDirectory(at: store.url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        precondition(backups.contains { $0.lastPathComponent.contains("corrupt-") })
        for name in ["bilibili-22", "bilibili-33"] {
            let validated = try ModelFileValidator.validate(root.appendingPathComponent(".local/models/\(name)/model.json"))
            precondition(validated.legacy)
        }
        let native = try ModelFileValidator.validate(root.appendingPathComponent("vendor/CubismNativeSamples/Samples/Resources/Hiyori/Hiyori.model3.json"))
        precondition(!native.legacy)
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
