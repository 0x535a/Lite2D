import AppKit
import SwiftUI
import ServiceManagement

// The manager remains the source of truth for both the menu and this window.
final class SettingsWindowModel: ObservableObject {
    unowned let status: StatusBarController
    var manager: ModelInstanceManager { status.manager }
    @Published var selection: String?
    @Published var page = RoleSettingsPage.appearance
    @Published var updatingLogin = false
    let login = LaunchAtLogin()

    init(status: StatusBarController) {
        self.status = status
        selection = status.manager.records.first?.settings.id.uuidString ?? "general"
        status.manager.onChange = { [weak self] in
            guard let self else { return }
            if let selection, selection != "general", !manager.records.contains(where: { $0.settings.id.uuidString == selection }) {
                self.selection = manager.records.first?.settings.id.uuidString ?? "general"
            }
            objectWillChange.send()
        }
    }
    func binding<Value>(_ record: ModelRecord, _ path: WritableKeyPath<ModelInstanceSettings, Value>) -> Binding<Value> {
        let id = record.settings.id
        let fallback = record.settings[keyPath: path]
        return Binding(get: { self.manager.record(id)?.settings[keyPath: path] ?? fallback },
                set: { value in self.manager.mutate(id) { $0[keyPath: path] = value } })
    }
    func toggleLogin(_ enabled: Bool) {
        guard !updatingLogin else { return }
        updatingLogin = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { updatingLogin = false }
            do { try await login.setEnabled(enabled) }
            catch {
                if enabled && login.status == .requiresApproval { return }
                status.attempt { throw error }
            }
        }
    }
}

enum RoleSettingsPage: String, CaseIterable, Identifiable {
    case appearance = "外观与摆放", interaction = "动作与互动", advanced = "高级"
    var id: String { rawValue }
}

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    let model: SettingsWindowModel
    init(status: StatusBarController) {
        model = SettingsWindowModel(status: status)
        let host = NSHostingController(rootView: SettingsRootView(model: model))
        let window = NSWindow(contentViewController: host)
        window.title = "Lite2D 设置"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 920, height: 700))
        window.minSize = NSSize(width: 820, height: 600)
        window.center()
        super.init(window: window)
        window.delegate = self
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.makeFirstResponder(nil)
        return true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    func show(role: UUID? = nil, resetPage: Bool = false) {
        if let role { model.selection = role.uuidString }
        if resetPage { model.page = .appearance }
        if model.selection == nil { model.selection = model.manager.records.first?.settings.id.uuidString ?? "general" }
        model.objectWillChange.send()
        let wasVisible = window?.isVisible == true
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        // AppKit hands initial focus to the first text field, which would open the window with the title selected.
        if !wasVisible { DispatchQueue.main.async { [weak self] in self?.window?.makeFirstResponder(nil) } }
    }
}

