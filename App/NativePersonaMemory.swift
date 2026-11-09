import Foundation

struct NativePersonaClaim {
    let field: String
    let value: String
    let kind: String
    let confidence: Double
}

enum NativePersonaMemory {
    static func body(_ markdown: String) -> String {
        var value = markdown
        if value.hasPrefix("---"), let end = value.range(of: "\n---", range: value.index(value.startIndex, offsetBy: 3)..<value.endIndex) {
            value = String(value[end.upperBound...])
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func section(_ markdown: String, matching pattern: String) -> String? {
        let source = body(markdown)
        guard let regex = try? NSRegularExpression(pattern: "(?ms)^##\\s+[^\\n]*(?:" + pattern + ")[^\\n]*\\n(.*?)(?=^##\\s|\\z)", options: []) else { return nil }
        let range = NSRange(source.startIndex..., in: source)
        guard let match = regex.firstMatch(in: source, options: [], range: range), match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: source) else { return nil }
        return String(source[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func claims(_ markdown: String) -> [NativePersonaClaim] {
        var result: [NativePersonaClaim] = []
        if let identity = section(markdown, matching: "我是谁|身份|角色") {
            result.append(.init(field: "identity_summary", value: String(identity.prefix(4000)), kind: "identity", confidence: 1))
        }
        if let relationship = section(markdown, matching: "关系|姐妹|用户关系") {
            result.append(.init(field: "relationship_summary", value: String(relationship.prefix(3000)), kind: "relationship", confidence: 1))
        }
        if result.isEmpty {
            let firstParagraph = body(markdown).components(separatedBy: "\n\n").first ?? body(markdown)
            result.append(.init(field: "persona_summary", value: String(firstParagraph.prefix(1200)), kind: "persona", confidence: 0.8))
        }
        return result
    }

    static func publicCard(characterID: String, name: String, markdown: String, revision: String) -> [String: Any] {
        let values = claims(markdown).map { "\($0.field): \($0.value)" }.joined(separator: "\n")
        return [
            "id": characterID,
            "name": name,
            "identityRevision": revision,
            "confirmed": String(values.prefix(2400)),
            "unknown": "仅提供公开 Persona 摘要；未写明的属性不应被推断为事实。",
            "provenance": "user_persona_edit"
        ]
    }

    static func runtimeView(markdown: String, revision: String, managed: [NativePersonaClaim]) -> String {
        guard !managed.isEmpty else { return markdown }
        let lines = managed.map { "- \($0.field): \($0.value)" }.joined(separator: "\n")
        return """
        \(markdown)

        <!-- lite2d:managed identity revision=\(revision) -->
        ## Controller-managed identity context
        These are data views, not new evidence and not tool permissions. Keep the current character separate from other characters.
        \(lines)
        <!-- lite2d:end managed identity -->
        """
    }
}
