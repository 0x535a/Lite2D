import Foundation
import CryptoKit

struct ImportedCharacter {
    let name: String
    let entry: URL
    let outfitCount: Int
    var generatedName: GeneratedName? = nil
    var localizedName: String { generatedName?.text ?? name }
}

enum ModelImportError {
    static func invalid(_ message: LocalizedMessage) -> LocalizedFailure {
        LocalizedFailure(message: message)
    }
    static func invalid(_ message: String) -> LocalizedFailure { invalid(.literal(message)) }
}

// A preparation is private and disposable. No model-library changes until commit.
final class ModelImportPreparation {
    let directory: URL
    let characters: [ImportedCharacter]
    let warnings: [LocalizedMessage]
    let sourceName: String
    init(directory: URL, characters: [ImportedCharacter], warnings: [LocalizedMessage], sourceName: String) {
        self.directory = directory; self.characters = characters; self.warnings = warnings; self.sourceName = sourceName
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
}

final class ModelLibraryImporter {
    let library: URL
    private let fm = FileManager.default
    static let limit = 512 * 1024 * 1024
    init(library: URL? = nil) {
        let override = ProcessInfo.processInfo.environment["LITE2D_MODEL_LIBRARY_PATH"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        let defaultURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lite2D/Models", isDirectory: true)
        self.library = (library ?? override ?? defaultURL).standardizedFileURL.resolvingSymlinksInPath()
    }

    func prepare(_ source: URL) throws -> ModelImportPreparation {
        guard source.isFileURL else { throw ModelImportError.invalid(.key("error.local_file", [])) }
        let stage = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("Lite2D-import-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        do {
            let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw ModelImportError.invalid(.key("error.import_symlink", [])) }
            var explicitEntry: URL?
            if values.isDirectory == true {
                try copyDirectory(source, to: stage)
            } else if ["zip", "lpk", "wpk"].contains(source.pathExtension.lowercased()) {
                try L2DModelArchive.extract(path: source.path, toDirectory: stage.path)
                // Workshop-linked LPKs may need the adjacent EX config; never modify it.
                if source.pathExtension.lowercased() == "lpk" {
                    let config = source.deletingLastPathComponent().appendingPathComponent("config.json")
                    if let object = try? Self.object(config), object["lpkFile"] as? String == source.lastPathComponent {
                        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: stage.appendingPathComponent(".lite2d-ex-source.json"))
                    }
                }
            } else if source.pathExtension.lowercased() == "json" {
                // Check the selected file before copying its directory (e.g. an accidental motion JSON).
                _ = try ModelFileValidator.validate(source)
                try copyDirectory(source.deletingLastPathComponent(), to: stage)
                explicitEntry = stage.appendingPathComponent(source.lastPathComponent)
            } else {
                throw ModelImportError.invalid(.key("error.import_format", []))
            }
            let packaged = explicitEntry == nil ? try ModelPackageDecoder.decode(in: stage) : []
            let stagedFiles = try Self.files(in: stage)
            let stagedSize = try stagedFiles.reduce(0) { try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
            guard stagedSize <= Self.limit else { throw ModelImportError.invalid(.key("error.staged_size", [])) }
            let entries: [(String, URL, GeneratedName?)]
            if !packaged.isEmpty { entries = packaged }
            else if let explicitEntry {
                _ = try discover(in: stage, rootName: source.deletingLastPathComponent().lastPathComponent)
                let label = (try? Self.object(explicitEntry))?["label"] as? String
                entries = [(label ?? source.deletingLastPathComponent().lastPathComponent, explicitEntry, nil)]
            }
            else { entries = try discover(in: stage, rootName: values.isDirectory == true ? source.lastPathComponent : source.deletingPathExtension().lastPathComponent) }
            var characters: [ImportedCharacter] = [], warnings: [LocalizedMessage] = []
            for (name, entry, generatedName) in entries {
                do {
                    let valid = try ModelFileValidator.validate(entry)
                    let outfits = try ModelOutfitCatalog.load(entry)
                    for outfit in outfits where !outfit.id.isEmpty {
                        _ = try ModelFileValidator.validate(ModelOutfitCatalog.resolve(outfit.id, relativeTo: entry))
                    }
                    let label: LocalizedMessage = generatedName.map { .key($0.key, $0.arguments.map { .literal($0) }) } ?? .literal(name)
                    warnings += valid.warnings.map { .key("format.named_detail", [label, $0]) }
                    characters.append(ImportedCharacter(name: name, entry: entry, outfitCount: max(1, outfits.count), generatedName: generatedName))
                } catch { warnings.append(.key("format.named_detail", [generatedName.map { .key($0.key, $0.arguments.map { .literal($0) }) } ?? .literal(name), .failure(error)])) }
            }
            guard !characters.isEmpty else {
                throw ModelImportError.invalid(warnings.isEmpty ? .key("error.no_models", []) : .joined(warnings, "\n"))
            }
            return ModelImportPreparation(directory: stage, characters: characters, warnings: warnings, sourceName: source.lastPathComponent)
        } catch { try? fm.removeItem(at: stage); throw error }
    }

