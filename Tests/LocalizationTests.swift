import Foundation

@main struct LocalizationTests {
    static func main() throws {
        L10n.useResources(Bundle(path: CommandLine.arguments[1])!)
        let suite = ProcessInfo.processInfo.environment["LITE2D_PREFERENCES_SUITE"]!
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let cases: [([String], String)] = [
            (["fr-FR", "ja-JP", "en-US"], "ja"), (["zh-TW"], "zh-Hant"),
            (["zh-HK"], "zh-Hant"), (["zh-MO"], "zh-Hant"), (["zh-Hans-TW"], "zh-Hans"),
            (["zh-Hant-CN"], "zh-Hant"), (["zh_CN"], "zh-Hans"), (["de-DE"], "en"), ([], "en")
        ]
        for (preferences, expected) in cases { precondition(L10n.match(preferences) == expected) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Lite2D-localization-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let entry = directory.appendingPathComponent("model.json")
        try Data(#"{"model":"../escape.moc","textures":["t.png"]}"#.utf8).write(to: entry)
        let error: Error
        do { _ = try ModelFileValidator.validate(entry); fatalError("Unsafe reference was accepted") }
        catch let failure { error = failure }
        precondition((error as? LocalizedFailure)?.key == "error.model_escape")
        let notice = LocalizedMessage.key("format.named_detail", [.literal("作者{1}原文"), .failure(error)])
        let literalOutfit = ModelOutfit(id: "", name: "默认")
        let generatedOutfit = ModelOutfit(id: "", name: "Default", generatedName: GeneratedName(key: "common.default"))
        let oldSettings = try JSONDecoder().decode(ModelInstanceSettings.self, from: Data(#"{"displayName":"模型","modelPath":"/model"}"#.utf8))
        let missingName = try JSONDecoder().decode(ModelInstanceSettings.self, from: Data(#"{"modelPath":"/model"}"#.utf8))
        let oldSidecar = try JSONDecoder().decode([ModelOutfit].self, from: Data(#"[{"id":"","name":"默认"}]"#.utf8))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let generatedData = try encoder.encode(generatedOutfit)
        let restored = try JSONDecoder().decode(ModelOutfit.self, from: generatedData)
        let motionEntry = directory.appendingPathComponent("motions.json")
        try Data(#"{"motions":{"作者动作组":[{"file":"a","name":"动作 1"},{"file":"b"}]}}"#.utf8).write(to: motionEntry)
        let motions = try ModelMotion.load(motionEntry)
        var renderedErrors = Set<String>()
        var renderedDefaults = Set<String>()
        for language in AppLanguage.allCases where language != .system {
            LanguageStore.shared.selection = language
            precondition(UserDefaults(suiteName: suite)?.string(forKey: "Lite2D.language") == language.rawValue)
            precondition(UserDefaults(suiteName: suite)?.stringArray(forKey: "AppleLanguages") == [language.rawValue])
            precondition(L10n.resolvedLanguage == language.rawValue)
            renderedErrors.insert(L10n.error(error))
            renderedDefaults.insert(restored.localizedName)
            precondition(notice.text.contains("作者{1}原文"), "Arguments must never be recursively formatted")
            precondition(literalOutfit.localizedName == "默认" && oldSidecar[0].localizedName == "默认")
            precondition(oldSettings.localizedDisplayName == "模型" && oldSettings.generatedName == nil)
            precondition(missingName.localizedDisplayName == L10n.text("model.fallback"))
            precondition(motions[0].localizedName == "动作 1" && motions[0].group == "作者动作组")
            precondition(motions[1].localizedName == L10n.text("motion.fallback", "2"))
            let reencoded = try encoder.encode(restored)
            precondition(reencoded == generatedData, "Language changes must not rewrite stored model metadata")
            precondition(!L10n.text("missing.internal.key").contains("missing.internal.key"))
            precondition(!L10n.error(NSError(domain: "Vendor", code: 1, userInfo: [NSLocalizedDescriptionKey: "RAW SDK DETAIL"])).isEmpty)
        }
        precondition(renderedErrors.count == 4 && renderedDefaults.count == 4, "Cached errors and generated names must translate at display time")
        for language in [AppLanguage.english, .simplifiedChinese, .traditionalChinese, .japanese] {
            L10n.setLanguage(language)
            precondition(L10n.lookup("monitor.value.unregistered") == nil)
            for literal in ["", "0.8", "22", "Custom Name", "custom-operation", "2026-11-10T04:46:43Z"] {
                precondition(CompanionMonitorPresentation.label(literal) == literal)
            }
            precondition(CompanionMonitorPresentation.label("active") != "…")
            precondition(CompanionMonitorPresentation.pagination(page: 0, pageSize: 30, total: 865).contains("29"))
            precondition(!CompanionMonitorPresentation.pagination(page: 0, pageSize: 30, total: 0).contains("1"))
        }
        L10n.setLanguage(.english)
        let local = CompanionMonitorPresentation.date("2026-11-10T04:46:43Z", timeZone: TimeZone(secondsFromGMT: 8 * 3600)!)
        precondition(local.contains("12:46:43"), local)
        let archived = CompanionMonitorPresentation.previewValues(operation: "archive", kind: "memory", before: "body", after: "body")
        precondition(archived.0 != archived.1 && !archived.0.contains("body"))
        L10n.setLanguage(.english)
        precondition(L10n.count("outfit.count", 0) == "0 outfits")
        precondition(L10n.count("outfit.count", 1) == "1 outfit")
        precondition(L10n.count("outfit.count", 2) == "2 outfits")
        precondition(L10n.count("import.more_warnings", 1) == "1 more notice")
        precondition(L10n.count("import.more_warnings", 2) == "2 more notices")
        let bridgeError = NSError(domain: "Lite2D.Import", code: 1, userInfo: ["Lite2DLocalizationKey": "error.archive_path"])
        precondition(L10n.error(bridgeError) == L10n.text("error.archive_path"))
        L10n.setLanguage(.system)
        precondition(UserDefaults.standard.persistentDomain(forName: suite)?["AppleLanguages"] == nil)
        // Missing selected-language translations fall back to the English bundle.
        let fallback = Bundle(path: CommandLine.arguments[2])!
        L10n.useResources(fallback)
        L10n.setLanguage(.japanese)
        precondition(L10n.text("settings.general") == "General")
        print("PASS: language negotiation, four-language switching/persistence, cached errors, author/legacy name preservation, generated-name round trips, plural forms, safe interpolation, English fallback")
    }
}
