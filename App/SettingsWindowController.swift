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
    case appearance, interaction, companion, advanced
    var title: String { L10n.text("settings." + rawValue) }
    var id: String { rawValue }
}

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    let model: SettingsWindowModel
    private var languageObserver: NSObjectProtocol?
    init(status: StatusBarController) {
        model = SettingsWindowModel(status: status)
        let host = NSHostingController(rootView: SettingsRootView(model: model))
        let window = NSWindow(contentViewController: host)
        window.title = L10n.text("settings.title")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 920, height: 700))
        window.minSize = NSSize(width: 820, height: 600)
        window.center()
        super.init(window: window)
        window.delegate = self
        languageObserver = NotificationCenter.default.addObserver(forName: .appLanguageChanged, object: nil, queue: .main) { [weak self] _ in
            self?.window?.title = L10n.text("settings.title")
            self?.model.objectWillChange.send()
        }
    }
    deinit { if let languageObserver { NotificationCenter.default.removeObserver(languageObserver) } }
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
    @ObservedObject private var language = LanguageStore.shared
    @ObservedObject var model: SettingsWindowModel
    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: $model.selection) {
                    Section(L10n.text("role.section")) {
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
                        Label(L10n.text("settings.general"), systemImage: "gearshape").tag("general")
                    }
                }
                Divider()
                Button(action: { model.status.chooseModels() }) {
                    Label(model.status.importInProgress ? L10n.text("import.busy") : L10n.text("role.add"), systemImage: "plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless).padding(.horizontal, 14).padding(.vertical, 12).disabled(model.status.importInProgress)
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
    @ObservedObject private var language = LanguageStore.shared
    @ObservedObject var model: SettingsWindowModel
    let record: ModelRecord
    @State private var name: String
    @State private var originalName: String
    @State private var removing = false
    @State private var previewGroup = ""
    @State private var previewIndex = 0
    @State private var hoveringName = false
    @FocusState private var editingName: Bool
    init(model: SettingsWindowModel, record: ModelRecord) {
        self.model = model; self.record = record
        _name = State(initialValue: record.settings.localizedDisplayName)
        _originalName = State(initialValue: record.settings.localizedDisplayName)
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
                TextField(L10n.text("role.name"), text: $name)
                    .textFieldStyle(.plain).font(.system(size: 25, weight: .semibold))
                    .focused($editingName).onSubmit(commitName)
                    .accessibilityLabel(L10n.text("role.name"))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(editingName || hoveringName ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(alignment: .trailing) {
                        if !editingName { Image(systemName: "pencil").font(.callout).foregroundStyle(.tertiary).padding(.trailing, 8).allowsHitTesting(false) }
                    }
                    .padding(.horizontal, -6)
                    .onHover { hoveringName = $0 }
                HStack(spacing: 6) {
                    Circle().fill(record.error != nil ? Color.orange : canAdjust ? .green : .secondary).frame(width: 7, height: 7)
                    Text(model.status.roleStatus(record))
                    if let screen = settings.boundDisplayName { Text("·"); Text(screen) }
                    Spacer()
                    Text(L10n.text("settings.autosave")).font(.caption)
                }.font(.callout).foregroundStyle(.secondary)
            }.padding(24)
            Picker(L10n.text("settings.group"), selection: $model.page) {
                ForEach(RoleSettingsPage.allCases) { Text($0.title).tag($0) }
            }.id(language.revision).pickerStyle(.segmented).labelsHidden().padding(.horizontal, 24).padding(.bottom, 16)
            if let error = record.error {
                notice(L10n.text("role.load_failure", L10n.error(error)), button: L10n.text("model.replace")) { model.status.chooseReplacement(id) }
            } else if !manager.isDisplayConnected(record) {
                notice(L10n.text("display.binding_notice"), button: L10n.text("display.choose")) { model.page = .appearance }
            } else if manager.allHidden {
                notice(L10n.text("role.hidden_notice"), button: L10n.text("role.restore")) { manager.toggleAllHidden() }
            }
            Form {
                switch model.page {
                case .appearance: appearance
                case .interaction: interaction
                case .companion:
                    if let companion = manager.companion { CompanionRoleSections(companion: companion, id: id, openGeneral: { model.selection = "general" }) }
                case .advanced: advanced
                }
            }.formStyle(.grouped)
        }
        .onChange(of: editingName) { _, focused in if focused { originalName = name } else { commitName() } }
        .onChange(of: settings.outfitID) { _, _ in previewIndex = 0 }
        .onChange(of: settings.localizedDisplayName) { _, value in if !editingName { name = value; originalName = value } }
        .onDisappear { commitName() }
        .sheet(isPresented: $removing) {
            RemoveCharacterConfirmation(settings: settings, cancel: { removing = false }, remove: {
                removing = false; manager.remove(id)
            })
        }
    }
    private func commitName() {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard manager.record(id) != nil else { return }
        if !cleaned.isEmpty && cleaned != originalName && cleaned != settings.localizedDisplayName { manager.mutate(id) { $0.displayName = cleaned; $0.generatedName = nil } }
        // An empty or whitespace-only name reverts to the stored one.
        name = settings.localizedDisplayName
        originalName = name
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
        Section(L10n.text("appearance.section")) {
            Toggle(L10n.text("role.show"), isOn: model.binding(record, \.isVisible)).disabled(record.error != nil)
            if record.outfits.count > 1 || settings.outfitID != nil {
                Picker(L10n.text("outfit.section"), selection: Binding(get: { settings.outfitID ?? "" }, set: { value in
                    model.status.attempt { try manager.setOutfit(id, outfitID: value) }
                })) {
                    ForEach(record.outfits, id: \.id) { Text($0.localizedName).tag($0.id) }
                }
            }
            let expressions = record.controller?.view.bridge.expressionNames ?? []
            if !expressions.isEmpty {
                Picker(L10n.text("expression.section"), selection: Binding(get: { settings.expressionId ?? "" }, set: { manager.setExpression(id, expression: $0) })) {
                    Text(L10n.text("common.default")).tag("")
                    ForEach(expressions, id: \.self) { Text($0).tag($0) }
                }
            }
            LabeledContent(L10n.text("appearance.size")) {
                HStack(spacing: 8) {
                    Text("\(Int((settings.scale * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary)
                    Stepper(L10n.text("appearance.size"), onIncrement: { manager.zoom(id, factor: 1.15) }, onDecrement: { manager.zoom(id, factor: 1 / 1.15) })
                        .labelsHidden()
                }
            }.disabled(record.error != nil)
        }
        Section {
            Picker(L10n.text("display.assigned"), selection: Binding(get: { settings.displayUUID ?? "" }, set: { manager.bind(id, to: $0) })) {
                if !manager.isDisplayConnected(record) { Text(settings.boundDisplayName.map { L10n.text("display.disconnected_name", $0) } ?? L10n.text("display.placeholder")).tag(settings.displayUUID ?? "") }
                ForEach(Array(manager.displayRegistry.displays.enumerated()), id: \.element.id) { index, display in
                    Text(L10n.text("format.numbered", display.name, String(index + 1))).tag(display.id)
                }
            }
            HStack {
                Button(settings.interactionMode == .edit ? L10n.text("placement.done") : L10n.text("placement.adjust")) { manager.edit(id) }.disabled(!canAdjust)
                Button(L10n.text("placement.front")) { manager.bringForward(id) }.disabled(!canAdjust)
                Button(L10n.text("placement.reset")) { manager.resetPosition(id) }.disabled(!manager.isDisplayConnected(record))
            }
        } header: { Text(L10n.text("placement.section")) } footer: {
            Text(settings.interactionMode == .edit ? L10n.text("placement.edit_help") : L10n.text("placement.help"))
        }
    }
    @ViewBuilder private var interaction: some View {
        Section {
            Toggle(L10n.text("motion.enabled"), isOn: Binding(
                get: { !settings.animationPaused },
                set: { enabled in manager.mutate(id) { $0.animationPaused = !enabled } }
            ))
            if !groups.isEmpty {
                Picker(L10n.text("motion.idle_group"), selection: Binding(get: { settings.idleMotionGroup ?? groups.first(where: { $0.lowercased() == "idle" }) ?? "" }, set: { manager.setIdle(id, group: $0) })) {
                    Text(L10n.text("common.none")).tag("")
                    if let selected = settings.idleMotionGroup, !selected.isEmpty, !groups.contains(selected) { Text(L10n.text("motion.unavailable_group", selected)).tag(selected) }
                    ForEach(groups, id: \.self) { Text($0).tag($0) }
                }
                DisclosureGroup(L10n.text("motion.weights")) {
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
                    Button(L10n.text("motion.reset_weights")) {
                        var overrides = settings.motionWeightOverrides
                        for motion in motions { overrides.removeValue(forKey: motion.key) }
                        manager.setMotionWeights(id, overrides: overrides)
                    }
                    Text(L10n.text("motion.weights_help")).font(.caption).foregroundStyle(.secondary)
                }
            } else { Text(L10n.text("motion.empty")).foregroundStyle(.secondary) }
        } header: { Text(L10n.text("motion.autoplay")) } footer: { Text(L10n.text("motion.autoplay_help")) }
        if !groups.isEmpty {
            Section(L10n.text("motion.preview")) {
                let selected = groups.contains(previewGroup) ? previewGroup : groups[0]
                Picker(L10n.text("motion.group"), selection: Binding(get: { selected }, set: { previewGroup = $0; previewIndex = 0 })) {
                    ForEach(groups, id: \.self) { Text($0).tag($0) }
                }
                let count = record.controller?.view.bridge.motionGroups[selected]?.intValue ?? 0
                Picker(L10n.text("motion.label"), selection: $previewIndex) {
                    ForEach(0..<count, id: \.self) { index in
                        Text(record.controller?.view.motions.first { $0.group == selected && $0.index == index }?.localizedName ?? L10n.text("motion.fallback", String(index + 1))).tag(index)
                    }
                }
                Button(L10n.text("motion.play_preview"), systemImage: "play.fill") { manager.play(id, group: selected, index: min(previewIndex, max(0, count - 1))) }
                    .disabled(settings.animationPaused || !canAdjust)
                if settings.animationPaused { Text(L10n.text("motion.paused_help")).font(.caption).foregroundStyle(.secondary) }
            }
        }
        Section(L10n.text("tracking.section")) {
            Toggle(L10n.text("tracking.enabled"), isOn: model.binding(record, \.trackingEnabled))
            Picker(L10n.text("tracking.smoothing"), selection: model.binding(record, \.trackingSmoothingSeconds)) {
                Text(L10n.text("tracking.responsive")).tag(0.06); Text(L10n.text("tracking.standard")).tag(0.14); Text(L10n.text("tracking.soft")).tag(0.30)
                if ![0.06, 0.14, 0.30].contains(settings.trackingSmoothingSeconds) { Text(L10n.text("common.custom")).tag(settings.trackingSmoothingSeconds) }
            }.disabled(!settings.trackingEnabled)
        }
        Section {
            Toggle(L10n.text("click.enabled"), isOn: model.binding(record, \.clickInteractionEnabled))
                .disabled(!settings.clickInteractionEnabled && !groups.contains(clickGroup))
            if !groups.isEmpty {
                Picker(L10n.text("click.group"), selection: Binding(get: { clickGroup }, set: { value in manager.mutate(id) { $0.clickMotionGroup = value } })) {
                    Text(L10n.text("common.choose")).tag("")
                    if !clickGroup.isEmpty && !groups.contains(clickGroup) { Text(L10n.text("motion.unavailable_group", clickGroup)).tag(clickGroup) }
                    ForEach(groups, id: \.self) { Text($0).tag($0) }
                }
            }
            if settings.clickInteractionEnabled && !groups.contains(clickGroup) {
                Text(L10n.text("click.unavailable")).foregroundStyle(.orange)
            }
        } header: { Text(L10n.text("click.section")) } footer: {
            Text(L10n.text("click.help"))
        }
    }
    @ViewBuilder private var advanced: some View {
        Section(L10n.text("performance.section")) {
            Picker(L10n.text("performance.fps"), selection: model.binding(record, \.targetFPS)) { Text("30 FPS").tag(30); Text("60 FPS").tag(60) }
            Text(L10n.text("performance.help")).font(.caption).foregroundStyle(.secondary)
        }
        Section {
            LabeledContent(L10n.text("file.location")) {
                Text((settings.modelPath as NSString).abbreviatingWithTildeInPath)
                    .lineLimit(2).truncationMode(.middle).multilineTextAlignment(.trailing).textSelection(.enabled)
            }
            LabeledContent(L10n.text("file.label")) {
                HStack {
                    Button(L10n.text("file.reveal")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: settings.modelPath)]) }
                    Button(L10n.text("model.replace")) { model.status.chooseReplacement(id) }
                }
            }
        } header: { Text(L10n.text("model.files")) } footer: { Text(L10n.text("model.replace_help")) }
        Section(L10n.text("role.management")) {
            LabeledContent(L10n.text("role.duplicate")) {
                Button(L10n.text("action.copy")) {
                    model.status.attempt {
                        if let copy = try manager.duplicate(id) { model.selection = copy.settings.id.uuidString }
                    }
                }
            }
            LabeledContent(L10n.text("role.remove")) { Button(L10n.text("role.remove_action"), role: .destructive) { removing = true } }
        }
    }
}

