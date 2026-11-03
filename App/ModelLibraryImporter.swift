import Foundation
import CryptoKit

struct ImportedCharacter {
    let name: String
    let entry: URL
    let outfitCount: Int
}

enum ModelImportError {
    static func invalid(_ message: String) -> NSError {
        NSError(domain: "Lite2D.Import", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

// A preparation is private and disposable. No model-library changes until commit.
final class ModelImportPreparation {
    let directory: URL
    let characters: [ImportedCharacter]
    let warnings: [String]
    let sourceName: String
    init(directory: URL, characters: [ImportedCharacter], warnings: [String], sourceName: String) {
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
        guard source.isFileURL else { throw ModelImportError.invalid("请选择本机模型文件。") }
        let stage = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("Lite2D-import-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        do {
            let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw ModelImportError.invalid("请选择实际模型文件或文件夹，不能导入符号链接。") }
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
                throw ModelImportError.invalid("支持 LPK、WPK、ZIP、完整模型文件夹和模型入口 JSON。")
            }
            let packaged = explicitEntry == nil ? try ModelPackageDecoder.decode(in: stage) : []
            let stagedFiles = try Self.files(in: stage)
            let stagedSize = try stagedFiles.reduce(0) { try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
            guard stagedSize <= Self.limit else { throw ModelImportError.invalid("整理后的模型资源超过 512 MiB。") }
            let entries: [(String, URL)]
            if !packaged.isEmpty { entries = packaged }
            else if let explicitEntry { entries = [(source.deletingLastPathComponent().lastPathComponent, explicitEntry)] }
            else { entries = try discover(in: stage, rootName: values.isDirectory == true ? source.lastPathComponent : source.deletingPathExtension().lastPathComponent) }
            var characters: [ImportedCharacter] = [], warnings: [String] = []
            for (name, entry) in entries {
                do {
                    let valid = try ModelFileValidator.validate(entry)
                    let outfits = try ModelOutfitCatalog.load(entry)
                    for outfit in outfits where !outfit.id.isEmpty {
                        _ = try ModelFileValidator.validate(ModelOutfitCatalog.resolve(outfit.id, relativeTo: entry))
                    }
                    warnings += valid.warnings.map { "\(name)：\($0)" }
                    characters.append(ImportedCharacter(name: name, entry: entry, outfitCount: max(1, outfits.count)))
                } catch { warnings.append("\(name)：\(error.localizedDescription)") }
            }
            guard !characters.isEmpty else {
                throw ModelImportError.invalid(warnings.isEmpty ? "没有找到可播放的 Live2D 模型。Spine、场景包及编辑工程暂不支持。" : warnings.joined(separator: "\n"))
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
            return ImportedCharacter(name: original.name, entry: entry, outfitCount: original.outfitCount)
        }
    }

    private func copyDirectory(_ source: URL, to stage: URL) throws {
        var total = 0
        for file in try Self.files(in: source) {
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            total += size
            guard total <= Self.limit else { throw ModelImportError.invalid("模型目录超过 512 MiB，请选择更具体的模型目录。") }
            let target = stage.appendingPathComponent(Self.relative(file, to: source))
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: file, to: target)
        }
    }

    private func discover(in root: URL, rootName: String) throws -> [(String, URL)] {
        var entries: [URL] = []
        for file in try Self.files(in: root) where file.pathExtension.lowercased() == "json" {
            if file.deletingLastPathComponent().lastPathComponent == ".lite2d-decoded",
               !fm.fileExists(atPath: ModelOutfitCatalog.sidecar(file).path) { continue }
            guard !file.lastPathComponent.hasSuffix(".lite2d-outfits.json"),
                  let object = try? Self.object(file), object["model"] is String || object["FileReferences"] is [String: Any] else { continue }
            entries.append(file)
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
                if let first = sorted.first(where: { $0.lastPathComponent == "model.json" }) ?? sorted.first { roots.append(first) }
            }
        }
        roots.sort { $0.path < $1.path }
        return roots.map { entry in
            let object = try? Self.object(entry)
            let options = object?["options"] as? [String: Any]
            let basename = entry.lastPathComponent.replacingOccurrences(of: ".model3.json", with: "").replacingOccurrences(of: ".model.json", with: "")
            let parentName = entry.deletingLastPathComponent().path == root.path ? rootName : entry.deletingLastPathComponent().lastPathComponent
            let fallback = entry.lastPathComponent == "model.json" || basename == "model" ? parentName : basename
            return (options?["name"] as? String ?? fallback, entry)
        }
    }

    static func object(_ url: URL) throws -> [String: Any] {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size < 8 * 1024 * 1024,
              let result = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw ModelImportError.invalid("配置不是有效的 JSON 对象，或超过 8 MiB。")
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
            throw ModelImportError.invalid("无法读取模型目录。")
        }
        var count = 0
        for case let url as URL in enumerator {
            count += 1
            guard count <= 20000 else { throw ModelImportError.invalid("模型目录超过 20,000 项。") }
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isSymbolicLink != true, values.isRegularFile == true || values.isDirectory == true else {
                throw ModelImportError.invalid("模型目录包含符号链接或特殊文件，请使用完整的实际资源目录。")
            }
            if url.lastPathComponent == "__MACOSX" { enumerator.skipDescendants(); continue }
            if url.lastPathComponent == ".DS_Store" { continue }
            if values.isRegularFile == true { result.append(url.standardizedFileURL.resolvingSymlinksInPath()) }
        }
        if let enumerationError { throw enumerationError }
        return result.sorted { $0.path < $1.path }
    }
}
