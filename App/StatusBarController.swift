import AppKit
import UniformTypeIdentifiers

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
        menu.addItem(item("添加模型…") { [weak self] in self?.chooseModels() })
        let list = submenu("模型实例 (\(manager.records.count))", into: menu)
        for record in manager.records {
            let settings = record.settings, id = settings.id
            let model = submenu("\(settings.displayName) · \(id.uuidString.prefix(4))", into: list)
            if let error = record.error {
                let label = NSMenuItem(title: "加载失败：\(error)", action: nil, keyEquivalent: "")
                label.isEnabled = false; model.addItem(label)
            }
            let connected = manager.isDisplayConnected(record)
            let bindingName = settings.boundDisplayName ?? settings.displayUUID.map { String($0.prefix(8)) } ?? "未绑定"
            let displayMenu = submenu("绑定显示器：\(bindingName)\(connected ? "" : "（离线 / 隐藏）")", into: model)
            for display in manager.displayRegistry.displays {
                displayMenu.addItem(item("\(display.name) · \(display.id.prefix(4))", checked: display.id == settings.displayUUID) { [weak self] in
                    self?.manager.bind(id, to: display.id)
                })
            }
            model.addItem(item("显示", checked: settings.isVisible) { [weak self] in self?.manager.mutate(id) { $0.isVisible.toggle() } })
            model.addItem(item(settings.interactionMode == .edit ? "完成编辑（点击穿透）" : "编辑（拖动 / 滚轮缩放）") { [weak self] in self?.manager.edit(id) })
            model.addItem(item("视线追踪", checked: settings.trackingEnabled) { [weak self] in self?.manager.mutate(id) { $0.trackingEnabled.toggle() } })
            let smoothing = submenu("追踪平滑", into: model)
            for (title, seconds) in [("灵敏 · 0.06 秒", 0.06), ("标准 · 0.14 秒", 0.14), ("柔和 · 0.30 秒", 0.30)] {
                smoothing.addItem(item(title, checked: abs(settings.trackingSmoothingSeconds - seconds) < 0.001) { [weak self] in self?.manager.mutate(id) { $0.trackingSmoothingSeconds = seconds } })
            }
            model.addItem(item("暂停动作", checked: settings.animationPaused) { [weak self] in self?.manager.mutate(id) { $0.animationPaused.toggle() } })
            let groups = record.controller?.view.bridge.motionGroups ?? [:]
            if !groups.isEmpty {
                let idle = submenu("循环动作组", into: model)
                idle.addItem(item("无", checked: settings.idleMotionGroup == "") { [weak self] in self?.manager.setIdle(id, group: "") })
                let motions = submenu("播放动作", into: model)
                for group in groups.keys.sorted() {
                    let selected = settings.idleMotionGroup == group || (settings.idleMotionGroup == nil && group.lowercased() == "idle")
                    idle.addItem(item(group, checked: selected) { [weak self] in self?.manager.setIdle(id, group: group) })
                    let groupMenu = submenu(group, into: motions)
                    for index in 0..<(groups[group]?.intValue ?? 0) {
                        groupMenu.addItem(item("动作 \(index + 1)") { [weak self] in self?.manager.play(id, group: group, index: index) })
                    }
                }
            }
            let expressions = record.controller?.view.bridge.expressionNames ?? []
            if !expressions.isEmpty {
                let expressionMenu = submenu("表情", into: model)
                expressionMenu.addItem(item("默认", checked: settings.expressionId == nil) { [weak self] in self?.manager.setExpression(id, expression: "") })
                for expression in expressions {
                    expressionMenu.addItem(item(expression, checked: settings.expressionId == expression) { [weak self] in self?.manager.setExpression(id, expression: expression) })
                }
            }
            let fps = submenu("帧率", into: model)
            for rate in [30, 60] { fps.addItem(item("\(rate) FPS", checked: settings.targetFPS == rate) { [weak self] in self?.manager.mutate(id) { $0.targetFPS = rate } }) }
            model.addItem(.separator())
            model.addItem(item("放大") { [weak self] in self?.manager.zoom(id, factor: 1.15) })
            model.addItem(item("缩小") { [weak self] in self?.manager.zoom(id, factor: 1 / 1.15) })
            model.addItem(item("置于前面") { [weak self] in self?.manager.bringForward(id) })
            model.addItem(item("重置在绑定屏内的位置") { [weak self] in self?.manager.resetPosition(id) })
            model.addItem(item("重命名…") { [weak self] in self?.rename(id) })
            model.addItem(item("更换模型…") { [weak self] in self?.chooseReplacement(id) })
            model.addItem(item("复制实例") { [weak self] in self?.attempt { _ = try self?.manager.duplicate(id) } })
            model.addItem(item("移除实例") { [weak self] in self?.manager.remove(id) })
        }
        menu.addItem(.separator())
        menu.addItem(item(manager.allHidden ? "恢复各实例显示状态" : "全部隐藏") { [weak self] in self?.manager.toggleAllHidden() })
        menu.addItem(item("重置各实例在绑定屏的位置") { [weak self] in
            guard let self else { return }; for record in manager.records { manager.resetPosition(record.settings.id) }
        })
        menu.addItem(item("刷新显示器连接状态") { [weak self] in self?.manager.refreshDisplayBindings() })
        menu.addItem(item("撤销上次移除", enabled: manager.removedSettings != nil) { [weak self] in self?.manager.undoRemove() })
        menu.addItem(.separator())
        let quit = item("退出 Lite2D") { NSApp.terminate(nil) }; quit.keyEquivalent = "q"; menu.addItem(quit)
    }
    private func attempt(_ body: () throws -> Void) {
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
    private func chooseModels() {
        let panel = panel(multiple: true); NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            var isDirectory: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            var candidates = [url]
            if isDirectory.boolValue {
                candidates = (FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
                    .filter { $0.lastPathComponent == "model.json" || $0.lastPathComponent.hasSuffix(".model3.json") || $0.lastPathComponent.hasSuffix(".model.json") }
                    .sorted { $0.path < $1.path }
            }
            for candidate in candidates { attempt { _ = try manager.add(candidate) } }
        }
    }
    private func chooseReplacement(_ id: UUID) {
        let panel = panel(multiple: false); NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        attempt { try manager.replace(id, with: url) }
    }
    private func rename(_ id: UUID) {
        guard let record = manager.record(id) else { return }
        let alert = NSAlert(); alert.messageText = "重命名实例"
        let input = NSTextField(string: record.settings.displayName); input.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = input; alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { manager.mutate(id) { $0.displayName = input.stringValue } }
    }
}