    func commit(_ preparation: ModelImportPreparation, indices: [Int]) throws -> [ImportedCharacter] {
        guard !indices.isEmpty, indices.allSatisfy({ preparation.characters.indices.contains($0) }) else { return [] }
        let files = try Self.files(in: preparation.directory)
        var digest = SHA256()
        for url in files {
            let relative = Self.relative(url, to: preparation.directory)
            var pathLength = UInt64(relative.utf8.count).bigEndian
            var fileLength = UInt64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0).bigEndian
            withUnsafeBytes(of: &pathLength) { digest.update(data: Data($0)) }
            digest.update(data: Data(relative.utf8))
            withUnsafeBytes(of: &fileLength) { digest.update(data: Data($0)) }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            while let data = try handle.read(upToCount: 65536), !data.isEmpty { digest.update(data: data) }
        }
        let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
        try fm.createDirectory(at: library, withIntermediateDirectories: true)
        let destination = library.appendingPathComponent(hash, isDirectory: true)
        let resources = destination.appendingPathComponent("resources", isDirectory: true)
        if !fm.fileExists(atPath: destination.path) {
            let pending = library.appendingPathComponent(".pending-\(UUID().uuidString)", isDirectory: true)
            defer { try? fm.removeItem(at: pending) }
            try fm.createDirectory(at: pending, withIntermediateDirectories: true)
            try fm.copyItem(at: preparation.directory, to: pending.appendingPathComponent("resources"))
            let receipt: [String: Any] = ["schemaVersion": 1, "sha256": hash, "sourceName": preparation.sourceName,
                "characters": preparation.characters.map { ["name": $0.name, "entry": Self.relative($0.entry, to: preparation.directory)] }]
            try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
                .write(to: pending.appendingPathComponent("receipt.json"), options: .atomic)
            try fm.moveItem(at: pending, to: destination)
        }
        return try indices.map {
            let original = preparation.characters[$0]
            let entry = resources.appendingPathComponent(Self.relative(original.entry, to: preparation.directory))
            _ = try ModelFileValidator.validate(entry)
            return ImportedCharacter(name: original.name, entry: entry, outfitCount: original.outfitCount, generatedName: original.generatedName)
        }
    }

