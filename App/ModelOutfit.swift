import Foundation

struct ModelOutfit: Equatable, Codable {
    // Empty ID selects the original entry. Other IDs are relative to its directory.
    let id: String
    let name: String
    var generatedName: GeneratedName?
    var localizedName: String { generatedName?.text ?? name }
}

enum ModelOutfitCatalog {
    static func sidecar(_ entry: URL) -> URL { entry.appendingPathExtension("lite2d-outfits.json") }
    static func resolve(_ id: String, relativeTo entry: URL) throws -> URL {
        let root = entry.standardizedFileURL.resolvingSymlinksInPath().deletingLastPathComponent()
        guard !id.isEmpty, !id.hasPrefix("/"), URL(string: id)?.scheme == nil else {
            throw invalid(.key("error.outfit_reference", []))
        }
        let target = root.appendingPathComponent(id).standardizedFileURL.resolvingSymlinksInPath()
        guard target.path.hasPrefix(root.path + "/") else { throw invalid(.key("error.outfit_escape", [])) }
        return target
    }

    static func load(_ entry: URL) throws -> [ModelOutfit] {
        if FileManager.default.fileExists(atPath: sidecar(entry).path) {
            let data = try Data(contentsOf: sidecar(entry))
            guard data.count < 8 * 1024 * 1024 else { throw invalid(.key("error.outfit_size", [])) }
            let outfits = try JSONDecoder().decode([ModelOutfit].self, from: data)
            guard outfits.first?.id == "", Set(outfits.map(\.id)).count == outfits.count else { throw invalid(.key("error.outfit_catalog", [])) }
            for outfit in outfits where !outfit.id.isEmpty { _ = try resolve(outfit.id, relativeTo: entry) }
            return outfits
        }
        let json = try object(entry)
        let groups = json["motions"] as? [String: [[String: Any]]] ?? [:]
        var names: [String: String] = [:]
        // ViewerEX choice labels carry the author's outfit names and ordering.
        var orderedGroups: [String] = []
        for group in groups.keys.sorted() {
            for motion in groups[group] ?? [] {
                for choice in motion["choices"] as? [[String: Any]] ?? [] {
                    if let next = choice["next_mtn"] as? String, let title = choice["text"] as? String,
                       names[next] == nil {
                        names[next] = title; orderedGroups.append(next)
                    }
                }
            }
        }
        orderedGroups += groups.keys.filter { !orderedGroups.contains($0) }.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        var result = [ModelOutfit(id: "", name: "Default", generatedName: GeneratedName(key: "common.default"))]
        var seen = Set<String>()
        for group in orderedGroups {
            for motion in groups[group] ?? [] {
                guard let command = motion["command"] as? String else { continue }
                let tokens = command.split(whereSeparator: { $0.isWhitespace })
                // Interpret only this declarative reference; never execute commands/scripts.
                guard tokens.count == 2, tokens[0] == "change_cos" else { continue }
                var target = try resolve(String(tokens[1]), relativeTo: entry)
                // Older prepared caches renamed .bin JSONs but left command strings intact.
                if !FileManager.default.fileExists(atPath: target.path), target.pathExtension == "bin" || target.pathExtension == "bin3" {
                    target = try resolve((String(tokens[1]) as NSString).deletingPathExtension + ".json", relativeTo: entry)
                }
                guard let costume = try? object(target),
                      costume["model"] is String || costume["FileReferences"] is [String: Any] else { continue }
                let root = entry.standardizedFileURL.resolvingSymlinksInPath().deletingLastPathComponent()
                let relative = String(target.path.dropFirst(root.path.count + 1))
                let name = names[group] ?? (costume["options"] as? [String: Any])?["name"] as? String ?? group
                let sameModel = (costume["model"] as? String) == (json["model"] as? String)
                let sameTextures = (costume["textures"] as? [String]) == (json["textures"] as? [String])
                let isOriginal = target == entry.standardizedFileURL.resolvingSymlinksInPath() ||
                    (json["model"] is String && sameModel && sameTextures)
                if isOriginal { result[0] = ModelOutfit(id: "", name: name); continue }
                if seen.insert(relative).inserted { result.append(ModelOutfit(id: relative, name: name)) }
            }
        }
        return result
    }

    static func selectedURL(entry: URL, outfitID: String?, outfits: [ModelOutfit]) throws -> URL {
        guard let id = outfitID, !id.isEmpty else { return entry }
        guard outfits.contains(where: { $0.id == id }) else { throw invalid(.key("error.outfit_missing", [])) }
        return try resolve(id, relativeTo: entry)
    }

    private static func object(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard data.count < 8 * 1024 * 1024,
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw invalid(.key("error.outfit_json", []))
        }
        return value
    }
    private static func invalid(_ message: LocalizedMessage) -> LocalizedFailure {
        LocalizedFailure(message: message)
    }
}