private struct SettingsRootView: View {
    @ObservedObject var model: SettingsWindowModel
    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: $model.selection) {
                    Section("角色") {
                        ForEach(model.manager.records, id: \.settings.id) { record in
                            HStack(spacing: 10) {
                                Image(systemName: record.error == nil ? "person.crop.square" : "exclamationmark.triangle")
                                    .font(.title3).foregroundStyle(record.error == nil ? Color.accentColor : .orange)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(model.status.roleName(record)).lineLimit(1)
                                    Text(model.status.roleStatus(record)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                            .tag(record.settings.id.uuidString)
                        }
                    }
                    Section {
                        Label("通用设置", systemImage: "gearshape").tag("general")
                    }
                }
                Divider()
                Button(action: { model.status.chooseModels() }) {
                    Label(model.status.importInProgress ? "正在导入…" : "添加角色…", systemImage: "plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless).padding(16).disabled(model.status.importInProgress)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 280)
        } detail: {
            if let selection = model.selection, let id = UUID(uuidString: selection), let record = model.manager.record(id) {
                RoleSettingsView(model: model, record: record).id(id)
            } else {
                GeneralSettingsView(model: model)
            }
        }
        .frame(minWidth: 800, minHeight: 560)
        .dropDestination(for: URL.self) { urls, _ in
            guard !model.status.importInProgress, !urls.isEmpty, urls.allSatisfy(\.isFileURL) else { return false }
            model.status.importModels(urls)
            return true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in model.objectWillChange.send() }
    }
}

private struct RoleSettingsView: View {
    @ObservedObject var model: SettingsWindowModel
    let record: ModelRecord
    @State private var name: String
    @State private var removing = false
    @State private var previewGroup = ""
    @State private var previewIndex = 0
    @FocusState private var editingName: Bool
    init(model: SettingsWindowModel, record: ModelRecord) {
        self.model = model; self.record = record
        _name = State(initialValue: record.settings.displayName)
    }
    var manager: ModelInstanceManager { model.manager }
    var id: UUID { record.settings.id }
    var settings: ModelInstanceSettings { record.settings }
    var groups: [String] {
        (record.controller?.view.bridge.motionGroups ?? [:]).keys.sorted().filter { (record.controller?.view.bridge.motionGroups[$0]?.intValue ?? 0) > 0 }
    }
    var clickGroup: String { record.controller?.view.clickMotionGroup ?? settings.clickMotionGroup ?? "" }
    var canAdjust: Bool { record.error == nil && settings.isVisible && !manager.allHidden && manager.isDisplayConnected(record) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("角色名称", text: $name)
                    .textFieldStyle(.plain).font(.system(size: 25, weight: .semibold))
                    .focused($editingName).onSubmit(commitName)
                    .accessibilityLabel("角色名称")
                HStack(spacing: 6) {
                    Circle().fill(record.error != nil ? Color.orange : canAdjust ? .green : .secondary).frame(width: 7, height: 7)
                    Text(model.status.roleStatus(record))
                    if let screen = settings.boundDisplayName { Text("·"); Text(screen) }
                    Spacer()
                    Text("自动保存").font(.caption)
                }.font(.callout).foregroundStyle(.secondary)
            }.padding(24)
            Picker("设置分组", selection: $model.page) {
                ForEach(RoleSettingsPage.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 24).padding(.bottom, 16)
            if let error = record.error {
                notice("模型加载失败：\(error)", button: "更换模型…") { model.status.chooseReplacement(id) }
            } else if !manager.isDisplayConnected(record) {
                notice("绑定屏幕未连接或尚未绑定。请在“外观与摆放”中选择显示器。", button: "选择显示器") { model.page = .appearance }
            } else if manager.allHidden {
                notice("所有角色已被临时隐藏，恢复后会保留各角色原来的显示偏好。", button: "恢复显示") { manager.toggleAllHidden() }
            }
            Form {
                switch model.page {
                case .appearance: appearance
                case .interaction: interaction
                case .advanced: advanced
                }
            }.formStyle(.grouped)
        }
        .onChange(of: editingName) { _, focused in if !focused { commitName() } }
        .onChange(of: settings.outfitID) { _, _ in previewIndex = 0 }
        .onChange(of: settings.displayName) { _, value in if !editingName { name = value } }
        .onDisappear { commitName() }
        .alert("移除“\(settings.displayName)”？", isPresented: $removing) {
            Button("取消", role: .cancel) {}
            Button("移除角色", role: .destructive) { manager.remove(id) }
        } message: { Text("不会删除模型文件。可在通用设置中撤销最近一次移除。") }
    }
    private func commitName() {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard manager.record(id) != nil else { return }
        if !cleaned.isEmpty && cleaned != settings.displayName { manager.mutate(id) { $0.displayName = cleaned } }
        // An empty or whitespace-only name reverts to the stored one.
        name = cleaned.isEmpty ? settings.displayName : cleaned
    }
    private func notice(_ message: String, button: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
            Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(button, action: action)
        }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 24).padding(.bottom, 8)
    }
    @ViewBuilder private var appearance: some View {
        Section("外观") {
            Toggle("显示角色", isOn: model.binding(record, \.isVisible)).disabled(record.error != nil)
            if record.outfits.count > 1 || settings.outfitID != nil {
                Picker("服装", selection: Binding(get: { settings.outfitID ?? "" }, set: { value in
                    model.status.attempt { try manager.setOutfit(id, outfitID: value) }
                })) {
                    ForEach(record.outfits, id: \.id) { Text($0.name).tag($0.id) }
                }
            }
            let expressions = record.controller?.view.bridge.expressionNames ?? []
            if !expressions.isEmpty {
                Picker("表情", selection: Binding(get: { settings.expressionId ?? "" }, set: { manager.setExpression(id, expression: $0) })) {
                    Text("默认").tag("")
                    ForEach(expressions, id: \.self) { Text($0).tag($0) }
                }
            }
            LabeledContent("大小") {
                HStack(spacing: 8) {
                    Text("\(Int((settings.scale * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary)
                    Stepper("大小", onIncrement: { manager.zoom(id, factor: 1.15) }, onDecrement: { manager.zoom(id, factor: 1 / 1.15) })
                        .labelsHidden()
                }
            }.disabled(record.error != nil)
        }
        Section {
            Picker("所属显示器", selection: Binding(get: { settings.displayUUID ?? "" }, set: { manager.bind(id, to: $0) })) {
                if !manager.isDisplayConnected(record) { Text(settings.boundDisplayName.map { "\($0)（未连接）" } ?? "请选择显示器").tag(settings.displayUUID ?? "") }
                ForEach(Array(manager.displayRegistry.displays.enumerated()), id: \.element.id) { index, display in
                    Text("\(display.name)（\(index + 1)）").tag(display.id)
                }
            }
            HStack {
                Button(settings.interactionMode == .edit ? "完成调整" : "调整位置与大小") { manager.edit(id) }.disabled(!canAdjust)
                Button("置于最前") { manager.bringForward(id) }.disabled(!canAdjust)
                Button("重置位置") { manager.resetPosition(id) }.disabled(!manager.isDisplayConnected(record))
            }
        } header: { Text("摆放") } footer: {
            Text(settings.interactionMode == .edit ? "正在调整：拖动角色移动，滚轮缩放。完成后点击“完成调整”。" : "进入调整模式后，可拖动角色、滚轮缩放；每次只调整一个角色。屏幕断开时角色会隐藏，重连后恢复。")
        }
    }
    @ViewBuilder private var interaction: some View {
        Section {
            Toggle("暂停动作", isOn: model.binding(record, \.animationPaused))
            if !groups.isEmpty {
                Picker("自动播放动作组", selection: Binding(get: { settings.idleMotionGroup ?? groups.first(where: { $0.lowercased() == "idle" }) ?? "" }, set: { manager.setIdle(id, group: $0) })) {
                    Text("无").tag("")
                    if let selected = settings.idleMotionGroup, !selected.isEmpty, !groups.contains(selected) { Text("\(selected)（当前服装不可用）").tag(selected) }
                    ForEach(groups, id: \.self) { Text($0).tag($0) }
                }
                DisclosureGroup("动作权重") {
                    let motions = record.controller?.view.motions ?? []
                    ForEach(groups, id: \.self) { group in
                        DisclosureGroup(group) {
                            ForEach(motions.filter { $0.group == group }, id: \.key) { motion in
                                MotionWeightSettingRow(motion: motion, weight: motion.weight(overrides: settings.motionWeightOverrides)) { value in
                                    var overrides = settings.motionWeightOverrides
                                    if value == motion.defaultWeight { overrides.removeValue(forKey: motion.key) }
                                    else { overrides[motion.key] = value }
                                    manager.setMotionWeights(id, overrides: overrides)
                                }
                            }
                        }
                    }
                    Button("恢复当前服装的默认权重") {
                        var overrides = settings.motionWeightOverrides
                        for motion in motions { overrides.removeValue(forKey: motion.key) }
                        manager.setMotionWeights(id, overrides: overrides)
                    }
                    Text("0 表示不参与自动播放；组内全部为 0 时停止自动选播。手动预览不受权重限制。").font(.caption).foregroundStyle(.secondary)
                }
            } else { Text("当前模型或服装没有可用动作。").foregroundStyle(.secondary) }
        } header: { Text("自动播放") } footer: { Text("按权重随机播放所选组内的动作，允许连续重复。权重修改在下次选播时生效。") }
        if !groups.isEmpty {
            Section("手动预览") {
                let selected = groups.contains(previewGroup) ? previewGroup : groups[0]
                Picker("动作组", selection: Binding(get: { selected }, set: { previewGroup = $0; previewIndex = 0 })) {
                    ForEach(groups, id: \.self) { Text($0).tag($0) }
                }
                let count = record.controller?.view.bridge.motionGroups[selected]?.intValue ?? 0
                Picker("动作", selection: $previewIndex) {
                    ForEach(0..<count, id: \.self) { index in
                        Text(record.controller?.view.motions.first { $0.group == selected && $0.index == index }?.name ?? "动作 \(index + 1)").tag(index)
                    }
                }
                Button("播放预览", systemImage: "play.fill") { manager.play(id, group: selected, index: min(previewIndex, max(0, count - 1))) }
                    .disabled(settings.animationPaused || !canAdjust)
                if settings.animationPaused { Text("继续播放动作后即可预览。").font(.caption).foregroundStyle(.secondary) }
            }
        }
        Section("鼠标跟随") {
            Toggle("视线跟随鼠标", isOn: model.binding(record, \.trackingEnabled))
            Picker("跟随平滑度", selection: model.binding(record, \.trackingSmoothingSeconds)) {
                Text("灵敏").tag(0.06); Text("标准").tag(0.14); Text("柔和").tag(0.30)
                if ![0.06, 0.14, 0.30].contains(settings.trackingSmoothingSeconds) { Text("自定义").tag(settings.trackingSmoothingSeconds) }
            }.disabled(!settings.trackingEnabled)
        }
        Section {
            Toggle("点击角色触发动作", isOn: model.binding(record, \.clickInteractionEnabled))
                .disabled(!settings.clickInteractionEnabled && !groups.contains(clickGroup))
            if !groups.isEmpty {
                Picker("点击动作组", selection: Binding(get: { clickGroup }, set: { value in manager.mutate(id) { $0.clickMotionGroup = value } })) {
                    Text("请选择").tag("")
                    if !clickGroup.isEmpty && !groups.contains(clickGroup) { Text("\(clickGroup)（当前服装不可用）").tag(clickGroup) }
                    ForEach(groups, id: \.self) { Text($0).tag($0) }
                }
            }
            if settings.clickInteractionEnabled && !groups.contains(clickGroup) {
                Text("所选动作组在当前服装中不可用，点击互动暂时停用。").foregroundStyle(.orange)
            }
        } header: { Text("点击互动") } footer: {
            Text("点击角色可见部分时随机播放所选组内的动作，同时底下的应用也会收到点击。调整、暂停或隐藏期间不触发；动作播放期间忽略重复点击。")
        }
    }
    @ViewBuilder private var advanced: some View {
        Section("性能") {
            Picker("帧率", selection: model.binding(record, \.targetFPS)) { Text("30 FPS").tag(30); Text("60 FPS").tag(60) }
            Text("较低帧率可减少资源消耗，每个角色独立保存。").font(.caption).foregroundStyle(.secondary)
        }
        Section {
            LabeledContent("位置") {
                Text((settings.modelPath as NSString).abbreviatingWithTildeInPath)
                    .lineLimit(2).truncationMode(.middle).multilineTextAlignment(.trailing).textSelection(.enabled)
            }
            LabeledContent("文件") {
                HStack {
                    Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: settings.modelPath)]) }
                    Button("更换模型…") { model.status.chooseReplacement(id) }
                }
            }
        } header: { Text("模型文件") } footer: { Text("更换模型保留位置和显示设置，重置服装、表情及动作配置。") }
        Section("角色管理") {
            LabeledContent("复制角色") {
                Button("复制") {
                    model.status.attempt {
                        if let copy = try manager.duplicate(id) { model.selection = copy.settings.id.uuidString }
                    }
                }
            }
            LabeledContent("移除角色") { Button("移除…", role: .destructive) { removing = true } }
        }
    }
}

