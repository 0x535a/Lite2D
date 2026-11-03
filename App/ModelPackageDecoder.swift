import Foundation
import CryptoKit

// ViewerEX package compatibility is isolated from the player and model library.
enum ModelPackageDecoder {
    static func decode(in root: URL) throws -> [(String, URL, GeneratedName?)] {
        try decode(in: root, depth: 0)
    }

    private static func decode(in root: URL, depth: Int) throws -> [(String, URL, GeneratedName?)] {
        let files = try ModelLibraryImporter.files(in: root)
        let metadataName = Insecure.MD5.hash(data: Data("config.mlve".utf8)).map { String(format: "%02x", $0) }.joined()
        let configs = files.filter { ["config.json", ".lite2d-ex-source.json"].contains($0.lastPathComponent) }
        let manifests = files.filter { $0.lastPathComponent == metadataName || $0.lastPathComponent == "config.mlve" }
        guard manifests.count <= 1 else { throw ModelImportError.invalid(.key("error.multiple_manifests", [])) }
        if let metadataURL = manifests.first {
            let metadata = try ModelLibraryImporter.object(metadataURL)
            guard let list = metadata["list"] as? [[String: Any]], !list.isEmpty else {
                throw ModelImportError.invalid(.key("error.lpk_list", []))
            }
            let parent = metadataURL.deletingLastPathComponent()
            let config = configs.compactMap { try? ModelLibraryImporter.object($0) }.first { $0["metaData"] != nil } ?? [:]
            let encrypted = String(describing: metadata["encrypt"] ?? "false").lowercased() == "true" || (metadata["encrypt"] as? Bool == true)
            if encrypted && (config["metaData"] as? String == nil || config["fileId"] as? String == nil) {
                throw ModelImportError.invalid(.key("error.lpk_config", []))
            }
            let payloads = try ModelLibraryImporter.files(in: parent).filter { ["bin", "bin3"].contains($0.pathExtension.lowercased()) }
            guard !payloads.isEmpty else { throw ModelImportError.invalid(.key("error.lpk_resources", [])) }
            var fileID = config["fileId"] as? String ?? ""
            if encrypted {
                guard let firstCostume = (list.first?["costume"] as? [[String: Any]])?.first,
                      let firstPath = firstCostume["path"] as? String else { throw ModelImportError.invalid(.key("error.lpk_entry", [])) }
                let firstURL = try ModelOutfitCatalog.resolve(firstPath, relativeTo: metadataURL)
                let firstData = try Data(contentsOf: firstURL)
                let fallback = ((config["lpkFile"] as? String ?? "") as NSString).deletingPathExtension
                let ids = [fileID, fallback]
                guard let matched = ids.first(where: { candidate in
                    let seed = rollingKey((metadata["id"] as? String ?? "") + candidate + firstPath + (config["metaData"] as? String ?? ""))
                    let data = decodeBytes(firstData, seed: seed)
                    guard data.count < 8 * 1024 * 1024, let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
                    return object["model"] is String || object["FileReferences"] is [String: Any] || object["type"] != nil
                }) else { throw ModelImportError.invalid(.key("error.lpk_decode", [])) }
                fileID = matched
            }
            let output = parent.appendingPathComponent(".lite2d-decoded", isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            var mapping: [String: String] = [:], jsons: [String: Any] = [:]
            for file in payloads {
                let key = ModelLibraryImporter.relative(file, to: parent)
                var data = try Data(contentsOf: file)
                if encrypted {
                    let seed = rollingKey((metadata["id"] as? String ?? "") + fileID + key + (config["metaData"] as? String ?? ""))
                    data = decodeBytes(data, seed: seed)
                }
                var suffix = "dat"
                if data.starts(with: [77, 79, 67, 51]) { suffix = "moc3" }
                else if data.starts(with: [109, 111, 99]) { suffix = "moc" }
                else if data.starts(with: [137, 80, 78, 71]) { suffix = "png" }
                else if data.starts(with: [255, 216]) { suffix = "jpg" }
                if data.count < 8 * 1024 * 1024, let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
                    jsons[key] = object; suffix = "json"
                }
                // Flat stable names avoid collisions between assets in nested package directories.
                let stem = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
                let name = "\(stem).\(suffix)"
                mapping[key] = name
                try data.write(to: output.appendingPathComponent(name))
            }
            func remap(_ value: Any) -> Any {
                if let text = value as? String {
                    let tokens = text.split(whereSeparator: { $0.isWhitespace })
                    if tokens.count == 2, tokens[0] == "change_cos", let target = mapping[String(tokens[1])] { return "change_cos \(target)" }
                    return mapping[text] ?? text
                }
                if let array = value as? [Any] { return array.map(remap) }
                if let object = value as? [String: Any] { return object.mapValues(remap) }
                return value
            }
            for (key, object) in jsons {
                try JSONSerialization.data(withJSONObject: remap(object), options: [.fragmentsAllowed, .sortedKeys, .prettyPrinted])
                    .write(to: output.appendingPathComponent(mapping[key]!))
            }
            var result: [(String, URL, GeneratedName?)] = []
            for (index, character) in list.enumerated() {
                guard let costumes = character["costume"] as? [[String: Any]], !costumes.isEmpty else {
                    throw ModelImportError.invalid(.key("error.lpk_outfits", []))
                }
                var costumeEntries: [(String, URL, GeneratedName?)] = []
                for (costumeIndex, costume) in costumes.enumerated() {
                    guard let path = costume["path"] as? String, let mapped = mapping[path], jsons[path] is [String: Any] else {
                        throw ModelImportError.invalid(.key("error.lpk_outfit_read", []))
                    }
                    let entry = output.appendingPathComponent(mapped)
                    // Reject Spine and corrupted/decryption-mismatched entries explicitly.
                    let object = try ModelLibraryImporter.object(entry)
                    guard object["model"] is String || object["FileReferences"] is [String: Any] else {
                        throw ModelImportError.invalid(.key("error.non_live2d", []))
                    }
                    costumeEntries.append((costume["name"] as? String ?? "Outfit \(costumeIndex + 1)", entry,
                                           costume["name"] is String ? nil : GeneratedName(key: "outfit.fallback", arguments: [String(costumeIndex + 1)])))
                }
                // Each character gets its own entry and outfit catalog, even when assets are shared.
                let first = costumeEntries[0]
                let entry = output.appendingPathComponent("character-\(index).json")
                try FileManager.default.copyItem(at: first.1, to: entry)
                var outfits = [ModelOutfit(id: "", name: first.0, generatedName: first.2)]
                outfits += costumeEntries.dropFirst().map { ModelOutfit(id: $0.1.lastPathComponent, name: $0.0, generatedName: $0.2) }
                // Preserve old change_cos costumes as well when the manifest exposes only one costume.
                let existing = try ModelOutfitCatalog.load(entry)
                for outfit in existing where !outfit.id.isEmpty && !outfits.contains(where: { $0.id == outfit.id }) { outfits.append(outfit) }
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                try encoder.encode(outfits).write(to: ModelOutfitCatalog.sidecar(entry))
                let name = character["character"] as? String ?? character["name"] as? String ?? "Character \(index + 1)"
                let title = (list.count == 1 && name == "character") ? (config["title"] as? String ?? metadata["name"] as? String ?? name) : name
                let generatedName = character["character"] is String || character["name"] is String ? nil : GeneratedName(key: "role.fallback", arguments: [String(index + 1)])
                result.append((title, entry, generatedName))
            }
            // Keep only normalized assets plus package metadata (not duplicate encoded payloads).
            for file in payloads { try FileManager.default.removeItem(at: file) }
            try FileManager.default.moveItem(at: metadataURL, to: parent.appendingPathComponent(".lite2d-source-manifest.json"))
            for configURL in configs {
                let target = configURL.deletingLastPathComponent().appendingPathComponent(".lite2d-source-config.json")
                try FileManager.default.moveItem(at: configURL, to: target)
            }
            return result
        }

        // WPK wrappers and installed Workshop directories: config.json references the inner LPK.
        var result: [(String, URL, GeneratedName?)] = []
        for configURL in configs where configURL.lastPathComponent == "config.json" {
            let config = try ModelLibraryImporter.object(configURL)
            guard let packageName = config["lpkFile"] as? String else { continue }
            guard depth < 1 else { throw ModelImportError.invalid(.key("error.package_depth", [])) }
            let package = try ModelOutfitCatalog.resolve(packageName, relativeTo: configURL)
            let inner = configURL.deletingLastPathComponent().appendingPathComponent(".lite2d-package", isDirectory: true)
            try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
            try L2DModelArchive.extract(path: package.path, toDirectory: inner.path)
            try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]).write(to: inner.appendingPathComponent(".lite2d-ex-source.json"))
            let decoded = try decode(in: inner, depth: depth + 1)
            guard !decoded.isEmpty else { throw ModelImportError.invalid(.key("error.wpk_layout", [])) }
            result += decoded
            try FileManager.default.removeItem(at: package)
            try FileManager.default.moveItem(at: configURL, to: configURL.deletingLastPathComponent().appendingPathComponent(".lite2d-source-config.json"))
        }
        return result
    }

    private static func rollingKey(_ string: String) -> UInt32 {
        // Match EX's UTF-16 character hashing, including non-ASCII metadata.
        string.utf16.reduce(UInt32(0)) { ($0 &* 31) &+ UInt32($1) }
    }
    private static func decodeBytes(_ data: Data, seed: UInt32) -> Data {
        var bytes = Array(data)
        for offset in stride(from: 0, to: bytes.count, by: 1024) {
            var state = UInt64(seed)
            for index in offset..<min(offset + 1024, bytes.count) {
                state = ((2531011 + 214013 * state) >> 16) & 65535
                bytes[index] ^= UInt8(state & 255)
            }
        }
        return Data(bytes)
    }
}
