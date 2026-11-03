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
    init(manager: ModelInstanceManager) {
        self.manager = manager
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        statusItem.button?.image = NSImage(systemSymbolName: "person.crop.square", accessibilityDescription: "Lite2D")
        statusItem.button?.toolTip = "Lite2D · 独立模型实例"
        menu.delegate = self; menu.autoenablesItems = false; statusItem.menu = menu
        rebuild()
    }
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
            let empty = NSMenuItem(title: "还没有角色", action: nil, keyEquivalent: "")
            empty.isEnabled = false; menu.addItem(empty)
        }
        for record in manager.records {
            let settings = record.settings, id = settings.id
            let state = roleStatus(record)
            let title = roleName(record) + (state == "显示中" ? "" : " · \(state)")
            let model = submenu(title, into: menu)
            model.addItem(item(settings.isVisible ? "隐藏角色" : "显示角色", enabled: record.error == nil) { [weak self] in
                self?.manager.mutate(id) { $0.isVisible.toggle() }
            })
            model.addItem(item(settings.interactionMode == .edit ? "完成调整" : "调整位置与大小",
                               enabled: record.error == nil && manager.isDisplayConnected(record) && settings.isVisible && !manager.allHidden) { [weak self] in self?.manager.edit(id) })
            model.addItem(item(settings.animationPaused ? "继续播放动作" : "暂停动作", enabled: record.error == nil) { [weak self] in
                self?.manager.mutate(id) { $0.animationPaused.toggle() }
            })
            if record.outfits.count > 1 || settings.outfitID != nil {
                let outfits = submenu("服装", into: model)
                let options = record.outfits.isEmpty ? [ModelOutfit(id: "", name: "默认")] : record.outfits
                for outfit in options {
                    outfits.addItem(item(outfit.name, checked: (settings.outfitID ?? "") == outfit.id) { [weak self] in
                        self?.attempt { try self?.manager.setOutfit(id, outfitID: outfit.id) }
                    })
                }
            }
            model.addItem(.separator())
            model.addItem(item("角色设置…") { [weak self] in self?.settingsWindow.show(role: id) })
        }
        menu.addItem(.separator())
        menu.addItem(item(manager.allHidden ? "恢复显示" : "隐藏所有角色", enabled: !manager.records.isEmpty) { [weak self] in self?.manager.toggleAllHidden() })
        menu.addItem(item(importInProgress ? "正在导入角色…" : "添加角色…", enabled: !importInProgress) { [weak self] in self?.chooseModels() })
        let preferences = item("设置…") { [weak self] in self?.settingsWindow.show() }
        preferences.keyEquivalent = ","; menu.addItem(preferences)
        menu.addItem(.separator())
        let quit = item("退出 Lite2D") { NSApp.terminate(nil) }; quit.keyEquivalent = "q"; menu.addItem(quit)
    }
    func roleName(_ record: ModelRecord) -> String {
        let matches = manager.records.filter { $0.settings.displayName == record.settings.displayName }
        guard matches.count > 1, let index = matches.firstIndex(where: { $0.settings.id == record.settings.id }) else { return record.settings.displayName }
        return "\(record.settings.displayName)（\(index + 1)）"
    }
    func roleStatus(_ record: ModelRecord) -> String {
        if record.error != nil { return "加载失败" }
        if !manager.isDisplayConnected(record) { return record.settings.displayUUID == nil ? "未绑定屏幕" : "屏幕未连接" }
        if !record.settings.isVisible { return "已隐藏" }
        if manager.allHidden { return "全局隐藏中" }
        if record.settings.interactionMode == .edit { return "调整中" }
        return "显示中"
    }
    func attempt(title: String = "模型操作失败", _ body: () throws -> Void) {
        do { try body() }
        catch {
            let alert = NSAlert(); alert.messageText = title; alert.informativeText = error.localizedDescription
            NSApp.activate(ignoringOtherApps: true); alert.runModal()
        }
    }
    private func panel(multiple: Bool) -> NSOpenPanel {
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = multiple
        panel.allowedContentTypes = [.json, .zip] + ["lpk", "wpk"].compactMap { UTType(filenameExtension: $0) }
        panel.message = "选择 LPK、WPK、ZIP、模型文件夹或入口 JSON；资源将保存到 Lite2D 模型库。"
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
            var lastAdded: UUID?, failures: [String] = []
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
                            else { lastAdded = try manager.add(character.entry, name: character.name).settings.id }
                        } catch { failures.append("\(character.name)：\(error.localizedDescription)") }
                    }
                } catch { failures.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
            }
            progress.orderOut(nil)
            if let lastAdded { settingsWindow.show(role: lastAdded, resetPage: true) }
            if !failures.isEmpty { attempt(title: failures.count == urls.count ? "导入失败" : "部分角色导入失败") { throw ModelImportError.invalid(failures.joined(separator: "\n\n")) } }
        }
    }
    private func selectCharacters(_ preparation: ModelImportPreparation, single: Bool) -> [Int] {
        if preparation.characters.count == 1 && preparation.warnings.isEmpty { return [0] }
        return CharacterPicker.run(sourceName: preparation.sourceName, characters: preparation.characters,
                                   warnings: preparation.warnings, single: single) ?? []
    }
}
