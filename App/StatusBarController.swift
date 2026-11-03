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
        menu.addItem(item("添加角色…") { [weak self] in self?.chooseModels() })
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
    func attempt(_ body: () throws -> Void) {
        do { try body() }
        catch {
            let alert = NSAlert(); alert.messageText = "模型操作失败"; alert.informativeText = error.localizedDescription
            NSApp.activate(ignoringOtherApps: true); alert.runModal()
        }
    }
    private func panel(multiple: Bool) -> NSOpenPanel {
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = multiple
        panel.allowsMultipleSelection = multiple; panel.allowedContentTypes = [.json]
        panel.message = "选择模型 JSON；文件夹中的模型会分别创建独立实例。"
        return panel
    }
    func chooseModels() {
        let panel = panel(multiple: true); NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        var lastAdded: UUID?
        for url in panel.urls {
            var isDirectory: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            var candidates = [url]
            if isDirectory.boolValue {
                candidates = (FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
                    .filter { $0.lastPathComponent == "model.json" || $0.lastPathComponent.hasSuffix(".model3.json") || $0.lastPathComponent.hasSuffix(".model.json") }
                    .sorted { $0.path < $1.path }
            }
            for candidate in candidates { attempt { lastAdded = try manager.add(candidate).settings.id } }
        }
        if let id = lastAdded { settingsWindow.show(role: id, resetPage: true) }
    }
    func chooseReplacement(_ id: UUID) {
        let panel = panel(multiple: false); NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        attempt { try manager.replace(id, with: url) }
    }
    func editMotionWeights(_ id: UUID) {
        guard let record = manager.record(id), let view = record.controller?.view, !view.motions.isEmpty else { return }
        let motions = view.motions
        switch MotionWeightEditor.run(title: "\(record.settings.displayName) · 动作权重", motions: motions,
                                      overrides: record.settings.motionWeightOverrides) {
        case .save(let overrides):
            manager.setMotionWeights(id, overrides: overrides)
        case .reset:
            // Only clear the displayed motions; other outfits retain their overrides.
            var overrides = record.settings.motionWeightOverrides
            for motion in motions { overrides.removeValue(forKey: motion.key) }
            manager.setMotionWeights(id, overrides: overrides)
        case .cancel:
            break
        }
    }
}