private struct MotionWeightSettingRow: View {
    @ObservedObject private var language = LanguageStore.shared
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
                Text(motion.localizedName)
                Text(L10n.text("motion.default_weight", ModelMotion.displayWeight(motion.defaultWeight))).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                TextField(L10n.text("motion.weight"), text: $text).labelsHidden().textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing).monospacedDigit().frame(width: 72).focused($focused)
                    .foregroundStyle(value == nil ? Color.red : Color.primary)
                    .accessibilityLabel(L10n.text("motion.weight_accessibility", motion.group, motion.localizedName))
                Stepper(L10n.text("motion.weight"), onIncrement: { step(1) }, onDecrement: { step(-1) }).labelsHidden()
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .help(value == nil ? L10n.text("motion.invalid_weight") : "")
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
    @ObservedObject private var language = LanguageStore.shared
    @ObservedObject var model: SettingsWindowModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.text("settings.general")).font(.system(size: 25, weight: .semibold)).padding(24)
            Form {
                Section {
                    Picker(L10n.text("language.label"), selection: Binding(get: { language.selection }, set: { language.selection = $0 })) {
                        ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
                    }
                } header: { Text(L10n.text("language.section")) } footer: {
                    Text(L10n.text("language.help"))
                }
                Section(L10n.text("startup.section")) {
                    Toggle(L10n.text("startup.login"), isOn: Binding(get: { model.login.isRegistered }, set: { model.toggleLogin($0) }))
                        .disabled(model.updatingLogin)
                    if model.updatingLogin { ProgressView().controlSize(.small) }
                    if model.login.status == .requiresApproval {
                        Text(L10n.text("startup.approval")).foregroundStyle(.secondary)
                        Button(L10n.text("startup.open_settings")) { model.login.openSystemSettings() }
                    }
                }
                if let companion = model.manager.companion { CompanionGeneralSections(companion: companion) }
                Section {
                    Button(model.manager.allHidden ? L10n.text("role.restore_all") : L10n.text("role.hide_all")) { model.manager.toggleAllHidden() }.disabled(model.manager.records.isEmpty)
                    Button(L10n.text("role.undo_remove")) { model.manager.undoRemove() }.disabled(model.manager.removedSettings == nil)
                } header: { Text(L10n.text("role.section")) } footer: { Text(L10n.text("role.hide_help")) }
                Section(L10n.text("display.section")) {
                    Button(L10n.text("display.refresh")) { model.manager.refreshDisplayBindings() }
                    Button(L10n.text("placement.reset_all")) { for record in model.manager.records { model.manager.resetPosition(record.settings.id) } }
                    Text(L10n.text("placement.reset_help")).font(.caption).foregroundStyle(.secondary)
                }
                Section(L10n.text("about.section")) {
                    LabeledContent("Lite2D", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
                    Text(L10n.text("about.description")).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
        }
    }
}

private struct RemoveCharacterConfirmation: View {
    @ObservedObject private var language = LanguageStore.shared
    let settings: ModelInstanceSettings
    let cancel: () -> Void
    let remove: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("role.remove_confirm", settings.localizedDisplayName)).font(.headline)
            Text(L10n.text("role.remove_help")).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(L10n.text("action.cancel"), action: cancel).keyboardShortcut(.cancelAction)
                Button(L10n.text("role.remove"), role: .destructive, action: remove)
            }
        }.padding(24).frame(width: 420)
    }
}