private struct MotionWeightSettingRow: View {
    let motion: ModelMotion
    let weight: Double
    let update: (Double) -> Void
    @State private var text: String
    init(motion: ModelMotion, weight: Double, update: @escaping (Double) -> Void) {
        self.motion = motion; self.weight = weight; self.update = update
        _text = State(initialValue: ModelMotion.displayWeight(weight))
    }
    @FocusState private var focused: Bool
    private var value: Double? { Double(text).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } }
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(motion.name)
                Text("默认 \(ModelMotion.displayWeight(motion.defaultWeight))").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                TextField("权重", text: $text).labelsHidden().textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing).monospacedDigit().frame(width: 72).focused($focused)
                    .foregroundStyle(value == nil ? Color.red : Color.primary)
                    .accessibilityLabel("\(motion.group) · \(motion.name) 权重")
                Stepper("权重", onIncrement: { step(1) }, onDecrement: { step(-1) }).labelsHidden()
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .help(value == nil ? "请输入不小于 0 的数字" : "")
        .onChange(of: text) { _, _ in if let value, value != weight { update(value) } }
        .onChange(of: weight) { _, value in if !focused { text = ModelMotion.displayWeight(value) } }
        .onChange(of: focused) { _, value in if !value { text = ModelMotion.displayWeight(weight) } }
    }
    private func step(_ delta: Double) {
        let next = max(0, (value ?? weight) + delta)
        text = ModelMotion.displayWeight(next)
    }
}

