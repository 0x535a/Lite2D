import Foundation

@main struct ModelImportTests {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let importer = ModelLibraryImporter(library: root.appendingPathComponent("library"))
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
        }
        func rejected(_ path: String, containing text: String? = nil) throws {
            do {
                _ = try importer.prepare(root.appendingPathComponent(path))
                preconditionFailure("Unexpected import success: \(path)")
            } catch {
                if let text { check(error.localizedDescription.contains(text), "Wrong error for \(path): \(error)") }
            }
        }
        let plain = try importer.prepare(root.appendingPathComponent("plain.zip"))
        check(plain.characters.count == 1, "ZIP must find one model")
        let added = try importer.commit(plain, indices: [0])
        let repeated = try importer.commit(plain, indices: [0])
        check(added[0].entry == repeated[0].entry, "Same resources must reuse library location")
        let direct = try importer.prepare(root.appendingPathComponent("plain/model.model3.json"))
        check(direct.characters.count == 1, "Explicit JSON must load only selected entry")
        let folder = try importer.prepare(root.appendingPathComponent("plain"))
        check(folder.characters.count == 1, "Folder must discover model JSON")
        let lpk = try importer.prepare(root.appendingPathComponent("multi.lpk"))
        check(lpk.characters.map(\.name) == ["角色甲", "角色乙"], "Manifest names and order must survive")
        check(lpk.characters[0].outfitCount == 2, "Manifest costumes must belong to one character")
        let selected = try importer.commit(lpk, indices: [0])
        let preparedAgain = try importer.prepare(root.appendingPathComponent("multi.lpk"))
        let savedAgain = try importer.commit(preparedAgain, indices: [0])
        check(savedAgain[0].entry == selected[0].entry, "New preparations of the same package must deduplicate")
        let cancelled = try importer.commit(lpk, indices: [])
        check(cancelled.isEmpty, "Cancelled selection must not add characters")
        check(selected.count == 1, "Only selected characters become instances")
        let outfits = try ModelOutfitCatalog.load(selected[0].entry)
        check(outfits.map(\.name) == ["日常", "节日"], "Costume names/order must survive")
        _ = try ModelFileValidator.validate(ModelOutfitCatalog.resolve(outfits[1].id, relativeTo: selected[0].entry))
        let wpk = try importer.prepare(root.appendingPathComponent("wrapped.wpk"))
        check(wpk.characters.count == 2 && wpk.characters[0].outfitCount == 2, "WPK wrapper must unwrap inner LPK")
        let legacy = try importer.prepare(root.appendingPathComponent("legacy"))
        check(legacy.characters.count == 1 && legacy.characters[0].outfitCount == 2, "Explicit change_cos graph must group costumes: \(legacy.characters.map { ($0.name, $0.outfitCount, $0.entry.path) })")
        let unrelated = try importer.prepare(root.appendingPathComponent("unrelated"))
        check(unrelated.characters.count == 2, "Unrelated entries must stay separate")
        let partial = try importer.prepare(root.appendingPathComponent("partial"))
        check(partial.characters.count == 1 && !partial.warnings.isEmpty, "One broken model must not discard valid sibling")
        try rejected("traversal.zip", containing: "路径")
        try rejected("link.zip", containing: "路径")
        try rejected("collision.zip", containing: "路径")
        try rejected("corrupt.zip")
        try rejected("spine.lpk", containing: "Spine")
        try rejected("encrypted-without-config.lpk", containing: "config.json")
        try rejected("missing-texture", containing: "纹理")
        try rejected("linked-folder", containing: "符号链接")
        try rejected("bad-sidecar", containing: "服装")
        try FileManager.default.removeItem(at: root.appendingPathComponent("plain"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("plain.zip"))
        _ = try ModelFileValidator.validate(added[0].entry)
        let freshImporter = ModelLibraryImporter(library: importer.library)
        let restored = try freshImporter.prepare(added[0].entry)
        check(restored.characters.count == 1, "Saved entry must load after source deletion in a fresh importer")

        if CommandLine.arguments.count > 2 {
            let workshop = URL(fileURLWithPath: CommandLine.arguments[2])
            var passed = 0, unsupported = 0, maxOutfits = 0
            for directory in try FileManager.default.contentsOfDirectory(at: workshop, includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path }) {
                let configURL = directory.appendingPathComponent("config.json")
                guard let config = try? ModelLibraryImporter.object(configURL),
                      let package = config["lpkFile"] as? String else { continue }
                if String(describing: config["type"] ?? "") == "7" {
                    do { _ = try importer.prepare(directory.appendingPathComponent(package)); preconditionFailure("Spine must be rejected") }
                    catch { unsupported += 1 }
                    continue
                }
                let prepared: ModelImportPreparation
                do { prepared = try importer.prepare(directory.appendingPathComponent(package)) }
                catch { throw ModelImportError.invalid("Local package \(directory.lastPathComponent): \(error.localizedDescription)") }
                let saved = try importer.commit(prepared, indices: [0])
                _ = try ModelFileValidator.validate(saved[0].entry)
                let outfits = try ModelOutfitCatalog.load(saved[0].entry)
                maxOutfits = max(maxOutfits, outfits.count)
                for outfit in outfits where !outfit.id.isEmpty {
                    _ = try ModelFileValidator.validate(ModelOutfitCatalog.resolve(outfit.id, relativeTo: saved[0].entry))
                }
                passed += 1
            }
            print("Real local packages: \(passed) Cubism imports; \(unsupported) non-Cubism rejections; up to \(maxOutfits) costumes")
        }
        try Data(added[0].entry.path.utf8).write(to: root.appendingPathComponent("saved-entry.txt"))
        try Data(selected[0].entry.path.utf8).write(to: root.appendingPathComponent("saved-outfit-entry.txt"))
        print("Model import tests passed: archive/folder/JSON, manifest selection, outfits, dedup, source deletion, malformed inputs")
    }
}
