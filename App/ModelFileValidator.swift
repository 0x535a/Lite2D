import Foundation

struct ValidatedModel {
    let url: URL
    let legacy: Bool
    let warnings: [String]
}

enum ModelFileValidator {
    static func validate(_ url: URL) throws -> ValidatedModel {
        let entry = url.standardizedFileURL.resolvingSymlinksInPath()
        let root = entry.deletingLastPathComponent()
        func invalid(_ message: String) -> NSError {
            NSError(domain: "Lite2D.Model", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        guard entry.isFileURL else { throw invalid("请选择本机模型 JSON 文件。") }
        let data = try Data(contentsOf: entry)
        guard data.count < 8 * 1024 * 1024,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw invalid("模型描述不是有效的 JSON 对象。")
        }
        let refs = json["FileReferences"] as? [String: Any]
        let legacy = refs == nil && json["model"] is String
        guard legacy || refs != nil else { throw invalid("不支持的模型格式：需要 Cubism 2 或 Cubism 3+ 模型描述。") }
        func resolve(_ name: String) throws -> URL {
            guard !name.isEmpty, !name.hasPrefix("/"), URL(string: name)?.scheme == nil else {
                throw invalid("模型引用必须是本目录内的相对路径：\(name)")
            }
            let path = root.appendingPathComponent(name).standardizedFileURL.resolvingSymlinksInPath()
            guard path.path.hasPrefix(root.path + "/") else {
                throw invalid("模型资源超出资产目录：\(name)")
            }
            return path
        }
        guard let model = (legacy ? json["model"] : refs?["Moc"]) as? String else {
            throw invalid("模型描述中缺少 Moc 引用。")
        }
        let binary = try Data(contentsOf: resolve(model), options: .mappedIfSafe)
        let magic = Array(binary.prefix(4))
        guard binary.count > 32, legacy ? Array(magic.prefix(3)) == [109, 111, 99] : magic == [77, 79, 67, 51] else {
            throw invalid("模型二进制与描述的 Cubism 版本不符或已损坏。")
        }
        guard let textures = (legacy ? json["textures"] : refs?["Textures"]) as? [String], !textures.isEmpty else {
            throw invalid("模型没有有效的纹理列表。")
        }
        for name in textures {
            let texture = try resolve(name)
            guard FileManager.default.isReadableFile(atPath: texture.path) else {
                throw invalid("缺少必要纹理：\(name)")
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
        var warnings: [String] = []
        for name in optional {
            let path = try resolve(name)
            if !FileManager.default.isReadableFile(atPath: path.path) { warnings.append("可选资源缺失：\(name)") }
        }
        return ValidatedModel(url: entry, legacy: legacy, warnings: warnings)
    }
}