private struct GeneralSettingsView: View {
    @ObservedObject var model: SettingsWindowModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("通用设置").font(.system(size: 25, weight: .semibold)).padding(24)
            Form {
                Section("启动") {
                    Toggle("登录时自动启动", isOn: Binding(get: { model.login.isRegistered }, set: { model.toggleLogin($0) }))
                        .disabled(model.updatingLogin)
                    if model.updatingLogin { ProgressView().controlSize(.small) }
                    if model.login.status == .requiresApproval {
                        Text("等待系统允许登录启动。").foregroundStyle(.secondary)
                        Button("在系统设置中允许…") { model.login.openSystemSettings() }
                    }
                }
                Section {
                    Button(model.manager.allHidden ? "恢复角色显示" : "隐藏所有角色") { model.manager.toggleAllHidden() }.disabled(model.manager.records.isEmpty)
                    Button("撤销上次移除") { model.manager.undoRemove() }.disabled(model.manager.removedSettings == nil)
                } header: { Text("角色") } footer: { Text("隐藏所有角色是临时操作，恢复时保留每个角色原来的显示偏好。") }
                Section("显示器") {
                    Button("刷新显示器连接状态") { model.manager.refreshDisplayBindings() }
                    Button("重置所有角色的位置") { for record in model.manager.records { model.manager.resetPosition(record.settings.id) } }
                    Text("重置位置保留显示器绑定；屏幕未连接的角色不会迁移到其他屏幕。").font(.caption).foregroundStyle(.secondary)
                }
                Section("关于") {
                    LabeledContent("Lite2D", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
                    Text("macOS 原生 Live2D 桌面角色").foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
        }
    }
}
