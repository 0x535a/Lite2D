import AppKit
import UniformTypeIdentifiers
import ServiceManagement

final class ActionMenuItem: NSMenuItem {
    var handler: (() -> Void)?
    init(_ title: String, checked: Bool = false, enabled: Bool = true, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self; state = checked ? .on : .off; isEnabled = enabled
    }
    required init(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    @objc private func invoke() { handler?() }
}

final class StatusBarController: NSObject, NSMenuDelegate {
    let manager: ModelInstanceManager
    let statusItem: NSStatusItem
    let menu = NSMenu()
    lazy var settingsWindow = SettingsWindowController(status: self)
    private(set) var importInProgress = false
    private let importer = ModelLibraryImporter()
    private var importPanel: NSPanel?
    private var languageObserver: NSObjectProtocol?
    init(manager: ModelInstanceManager) {
        self.manager = manager
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        statusItem.button?.image = NSImage(systemSymbolName: "person.crop.square", accessibilityDescription: "Lite2D")
        statusItem.button?.toolTip = L10n.text("status.tooltip")
        menu.delegate = self; menu.autoenablesItems = false; statusItem.menu = menu
        languageObserver = NotificationCenter.default.addObserver(forName: .appLanguageChanged, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            statusItem.button?.toolTip = L10n.text("status.tooltip")
            importPanel?.title = L10n.text("import.title")
            for record in manager.records { record.controller?.window.title = record.settings.localizedDisplayName }
            rebuild()
        }
        rebuild()
    }
    deinit { if let languageObserver { NotificationCenter.default.removeObserver(languageObserver) } }
    func menuNeedsUpdate(_ menu: NSMenu) { rebuild() }
    func menuWillOpen(_ menu: NSMenu) { manager.clickInteractionSuspended = true }
    func menuDidClose(_ menu: NSMenu) { manager.clickInteractionSuspended = false }
    private func item(_ title: String, checked: Bool = false, enabled: Bool = true, action: @escaping () -> Void) -> ActionMenuItem {
        ActionMenuItem(title, checked: checked, enabled: enabled, handler: action)
    }
    private func submenu(_ title: String, into parent: NSMenu) -> NSMenu {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(); menu.autoenablesItems = false; entry.submenu = menu; parent.addItem(entry)
        return menu
    }
    func rebuild() {
        menu.removeAllItems()
        if manager.records.isEmpty {
            let empty = NSMenuItem(title: L10n.text("role.empty"), action: nil, keyEquivalent: "")
            empty.isEnabled = false; menu.addItem(empty)
        }
        for record in manager.records {
            let settings = record.settings, id = settings.id
            let state = roleState(record)
            let title = roleName(record) + (state == .visible ? "" : " · \(state.title)")
            let model = submenu(title, into: menu)
            model.addItem(item(settings.isVisible ? L10n.text("role.hide") : L10n.text("role.show"), enabled: record.error == nil) { [weak self] in
                self?.manager.mutate(id) { $0.isVisible.toggle() }
            })
            model.addItem(item(settings.interactionMode == .edit ? L10n.text("placement.done") : L10n.text("placement.adjust"),
                               enabled: record.error == nil && manager.isDisplayConnected(record) && settings.isVisible && !manager.allHidden) { [weak self] in self?.manager.edit(id) })
            model.addItem(item(settings.animationPaused ? L10n.text("motion.resume") : L10n.text("motion.pause"), enabled: record.error == nil) { [weak self] in
                self?.manager.mutate(id) { $0.animationPaused.toggle() }
            })
            if record.outfits.count > 1 || settings.outfitID != nil {
                let outfits = submenu(L10n.text("outfit.section"), into: model)
                let options = record.outfits.isEmpty ? [ModelOutfit(id: "", name: "Default", generatedName: GeneratedName(key: "common.default"))] : record.outfits
                for outfit in options {
                    outfits.addItem(item(outfit.localizedName, checked: (settings.outfitID ?? "") == outfit.id) { [weak self] in
                        self?.attempt { try self?.manager.setOutfit(id, outfitID: outfit.id) }
                    })
                }
            }
            model.addItem(.separator())
            model.addItem(item(L10n.text("role.settings")) { [weak self] in self?.settingsWindow.show(role: id) })
        }
        menu.addItem(.separator())
        menu.addItem(item(manager.allHidden ? L10n.text("role.restore") : L10n.text("role.hide_all"), enabled: !manager.records.isEmpty) { [weak self] in self?.manager.toggleAllHidden() })
        menu.addItem(item(importInProgress ? L10n.text("import.busy_menu") : L10n.text("role.add"), enabled: !importInProgress) { [weak self] in self?.chooseModels() })
        let preferences = item(L10n.text("settings.open")) { [weak self] in self?.settingsWindow.show() }
        preferences.keyEquivalent = ","; menu.addItem(preferences)
        menu.addItem(.separator())
        let quit = item(L10n.text("app.quit")) { NSApp.terminate(nil) }; quit.keyEquivalent = "q"; menu.addItem(quit)
    }
    func roleName(_ record: ModelRecord) -> String {
        let matches = manager.records.filter { $0.settings.localizedDisplayName == record.settings.localizedDisplayName }
        guard matches.count > 1, let index = matches.firstIndex(where: { $0.settings.id == record.settings.id }) else { return record.settings.localizedDisplayName }
        return L10n.text("format.numbered", record.settings.localizedDisplayName, String(index + 1))
    }
    func roleStatus(_ record: ModelRecord) -> String { roleState(record).title }
    func roleState(_ record: ModelRecord) -> RoleStatus {
        if record.error != nil { return .failed }
        if !manager.isDisplayConnected(record) { return record.settings.displayUUID == nil ? .unbound : .disconnected }
        if !record.settings.isVisible { return .hidden }
        if manager.allHidden { return .allHidden }
        if record.settings.interactionMode == .edit { return .editing }
        return .visible
    }
    func attempt(title: String = "error.operation", _ body: () throws -> Void) {
        do { try body() }
        catch {
            LocalizedErrorDialog.run(titleKey: title, message: .failure(error))
        }
    }
    private func panel(multiple: Bool) -> NSOpenPanel {
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = multiple
        panel.allowedContentTypes = [.folder, .json, .zip] + ["lpk", "wpk"].compactMap { UTType(filenameExtension: $0) }
        panel.message = L10n.text("import.panel_help")
        return panel
    }
    func chooseModels() {
        guard !importInProgress else { return }
        let panel = panel(multiple: true); NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        importModels(panel.urls)
    }
    func chooseReplacement(_ id: UUID) {
        guard !importInProgress else { return }
        let panel = panel(multiple: false); NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importModels([url], replacing: id)
    }
    func importModels(_ urls: [URL], replacing id: UUID? = nil) {
        guard !importInProgress, !urls.isEmpty else { return }
        importInProgress = true
        settingsWindow.model.objectWillChange.send()
        let progressModel = ImportProgressModel()
        let progress = ImportProgressPanel.make(model: progressModel)
        progress.makeKeyAndOrderFront(nil); importPanel = progress
        Task { @MainActor in
            defer {
                progress.orderOut(nil); importPanel = nil; importInProgress = false
                settingsWindow.model.objectWillChange.send(); rebuild()
            }
            var lastAdded: UUID?, failures: [LocalizedMessage] = []
            for url in urls {
                progressModel.detail = url.lastPathComponent
                do {
                    let preparation = try await Task.detached { [importer] in try importer.prepare(url) }.value
                    progress.orderOut(nil)
                    let selected = selectCharacters(preparation, single: id != nil)
                    guard !selected.isEmpty else { progress.makeKeyAndOrderFront(nil); continue }
                    progress.makeKeyAndOrderFront(nil)
                    let characters = try await Task.detached { [importer] in try importer.commit(preparation, indices: selected) }.value
                    for character in characters {
                        do {
                            if let id { try manager.replace(id, with: character.entry); lastAdded = id }
                            else { lastAdded = try manager.add(character.entry, name: character.name, generatedName: character.generatedName).settings.id }
                        } catch { failures.append(.key("format.named_detail", [character.generatedName.map { .key($0.key, $0.arguments.map { .literal($0) }) } ?? .literal(character.name), .failure(error)])) }
                    }
                } catch { failures.append(.key("format.named_detail", [.literal(url.lastPathComponent), .failure(error)])) }
            }
            progress.orderOut(nil)
            if let lastAdded { settingsWindow.show(role: lastAdded, resetPage: true) }
            if !failures.isEmpty { attempt(title: lastAdded == nil ? "import.failed" : "import.partial_failure") { throw ModelImportError.invalid(.joined(failures, "\n\n")) } }
        }
    }
    private func selectCharacters(_ preparation: ModelImportPreparation, single: Bool) -> [Int] {
        if preparation.characters.count == 1 && preparation.warnings.isEmpty { return [0] }
        return CharacterPicker.run(sourceName: preparation.sourceName, characters: preparation.characters,
                                   warnings: preparation.warnings, single: single) ?? []
    }
}

enum RoleStatus: String {
    case failed, unbound, disconnected, hidden, allHidden = "all_hidden", editing, visible
    var title: String { L10n.text("role.status." + rawValue) }
}
