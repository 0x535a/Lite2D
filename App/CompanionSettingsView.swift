import AppKit
import SwiftUI

struct CompanionRoleSections: View {
    @ObservedObject private var language = LanguageStore.shared
    @ObservedObject var companion: CompanionCoordinator
    let id: UUID
    var openGeneral: () -> Void = {}
    private var enabled: Binding<Bool> { Binding(get: { companion.character(id).enabled }, set: { value in companion.updateCharacter(id) { $0.enabled = value } }) }
    var body: some View {
        Section {
            Toggle(L10n.text("companion.character_enabled"), isOn: enabled).disabled(!companion.hasPersona(id))
            LabeledContent(L10n.text("companion.persona")) {
                HStack {
                    Button(companion.hasPersona(id) ? L10n.text("companion.replace_persona") : L10n.text("companion.import_persona")) { companion.importPersona(id) }
                    if companion.hasPersona(id) { Button(L10n.text("companion.edit_persona")) { companion.editPersona(id) } }
                }
            }
            if companion.hasPersona(id) { Text("persona.md").font(.caption).foregroundStyle(.secondary) }
            Toggle(L10n.text("companion.gaze"), isOn: Binding(get: { companion.character(id).gaze }, set: { value in companion.updateCharacter(id) { $0.gaze = value } }))
            let groups = (companion.manager?.record(id)?.controller?.view.bridge.motionGroups ?? [:]).keys.sorted()
            if !groups.isEmpty {
                Picker(L10n.text("companion.reaction_motion"), selection: Binding(get: { companion.character(id).reactionMotionGroup ?? "" }, set: { value in
                    companion.updateCharacter(id) { $0.reactionMotionGroup = value.isEmpty ? nil : value }
                })) {
                    Text(L10n.text("common.none")).tag("")
                    ForEach(groups, id: \.self) { Text($0).tag($0) }
                }
            }
        } header: { Text(L10n.text("companion.personality")) } footer: { Text(L10n.text("companion.persona_help")).fixedSize(horizontal: false, vertical: true) }
        if let error = companion.roleErrors[id.uuidString] { Section { Text(error).foregroundStyle(.orange).textSelection(.enabled) } }
        Section {
            Button(L10n.text("companion.history")) { companion.showHistory() }
            Text(L10n.text("companion.role_help")).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } header: { Text(L10n.text("companion.continuity")) }
        Section(L10n.text("companion.section")) {
            LabeledContent(L10n.text("companion.state")) { Text(L10n.text("companion.state." + companion.runtimeState)).foregroundStyle(.secondary) }
            Button(L10n.text("settings.general"), action: openGeneral)
            Text(L10n.text("companion.shared_settings_help")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct CompanionGeneralSections: View {
    @ObservedObject private var language = LanguageStore.shared
    @ObservedObject var companion: CompanionCoordinator
    func binding<T>(_ key: WritableKeyPath<CompanionSettings, T>) -> Binding<T> {
        Binding(get: { companion.settings[keyPath: key] }, set: { companion.settings[keyPath: key] = $0; companion.changed() })
    }
    var body: some View {
        Section {
            Toggle(L10n.text("companion.enabled"), isOn: binding(\.enabled))
            Toggle(L10n.text("companion.paused"), isOn: binding(\.paused)).disabled(!companion.settings.enabled)
            LabeledContent(L10n.text("companion.state")) {
                Text(L10n.text("companion.state." + companion.runtimeState)).foregroundStyle(.secondary)
            }
            HStack {
                Button(L10n.text("companion.stop")) { companion.stopTopic() }.disabled(!companion.busy)
                Button(L10n.text("companion.history")) { companion.showHistory() }
                if companion.settings.enabled { Button(L10n.text("companion.retry")) { companion.retry() } }
            }
            if let error = companion.error { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
        } header: { Text(L10n.text("companion.section")) } footer: { Text(L10n.text("companion.scope_help")).fixedSize(horizontal: false, vertical: true) }
        Section {
            LabeledContent(L10n.text("companion.interval")) {
                HStack {
                    Text(companion.settings.intervalMinutes == 0 ? L10n.text("companion.off") : L10n.text("companion.minutes", String(companion.settings.intervalMinutes))).monospacedDigit().foregroundStyle(.secondary)
                    Stepper(L10n.text("companion.interval"), value: binding(\.intervalMinutes), in: 0...1440, step: 1).labelsHidden()
                }
            }
            HStack {
                ForEach([0, 5, 15, 30, 60], id: \.self) { minutes in
                    Button(minutes == 0 ? L10n.text("companion.off") : L10n.text("companion.minutes", String(minutes))) {
                        companion.settings.intervalMinutes = minutes; companion.changed()
                    }
                }
            }
            Stepper(L10n.text("companion.budget", String(companion.settings.hourlyRequests)), value: binding(\.hourlyRequests), in: 1...120)
        } header: { Text(L10n.text("companion.initiative")) } footer: { Text(L10n.text("companion.interval_help")).fixedSize(horizontal: false, vertical: true) }
        Section {
            ForEach(["opencode", "codex", "claude"], id: \.self) { backend in
                CompanionSourceRow(companion: companion, backend: backend)
            }
        } header: { Text(L10n.text("companion.observers")) } footer: { Text(L10n.text("companion.observer_help")).fixedSize(horizontal: false, vertical: true) }
        Section {
            LabeledContent(L10n.text("companion.model")) {
                TextField("provider/model", text: binding(\.model)).labelsHidden().frame(maxWidth: 250)
            }
            DisclosureGroup(L10n.text("companion.dependencies")) {
                TextField("Node.js", text: binding(\.nodePath), prompt: Text(companion.executable("node") ?? L10n.text("companion.not_found")))
                TextField("OpenCode", text: binding(\.opencodePath), prompt: Text(companion.executable("opencode") ?? L10n.text("companion.not_found")))
                TextField("Codex", text: binding(\.codexPath), prompt: Text(companion.executable("codex") ?? L10n.text("companion.not_found")))
                Text(L10n.text("companion.dependencies_help")).font(.caption).foregroundStyle(.secondary)
            }
        } header: { Text(L10n.text("companion.runtime")) } footer: { Text(L10n.text("companion.model_help")).fixedSize(horizontal: false, vertical: true) }
    }
}

private struct CompanionSourceRow: View {
    @ObservedObject private var language = LanguageStore.shared
    @ObservedObject var companion: CompanionCoordinator
    let backend: String
    var name: String { ["opencode": "OpenCode", "codex": "Codex", "claude": "Claude Code"][backend] ?? backend }
    var value: CompanionSourceSettings { companion.settings.sources[backend] ?? .init() }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(name, isOn: Binding(get: { value.enabled }, set: { enabled in
                var copy = value; copy.enabled = enabled; companion.settings.sources[backend] = copy; companion.changed()
            }))
            if value.enabled {
                let state = companion.sources[backend]?["state"] as? String ?? "disabled"
                HStack {
                    Image(systemName: state == "available" ? "checkmark.circle" : "info.circle")
                    Text(L10n.text("companion.source." + state))
                    if let count = companion.sources[backend]?["count"] as? Int { Text(L10n.text("companion.sessions", String(count))) }
                }.font(.caption).foregroundStyle(state == "unavailable" ? Color.orange : Color.secondary)
                if let message = companion.sources[backend]?["message"] as? String { Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                ForEach(value.projects, id: \.self) { project in
                    HStack {
                        Text((project as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle).help(project)
                        Spacer()
                        Button { var copy = value; copy.projects.removeAll { $0 == project }; companion.settings.sources[backend] = copy; companion.changed() } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).accessibilityLabel(L10n.text("companion.remove_project"))
                    }
                }
                Button(L10n.text("companion.add_project")) {
                    let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
                    panel.message = L10n.text("companion.observer_help")
                    if panel.runModal() == .OK, let url = panel.url {
                        let project = url.resolvingSymlinksInPath().standardizedFileURL.path
                        var copy = value; if !copy.projects.contains(project) { copy.projects.append(project) }
                        companion.settings.sources[backend] = copy; companion.changed()
                    }
                }
            }
        }.padding(.vertical, 5)
    }
}

struct CompanionHistoryView: View {
    @ObservedObject var companion: CompanionCoordinator
    @ObservedObject private var language = LanguageStore.shared
    @State private var page = "history"
    @State private var selectedRecord = ""
    @State private var recordText = ""
    @State private var clearing = false
    @State private var memorySelection: CompanionMemorySelection?
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.text("companion.history")).font(.title2.bold())
                Spacer()
                Button(L10n.text("companion.stop")) { companion.stopTopic() }.disabled(!companion.busy)
            }.padding(20)
            Picker(L10n.text("companion.history"), selection: $page) {
                Text(L10n.text("companion.conversation")).tag("history")
                Text(L10n.text("companion.public_memory")).tag("memory")
            }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 20).padding(.bottom, 12)
            if page == "history" {
                if companion.entries.isEmpty {
                    ContentUnavailableView(L10n.text("companion.empty_history"), systemImage: "bubble.left.and.bubble.right")
                } else {
                    List(companion.entries) { entry in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(entry.characterId.flatMap(UUID.init(uuidString:)).flatMap { companion.manager?.record($0)?.settings.localizedDisplayName } ?? entry.name ?? "Lite2D").font(.headline)
                                Spacer()
                                Text(entry.at.replacingOccurrences(of: "T", with: " ").prefix(19)).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(entry.text).textSelection(.enabled).foregroundStyle(entry.type == "error" ? Color.orange : Color.primary)
                        }.padding(.vertical, 5)
                    }
                }
            } else {
                Form {
                    Section(L10n.text("companion.public_memory")) {
                        if companion.records.isEmpty { Text(L10n.text("companion.empty_memory")).foregroundStyle(.secondary) }
                        ForEach(companion.records, id: \.self["path"]) { record in
                            LabeledContent(record["path"] ?? "") {
                                Button(L10n.text("companion.edit_memory")) {
                                    memorySelection = .init(id: record["path"] ?? "", content: record["content"] ?? "", revision: record["revision"] ?? "", isPrivate: false)
                                }
                            }
                        }
                        Button(L10n.text("companion.refresh")) { companion.send(["type": "records"]) }
                    }
                    Section(L10n.text("companion.private_memory")) {
                        ForEach(companion.manager?.records ?? [], id: \.settings.id) { record in
                            LabeledContent(record.settings.localizedDisplayName) {
                                Button(L10n.text("companion.inspect_memory")) {
                                    companion.exportMemory(record.settings.id)
                                    memorySelection = .init(id: record.settings.id.uuidString, content: companion.memoryContents[record.settings.id.uuidString] ?? "", revision: "", isPrivate: true)
                                }
                            }
                        }
                    }
                }.formStyle(.grouped)
            }
            Divider()
            HStack {
                Text(L10n.text("companion.no_input")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.text("companion.clear"), role: .destructive) { clearing = true }
            }.padding(16)
        }.frame(minWidth: 560, minHeight: 440)
        .onChange(of: page) { _, value in if value == "memory" { companion.send(["type": "records"]) } }
        .sheet(item: $memorySelection) { selection in CompanionMemoryEditor(companion: companion, selection: selection) }
        .confirmationDialog(L10n.text("companion.clear_confirm"), isPresented: $clearing, titleVisibility: .visible) {
            Button(L10n.text("companion.clear"), role: .destructive) { companion.send(["type": "clear", "scope": page == "history" ? "history" : "public"]) }
        } message: { Text(L10n.text("companion.clear_help")) }
    }
    static func makeWindow(coordinator: CompanionCoordinator) -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: CompanionHistoryView(companion: coordinator)))
        window.title = L10n.text("companion.history"); window.isReleasedWhenClosed = false
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 680, height: 560)); window.center(); return window
    }
}

