import Foundation

struct ValidatedModel {
    let url: URL
    let legacy: Bool
    let warnings: [LocalizedMessage]
}

enum ModelFileValidator {
    static func validate(_ url: URL) throws -> ValidatedModel {
        let entry = url.standardizedFileURL.resolvingSymlinksInPath()
        let root = entry.deletingLastPathComponent()
        func invalid(_ message: LocalizedMessage) -> LocalizedFailure {
            LocalizedFailure(message: message)
        }
        guard entry.isFileURL else { throw invalid(.key("error.local_json", [])) }
        let data = try Data(contentsOf: entry)
        guard data.count < 8 * 1024 * 1024,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw invalid(.key("error.model_json", []))
        }
        let refs = json["FileReferences"] as? [String: Any]
        let legacy = refs == nil && json["model"] is String
        guard legacy || refs != nil else { throw invalid(.key("error.model_format", [])) }
        func resolve(_ name: String) throws -> URL {
            guard !name.isEmpty, !name.hasPrefix("/"), URL(string: name)?.scheme == nil else {
                throw invalid(.key("error.model_reference", [.literal(name)]))
            }
            let path = root.appendingPathComponent(name).standardizedFileURL.resolvingSymlinksInPath()
            guard path.path.hasPrefix(root.path + "/") else {
                throw invalid(.key("error.model_escape", [.literal(name)]))
            }
            return path
        }
        guard let model = (legacy ? json["model"] : refs?["Moc"]) as? String else {
            throw invalid(.key("error.missing_moc", []))
        }
        let binary = try Data(contentsOf: resolve(model), options: .mappedIfSafe)
        let magic = Array(binary.prefix(4))
        guard binary.count > 32, legacy ? Array(magic.prefix(3)) == [109, 111, 99] : magic == [77, 79, 67, 51] else {
            throw invalid(.key("error.moc_version", []))
        }
        guard let textures = (legacy ? json["textures"] : refs?["Textures"]) as? [String], !textures.isEmpty else {
            throw invalid(.key("error.texture_list", []))
        }
        for name in textures {
            let texture = try resolve(name)
            guard FileManager.default.isReadableFile(atPath: texture.path) else {
                throw invalid(.key("error.missing_texture", [.literal(name)]))
            }
        }
        var optional: [String] = []
        for key in legacy ? ["physics", "pose"] : ["Physics", "Pose", "UserData"] {
            if let value = (legacy ? json[key] : refs?[key]) as? String, !value.isEmpty { optional.append(value) }
        }
        let groups = (legacy ? json["motions"] : refs?["Motions"]) as? [String: [[String: Any]]] ?? [:]
        for list in groups.values {
            for item in list {
                if let value = item[legacy ? "file" : "File"] as? String { optional.append(value) }
            }
        }
        let expressions = (legacy ? json["expressions"] : refs?["Expressions"]) as? [[String: Any]] ?? []
        for item in expressions {
            if let value = item[legacy ? "file" : "File"] as? String { optional.append(value) }
        }
        var warnings: [LocalizedMessage] = []
        for name in optional {
            let path = try resolve(name)
            if !FileManager.default.isReadableFile(atPath: path.path) { warnings.append(.key("error.optional_asset", [.literal(name)])) }
        }
        return ValidatedModel(url: entry, legacy: legacy, warnings: warnings)
    }
}
