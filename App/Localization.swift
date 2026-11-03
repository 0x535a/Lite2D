import Foundation
import Combine

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, simplifiedChinese = "zh-Hans", traditionalChinese = "zh-Hant", english = "en", japanese = "ja"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return L10n.text("language.system")
        case .simplifiedChinese: return "简体中文"
        case .traditionalChinese: return "繁體中文"
        case .english: return "English"
        case .japanese: return "日本語"
        }
    }
}

extension Notification.Name {
    static let appLanguageChanged = Notification.Name("Lite2D.appLanguageChanged")
}

/// Bundle lookup is shared by SwiftUI, AppKit and background import validation.
/// Only the preference is persisted; translated presentation never enters model assets.
enum L10n {
    private static let lock = NSLock()
    private static let defaults = ProcessInfo.processInfo.environment["LITE2D_PREFERENCES_SUITE"].flatMap(UserDefaults.init(suiteName:)) ?? .standard
    private static var selected = AppLanguage(rawValue: defaults.string(forKey: "Lite2D.language") ?? "") ?? .system
    private static var resources = Bundle.main
    static var language: AppLanguage { lock.lock(); defer { lock.unlock() }; return selected }

    static func match(_ preferences: [String]) -> String {
        for preference in preferences {
            let parts = preference.replacingOccurrences(of: "_", with: "-").lowercased().split(separator: "-").map(String.init)
            guard let base = parts.first else { continue }
            if base == "en" { return "en" }
            if base == "ja" { return "ja" }
            if base == "zh" {
                if parts.contains("hant") { return "zh-Hant" }
                if parts.contains("hans") { return "zh-Hans" }
                return parts.contains(where: { ["tw", "hk", "mo"].contains($0) }) ? "zh-Hant" : "zh-Hans"
            }
        }
        return "en"
    }
    static var systemPreferences: [String] {
        // Read the global domain so an app-specific AppleLanguages override cannot
        // make “System Default” accidentally follow our previous manual choice.
        UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String] ?? Locale.preferredLanguages
    }
    static var resolvedLanguage: String {
        let choice = language
        return choice == .system ? match(systemPreferences) : choice.rawValue
    }
    static func setLanguage(_ language: AppLanguage) {
        lock.lock(); selected = language; lock.unlock()
        defaults.set(language.rawValue, forKey: "Lite2D.language")
        configureSystemDialogs()
        NotificationCenter.default.post(name: .appLanguageChanged, object: nil)
    }
    /// Called before AppKit starts. Foundation may cache system dialog localization
    /// for the process; the persisted override takes full effect on next launch.
    static func configureSystemDialogs() {
        if language == .system { defaults.removeObject(forKey: "AppleLanguages") }
        else { defaults.set([language.rawValue], forKey: "AppleLanguages") }
    }
    static func useResources(_ bundle: Bundle) {
        lock.lock(); resources = bundle; lock.unlock()
    }
    static func template(_ key: String) -> String {
        lock.lock(); let root = resources; lock.unlock()
        let language = resolvedLanguage
        let fallback = root.path(forResource: "en", ofType: "lproj").flatMap(Bundle.init(path:))
        let bundle = root.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)) ?? fallback
        let missing = "__LITE2D_MISSING__"
        let translated = bundle?.localizedString(forKey: key, value: missing, table: nil)
        if let translated, translated != missing { return translated }
        let english = fallback?.localizedString(forKey: key, value: missing, table: nil)
        // Even damaged resources must not expose an implementation key to users.
        return english.flatMap { $0 == missing ? nil : $0 } ?? "…"
    }
    static func text(_ key: String, _ arguments: String...) -> String { format(key, arguments) }
    static func format(_ key: String, _ arguments: [String]) -> String {
        let source = template(key)
        // Replace in one pass: author text such as “{1}” must stay verbatim.
        let pattern = try! NSRegularExpression(pattern: #"\{([0-9]+)\}"#)
        var result = source
        for match in pattern.matches(in: source, range: NSRange(source.startIndex..., in: source)).reversed() {
            guard let range = Range(match.range, in: result), let numberRange = Range(match.range(at: 1), in: source),
                  let index = Int(source[numberRange]), arguments.indices.contains(index) else { continue }
            result.replaceSubrange(range, with: arguments[index])
        }
        return result
    }
    static func count(_ key: String, _ count: Int) -> String {
        text(count == 1 ? key + ".one" : key, String(count))
    }
    static func error(_ error: Error) -> String {
        if let localized = error as? LocalizedFailure { return localized.message.text }
        let ns = error as NSError
        if let key = ns.userInfo["Lite2DLocalizationKey"] as? String { return text(key, ns.localizedDescription) }
        let key = ["Lite2D", "Lite2D.Legacy"].contains(ns.domain) ? "error.engine" : "error.external"
        return text(key, error.localizedDescription)
    }
}

/// Retains templates and raw arguments, so already-open warnings and errors can
/// change language without re-running import work or translating author content.
indirect enum LocalizedMessage {
    case literal(String)
    case key(String, [LocalizedMessage])
    case failure(Error)
    case joined([LocalizedMessage], String)
    var keys: Set<String> {
        switch self {
        case .literal: return []
        case .key(let key, let arguments): return arguments.reduce(into: Set([key])) { $0.formUnion($1.keys) }
        case .failure(let error):
            if let error = error as? LocalizedFailure { return error.message.keys }
            if let key = (error as NSError).userInfo["Lite2DLocalizationKey"] as? String { return [key] }
            return []
        case .joined(let messages, _): return messages.reduce(into: Set<String>()) { $0.formUnion($1.keys) }
        }
    }
    var text: String {
        switch self {
        case .literal(let value): return value
        case .key(let key, let arguments): return L10n.format(key, arguments.map(\.text))
        case .failure(let error): return L10n.error(error)
        case .joined(let messages, let separator): return messages.map(\.text).joined(separator: separator)
        }
    }
}

struct LocalizedFailure: LocalizedError {
    let message: LocalizedMessage
    /// Stable identity for validation and callers, independent of translated text.
    var key: String? { if case .key(let key, _) = message { return key }; return nil }
    var errorDescription: String? { message.text }
}

final class LanguageStore: ObservableObject {
    static let shared = LanguageStore()
    @Published private(set) var revision = 0
    private var observer: NSObjectProtocol?
    private var languageObserver: NSObjectProtocol?
    private init() {
        languageObserver = NotificationCenter.default.addObserver(forName: .appLanguageChanged, object: nil, queue: .main) { [weak self] _ in
            self?.revision += 1
        }
        observer = NotificationCenter.default.addObserver(forName: NSLocale.currentLocaleDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard L10n.language == .system else { return }
            self?.refresh()
        }
    }
    var selection: AppLanguage {
        get { L10n.language }
        set { L10n.setLanguage(newValue) }
    }
    private func refresh() {
        NotificationCenter.default.post(name: .appLanguageChanged, object: nil)
    }
}

/// Explicit provenance. Missing metadata in older files always means literal text.
struct GeneratedName: Codable, Equatable {
    let key: String
    var arguments: [String] = []
    var suffix: String = ""
    var text: String { L10n.format(key, arguments) + suffix }
    init(key: String, arguments: [String] = [], suffix: String = "") {
        self.key = key; self.arguments = arguments; self.suffix = suffix
    }
    enum CodingKeys: String, CodingKey { case key, arguments, suffix }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        arguments = try c.decodeIfPresent([String].self, forKey: .arguments) ?? []
        suffix = try c.decodeIfPresent(String.self, forKey: .suffix) ?? ""
    }
}