private struct CompanionMemorySelection: Identifiable {
    let id: String
    let content: String
    let revision: String
    let isPrivate: Bool
}
private struct CompanionMemoryEditor: View {
    @ObservedObject var companion: CompanionCoordinator
    let selection: CompanionMemorySelection
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var resetting = false
    init(companion: CompanionCoordinator, selection: CompanionMemorySelection) {
        self.companion = companion; self.selection = selection; _text = State(initialValue: selection.content)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text(selection.isPrivate ? "companion.private_memory" : "companion.public_memory")).font(.headline)
            TextEditor(text: $text).font(.system(.body, design: .monospaced)).frame(minHeight: 240).border(.quaternary)
            Text(L10n.text("companion.memory_help")).font(.caption).foregroundStyle(.secondary)
            HStack {
                if selection.isPrivate {
                    Button(L10n.text("companion.reset_context"), role: .destructive) { resetting = true }
                }
                Spacer()
                Button(L10n.text("action.cancel")) { dismiss() }
                Button(L10n.text("companion.save")) {
                    if selection.isPrivate { companion.send(["type": "saveMemory", "characterId": selection.id, "content": text]) }
                    else { companion.send(["type": "saveRecord", "path": selection.id, "content": text, "expectedRevision": selection.revision]) }
                    dismiss()
                }.keyboardShortcut(.defaultAction).disabled(text.utf8.count > 32768)
            }
        }.padding(20).frame(width: 580)
        .onReceive(companion.$memoryContents) { values in
            if selection.isPrivate, text == selection.content, let value = values[selection.id] { text = value }
        }
        .confirmationDialog(L10n.text("companion.reset_context"), isPresented: $resetting, titleVisibility: .visible) {
            Button(L10n.text("companion.reset_context"), role: .destructive) {
                companion.send(["type": "clear", "scope": selection.id]); dismiss()
            }
        } message: { Text(L10n.text("companion.reset_context_help")) }
    }
}
