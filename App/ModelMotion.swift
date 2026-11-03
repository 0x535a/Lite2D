import Foundation

struct ModelMotion {
    let group: String
    let index: Int
    let file: String
    let name: String
    let defaultWeight: Double
    // File identity preserves overrides when outfits reorder or share motions.
    var key: String { "\(group.utf8.count):\(group)\(file)" }
    func weight(overrides: [String: Double]) -> Double { overrides[key] ?? defaultWeight }

    static func load(_ url: URL) throws -> [ModelMotion] {
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
        let refs = json["FileReferences"] as? [String: Any] ?? [:]
        let groups = (json["motions"] ?? refs["Motions"]) as? [String: [[String: Any]]] ?? [:]
        return groups.keys.sorted().flatMap { group in
            (groups[group] ?? []).enumerated().compactMap { index, entry -> ModelMotion? in
                guard let file = (entry["file"] ?? entry["File"]) as? String, !file.isEmpty else { return nil }
                let value = (entry["weight"] as? NSNumber)?.doubleValue ?? 1
                let weight = value.isFinite && value >= 0 ? value : 1
                return ModelMotion(group: group, index: index, file: file,
                                   name: entry["name"] as? String ?? "动作 \(index + 1)", defaultWeight: weight)
            }
        }
    }
}
