import Foundation

struct ModelMotion {
    let group: String
    let index: Int
    let file: String
    let name: String
    var generatedName: GeneratedName? = nil
    var localizedName: String { generatedName?.text ?? name }
    let defaultWeight: Double
    // File identity preserves overrides when outfits reorder or share motions.
    var key: String { "\(group.utf8.count):\(group)\(file)" }
    func weight(overrides: [String: Double]) -> Double { overrides[key] ?? defaultWeight }
    /// Whole weights print without a trailing ".0".
    static func displayWeight(_ value: Double) -> String {
        let text = String(value)
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }

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
                                   name: entry["name"] as? String ?? "Motion \(index + 1)",
                                   generatedName: entry["name"] is String ? nil : GeneratedName(key: "motion.fallback", arguments: [String(index + 1)]), defaultWeight: weight)
            }
        }
    }
}