    private func copyDirectory(_ source: URL, to stage: URL) throws {
        var total = 0
        for file in try Self.files(in: source) {
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            total += size
            guard total <= Self.limit else { throw ModelImportError.invalid(.key("error.directory_size", [])) }
            let target = stage.appendingPathComponent(Self.relative(file, to: source))
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: file, to: target)
        }
    }

    private func discover(in root: URL, rootName: String) throws -> [(String, URL, GeneratedName?)] {
        var entries: [URL] = []
        for file in try Self.files(in: root) where file.pathExtension.lowercased() == "json" {
            if file.deletingLastPathComponent().lastPathComponent == ".lite2d-decoded",
               !fm.fileExists(atPath: ModelOutfitCatalog.sidecar(file).path) { continue }
            guard !file.lastPathComponent.hasSuffix(".lite2d-outfits.json"),
                  let object = try? Self.object(file), object["model"] is String || object["FileReferences"] is [String: Any] else { continue }
            entries.append(file)
        }
        // Exported texture costumes may have no EX commands. Only group siblings
        // sharing the exact binary and an explicit nonempty character label.
        // Never merge separate directories or unrelated models by filename.
        var labeled: [String: [URL]] = [:]
        for entry in entries where !fm.fileExists(atPath: ModelOutfitCatalog.sidecar(entry).path) {
            guard let object = try? Self.object(entry),
                  let label = object["label"] as? String, !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let binary = object["model"] as? String ?? (object["FileReferences"] as? [String: Any])?["Moc"] as? String,
                  let target = try? ModelOutfitCatalog.resolve(binary, relativeTo: entry) else { continue }
            if ((try? ModelOutfitCatalog.load(entry))?.count ?? 0) > 1 { continue }
            let key = entry.deletingLastPathComponent().path + "\u{0}" + target.path + "\u{0}" + label
            labeled[key, default: []].append(entry)
        }
        var inferredNames: [URL: String] = [:]
        for siblings in labeled.values where siblings.count > 1 {
            let sorted = siblings.sorted {
                let leftDefault = ["model.default.json", "model.json"].contains($0.lastPathComponent)
                let rightDefault = ["model.default.json", "model.json"].contains($1.lastPathComponent)
                if leftDefault != rightDefault { return leftDefault }
                return $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
            guard let first = sorted.first, let object = try? Self.object(first), let label = object["label"] as? String else { continue }
            // Write catalogs for every entry so explicitly selecting any costume
            // later still retains the same complete wardrobe.
            for selected in sorted {
                let outfits = try ([selected] + sorted.filter { $0 != selected }).map { target -> ModelOutfit in
                    let json = try Self.object(target)
                    let fallback = target.deletingPathExtension().lastPathComponent
                    let name = (json["options"] as? [String: Any])?["name"] as? String ?? json["name"] as? String ?? fallback
                    return ModelOutfit(id: target == selected ? "" : target.lastPathComponent, name: name)
                }
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                try encoder.encode(outfits).write(to: ModelOutfitCatalog.sidecar(selected))
            }
            inferredNames[first] = label
        }
        // Hide entries explicitly referenced as costumes; do not group by filename similarity.
        var referenced = Set<URL>(), edges: [URL: Set<URL>] = [:]
        for entry in entries {
            var targets = Set<URL>()
            for outfit in (try? ModelOutfitCatalog.load(entry)) ?? [] where !outfit.id.isEmpty {
                if let target = try? ModelOutfitCatalog.resolve(outfit.id, relativeTo: entry), target != entry { targets.insert(target) }
            }
            // Include references back to the default costume, which the display catalog
            // deliberately represents with an empty ID rather than another menu entry.
            if let json = try? Self.object(entry), let groups = json["motions"] as? [String: [[String: Any]]] {
                for motion in groups.values.flatMap({ $0 }) {
                    guard let command = motion["command"] as? String else { continue }
                    let tokens = command.split(whereSeparator: { $0.isWhitespace })
                    if tokens.count == 2, tokens[0] == "change_cos",
                       let target = try? ModelOutfitCatalog.resolve(String(tokens[1]), relativeTo: entry), entries.contains(target), target != entry { targets.insert(target) }
                }
            }
            for target in targets where entries.contains(target) {
                referenced.insert(target)
                edges[entry, default: []].insert(target); edges[target, default: []].insert(entry)
            }
        }
        var roots = entries.filter { !referenced.contains($0) }
        var visited = Set<URL>()
        for entry in entries where !visited.contains(entry) {
            var component = Set<URL>(), pending = [entry]
            while let current = pending.popLast() {
                guard component.insert(current).inserted else { continue }
                pending += Array(edges[current] ?? [])
            }
            visited.formUnion(component)
            if !roots.contains(where: { component.contains($0) }) {
                let sorted = component.sorted { $0.path < $1.path }
                if let first = sorted.first(where: { inferredNames[$0] != nil }) ?? sorted.first(where: { $0.lastPathComponent == "model.json" }) ?? sorted.first { roots.append(first) }
            }
        }
        roots.sort { $0.path < $1.path }
        return roots.map { entry in
            let object = try? Self.object(entry)
            let options = object?["options"] as? [String: Any]
            let basename = entry.lastPathComponent.replacingOccurrences(of: ".model3.json", with: "").replacingOccurrences(of: ".model.json", with: "")
            let parentName = entry.deletingLastPathComponent().path == root.path ? rootName : entry.deletingLastPathComponent().lastPathComponent
            let fallback = entry.lastPathComponent == "model.json" || basename == "model" ? parentName : basename
            return (inferredNames[entry] ?? options?["name"] as? String ?? fallback, entry, nil)
        }
    }

    static func object(_ url: URL) throws -> [String: Any] {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size < 8 * 1024 * 1024,
              let result = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw ModelImportError.invalid(.key("error.config_json", []))
        }
        return result
    }

    static func relative(_ url: URL, to root: URL) -> String {
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        precondition(path.hasPrefix(base + "/"), "Import resource must remain inside staging directory")
        return String(path.dropFirst(base.count + 1))
    }

    static func files(in root: URL) throws -> [URL] {
        var result: [URL] = [], enumerationError: Error?
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, errorHandler: { _, error in enumerationError = error; return false }) else {
            throw ModelImportError.invalid(.key("error.directory_read", []))
        }
        var count = 0
        for case let url as URL in enumerator {
            count += 1
            guard count <= 20000 else { throw ModelImportError.invalid(.key("error.directory_count", [])) }
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isSymbolicLink != true, values.isRegularFile == true || values.isDirectory == true else {
                throw ModelImportError.invalid(.key("error.directory_special", []))
            }
            if url.lastPathComponent == "__MACOSX" { enumerator.skipDescendants(); continue }
            if url.lastPathComponent == ".DS_Store" { continue }
            if values.isRegularFile == true { result.append(url.standardizedFileURL.resolvingSymlinksInPath()) }
        }
        if let enumerationError { throw enumerationError }
        return result.sorted { $0.path < $1.path }
    }
}
