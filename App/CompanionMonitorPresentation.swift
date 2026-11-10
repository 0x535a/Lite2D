import Foundation

// Localize enum labels only. Free text, names and numeric values remain data.
enum CompanionMonitorPresentation {
    static func label(_ value: String) -> String {
        guard !value.isEmpty else { return "" }
        return L10n.lookup("monitor.value." + value) ?? value
    }
    static func date(_ value: String, timeZone: TimeZone = .current) -> String {
        guard !value.isEmpty else { return "" }
        let parser = ISO8601DateFormatter()
        var parsed = parser.date(from: value)
        if parsed == nil {
            parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            parsed = parser.date(from: value)
        }
        guard let date = parsed else { return value }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: L10n.resolvedLanguage)
        formatter.timeZone = timeZone
        formatter.dateStyle = .short; formatter.timeStyle = .medium
        return formatter.string(from: date)
    }
    static func pagination(page: Int, pageSize: Int, total: Int) -> String {
        guard total > 0 else { return L10n.text("monitor.no_records") }
        let pages = (total + pageSize - 1) / pageSize
        return L10n.text("monitor.pagination", String(page + 1), String(pages), String(total))
    }
    static func previewValues(operation: String, kind: String, before: String, after: String) -> (String, String) {
        switch operation {
        case "archive": return (label("active"), label("archived"))
        case "restore": return (label("archived"), label("active"))
        case "forget": return (L10n.text("monitor.retained_content"), L10n.text("monitor.content_removed"))
        case "approve" where kind == "reflection": return (label("preview"), label("committed"))
        case "cancel": return (label("preview"), label("cancelled"))
        case "rollback" where kind == "reflection": return (label("committed"), label("rolled_back"))
        default: return (before, after)
        }
    }
}
