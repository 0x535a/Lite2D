import Foundation

// Routing is configuration, never character identity or memory ownership.
enum CompanionModelRouting {
    static func role(_ id: String, config: CompanionObject) -> String {
        let selected = (NativeCompanionData.array(config["characters"]).first { $0["id"] as? String == id }?["model"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return selected.isEmpty ? (config["model"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) : selected
    }
    static func archive(config: CompanionObject) -> String {
        let selected = (config["memoryModel"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return selected.isEmpty ? (config["model"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) : selected
    }
    static func validate(_ value: String) throws {
        guard value.isEmpty || (value.utf8.count <= 512 && value.first != "/" && value.last != "/" && value.contains("/") && !value.contains("\0")) else {
            throw NativeCompanionData.error("Model must be empty or provider/model")
        }
    }
    static func resetToServiceDefault(requested: String, previous: String?) -> Bool { requested.isEmpty && previous != "" }
}
