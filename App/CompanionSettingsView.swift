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
            LabeledContent {
                HStack {
                    Button(companion.hasPersona(id) ? L10n.text("companion.replace_persona") : L10n.text("companion.import_persona")) { companion.importPersona(id) }
                    if companion.hasPersona(id) {
                        Button(L10n.text("companion.edit_persona")) { companion.editPersona(id) }
                        Button(L10n.text("companion.generated_persona")) { companion.showGeneratedPersona(id) }
                    }
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("companion.persona"))
                    if companion.hasPersona(id) { Text("persona.md").font(.caption).foregroundStyle(.secondary) }
                }
            }
        } header: { Text(L10n.text("companion.personality")) } footer: { Text(L10n.text("companion.persona_help")).fixedSize(horizontal: false, vertical: true) }
        Section {
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
        }
        if let error = companion.roleErrors[id.uuidString] { Section { Text(error).foregroundStyle(.orange).textSelection(.enabled) } }
        Section {
            LabeledContent(L10n.text("companion.trigger")) {
                Button(L10n.text("companion.trigger_action")) { companion.trigger(id) }.disabled(!companion.canTrigger(id))
            }
            Text(L10n.text("companion.trigger_help")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            LabeledContent(L10n.text("companion.history")) {
                Button(L10n.text("companion.open_history")) { companion.showHistory() }
            }
            Text(L10n.text("companion.role_help")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } header: { Text(L10n.text("companion.continuity")) }
        Section {
            Picker(L10n.text("companion.bubble_side"), selection: Binding(get: { companion.character(id).bubbleSide }, set: { value in
                companion.updateCharacter(id) { $0.bubbleSide = value }
            })) {
                Text(L10n.text("companion.side_left")).tag(CompanionBubbleSide.left)
                Text(L10n.text("companion.side_right")).tag(CompanionBubbleSide.right)
            }.pickerStyle(.segmented)
            Picker(L10n.text("companion.group"), selection: Binding(get: { companion.group(for: id)?.id.uuidString ?? "" }, set: { value in
                companion.assignGroup(id, to: UUID(uuidString: value))
            })) {
                Text(L10n.text("common.none")).tag("")
                ForEach(companion.settings.groups) { group in Text(group.name).tag(group.id.uuidString) }
            }
            if let group = companion.group(for: id) {
                Text(L10n.text("companion.group_member_help", group.name)).font(.caption).foregroundStyle(.secondary)
                Button(L10n.text("companion.group_adjust")) { companion.beginGroupPlacement(group.id) }
                if companion.groupEditingID == group.id {
                    Button(L10n.text("companion.bubble_done")) { companion.finishGroupPlacement(group.id, save: true) }
                }
            }
            LabeledContent(L10n.text("companion.avatar")) {
                HStack {
                    if let avatar = companion.avatar(id) {
                        Image(nsImage: avatar).resizable().scaledToFill().frame(width: 30, height: 30).clipShape(Circle())
                    }
                    Button(L10n.text("companion.avatar_choose")) { companion.importAvatar(id) }
                    if companion.character(id).avatarFile != nil {
                        Button(L10n.text("companion.avatar_remove")) { companion.removeAvatar(id) }
                    }
                }
            }
            Text(L10n.text("companion.avatar_help")).font(.caption).foregroundStyle(.secondary)
            LabeledContent(L10n.text("companion.bubble_position")) {
                HStack {
                    if companion.bubbleEditingID == id {
                        Button(L10n.text("companion.bubble_done")) { companion.finishBubblePlacement(id, save: true) }.keyboardShortcut(.defaultAction)
                        Button(L10n.text("action.cancel")) { companion.finishBubblePlacement(id, save: false) }
                    } else {
                        Button(L10n.text("companion.bubble_adjust")) { companion.beginBubblePlacement(id) }
                            .disabled(!companion.canPlaceBubble(id))
                    }
                    Button(L10n.text("companion.bubble_reset")) { companion.resetBubblePlacement(id) }
                        .disabled(companion.group(for: id) != nil || companion.character(id).bubbleOffset == nil || companion.bubbleEditingID == id)
                }
            }
            Text(L10n.text(companion.bubbleEditingID == id ? "companion.bubble_dragging" : "companion.bubble_help"))
                .font(.caption).foregroundStyle(companion.bubbleEditingID == id ? Color.accentColor : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: { Text(L10n.text("companion.bubble_section")) }
        Section {
            LabeledContent(L10n.text("companion.state")) { Text(L10n.text("companion.state." + companion.runtimeState)).foregroundStyle(.secondary) }
            Button(action: openGeneral) {
                HStack {
                    Text(L10n.text("settings.general"))
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            Text(L10n.text("companion.shared_settings_help")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } header: { Text(L10n.text("companion.shared_section")) }
    }
}

struct CompanionGeneralSections: View {
    @ObservedObject private var language = LanguageStore.shared
    @ObservedObject var companion: CompanionCoordinator
    func binding<T>(_ key: WritableKeyPath<CompanionSettings, T>) -> Binding<T> {
        Binding(get: { companion.settings[keyPath: key] }, set: { companion.settings[keyPath: key] = $0; companion.changed() })
    }
    func perception<T>(_ key: WritableKeyPath<CompanionPerceptionSettings, T>) -> Binding<T> {
        Binding(get: { companion.settings.perception[keyPath: key] }, set: { companion.settings.perception[keyPath: key] = $0; companion.changed() })
    }
    var body: some View {
        Section {
            LabeledContent(L10n.text("companion.bubble_retention")) {
                HStack(spacing: 6) {
                    TextField("", value: binding(\.bubbleRetentionSeconds), format: .number.precision(.fractionLength(0)))
                        .labelsHidden().frame(width: 60)
                        .accessibilityLabel(L10n.text("companion.bubble_retention"))
                    Text(L10n.text("companion.seconds")).foregroundStyle(.secondary)
                    Stepper("", value: binding(\.bubbleRetentionSeconds), in: 1...300).labelsHidden().fixedSize()
                }
            }
            Text(L10n.text("companion.bubble_retention_help")).font(.caption).foregroundStyle(.secondary)
        } header: { Text(L10n.text("companion.bubble_section")) }
        Section {
            Toggle(L10n.text("companion.enabled"), isOn: binding(\.enabled))
            Toggle(L10n.text("companion.paused"), isOn: binding(\.paused)).disabled(!companion.settings.enabled)
            LabeledContent(L10n.text("companion.state")) {
                Text(L10n.text("companion.state." + companion.runtimeState)).foregroundStyle(.secondary)
            }
            LabeledContent(L10n.text("companion.opencode_service")) {
                let state = companion.openCodeService["state"] as? String ?? "disabled"
                HStack(spacing: 6) {
                    if state == "checking" || state == "starting" { ProgressView().controlSize(.small) }
                    Text(L10n.text("companion.service." + state))
                        .foregroundStyle(state == "failed" ? Color.orange : Color.secondary)
                }
            }
            if let reason = companion.openCodeService["reason"] as? String {
                Text(L10n.text("companion.service." + reason)).font(.caption).foregroundStyle(.orange)
            }
            Text(L10n.text("companion.service_help")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(L10n.text("companion.stop")) { companion.stopTopic() }.disabled(!companion.busy && !companion.hasSpeech)
                Button(L10n.text("companion.history")) { companion.showHistory() }
                if companion.settings.enabled { Button(L10n.text("companion.retry")) { companion.retry() } }
            }
            if let error = companion.error { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
        } header: { Text(L10n.text("companion.section")) } footer: { Text(L10n.text("companion.scope_help")).fixedSize(horizontal: false, vertical: true) }
        Section {
            Picker(L10n.text("perception.mode"), selection: perception(\.mode)) {
                Text(L10n.text("perception.off")).tag(CompanionProactiveMode.off)
                Text(L10n.text("perception.shadow")).tag(CompanionProactiveMode.shadow)
            }
            Toggle(L10n.text("perception.workspace"), isOn: perception(\.workspace))
            Toggle(L10n.text("perception.idle"), isOn: perception(\.idle))
            Toggle(L10n.text("perception.power"), isOn: perception(\.power))
            Toggle(L10n.text("perception.network"), isOn: perception(\.network))
            Toggle(L10n.text("perception.calendar"), isOn: perception(\.calendar))
            Toggle(L10n.text("perception.reminders"), isOn: perception(\.reminders))
            ForEach(["macos.calendar", "macos.reminders"], id: \.self) { source in
                if companion.settings.perception.enabled(source) {
                    Button(L10n.text("perception.authorize", L10n.text("perception." + source))) { companion.authorizePerception(source) }
                }
            }
            Toggle(L10n.text("perception.share_activity"), isOn: perception(\.shareActivity))
            ForEach(CompanionPerceptionSettings.sourceNames, id: \.self) { source in
                if let state = companion.perceptionSources[source]?["state"] as? String {
                    LabeledContent(L10n.text("perception." + source)) { Text(L10n.text("perception.state." + state)).foregroundStyle(.secondary) }
                }
            }
        } header: { Text(L10n.text("perception.section")) } footer: {
            Text(L10n.text("perception.help")).fixedSize(horizontal: false, vertical: true)
        }
        Section {
            LabeledContent(L10n.text("companion.interval")) {
                HStack {
                    Text(companion.settings.intervalMinutes == 0 ? L10n.text("companion.off") : L10n.text("companion.minutes", String(companion.settings.intervalMinutes))).monospacedDigit().foregroundStyle(.secondary)
                    Stepper(L10n.text("companion.interval"), value: binding(\.intervalMinutes), in: 0...1440, step: 1).labelsHidden()
                }
            }
            DatePicker(L10n.text("companion.daily_time"), selection: Binding(get: {
                Calendar.current.date(bySettingHour: companion.settings.dailyConsolidationMinute / 60, minute: companion.settings.dailyConsolidationMinute % 60, second: 0, of: Date()) ?? Date()
            }, set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                companion.settings.dailyConsolidationMinute = (parts.hour ?? 4) * 60 + (parts.minute ?? 0)
                companion.changed()
            }), displayedComponents: .hourAndMinute)
            Text(L10n.text("companion.daily_help")).font(.caption).foregroundStyle(.secondary)
            if let archive = companion.dailyArchives.first {
                let state = archive["status"] as? String ?? "pending"
                LabeledContent(L10n.text("companion.daily_state")) { Text(L10n.text("companion.daily." + state)).foregroundStyle(.secondary) }
                if let error = archive["error"] as? String { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            }
            Stepper(L10n.text("companion.budget", String(companion.settings.hourlyRequests)), value: binding(\.hourlyRequests), in: 1...120)
        } header: { Text(L10n.text("companion.initiative")) } footer: { Text(L10n.text("companion.interval_help")).fixedSize(horizontal: false, vertical: true) }
        Section {
            ForEach(["opencode", "codex", "claude"], id: \.self) { backend in
                CompanionSourceRow(companion: companion, backend: backend)
            }
        } header: { Text(L10n.text("companion.observers")) } footer: { Text(L10n.text("companion.observer_help")).fixedSize(horizontal: false, vertical: true) }
        Section {
            Toggle(L10n.text("companion.web_search"), isOn: binding(\.webSearchEnabled))
        } header: { Text(L10n.text("companion.search_tools")) } footer: {
            Text(L10n.text("companion.web_search_help")).fixedSize(horizontal: false, vertical: true)
        }
        Section {
            LabeledContent(L10n.text("companion.model")) {
                TextField("provider/model", text: binding(\.model)).labelsHidden().frame(maxWidth: 250)
            }
            DisclosureGroup(L10n.text("companion.dependencies")) {
                TextField(L10n.text("companion.claude_node"), text: binding(\.nodePath), prompt: Text(companion.executable("node") ?? L10n.text("companion.not_found")))
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
                Text(L10n.text("companion.all_sessions")).font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 5)
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


struct CompanionStructuredMemoryView: View {
    @ObservedObject var companion: CompanionCoordinator
    let characterID: String
    var loadOnAppear = true
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    private var memories: [[String: Any]] { companion.structuredMemories[characterID] ?? [] }
    private var state: [String: Any] { companion.growthStates[characterID] ?? [:] }
    private func send(_ type: String, job: String? = nil, memory: String? = nil) {
        var command: [String: Any] = ["type": type, "characterId": characterID, "query": query]
        command["jobId"] = job; command["memoryId"] = memory; companion.send(command)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.text("companion.structured_memory")).font(.headline)
                Spacer()
                Button(L10n.text("companion.close_memory")) { dismiss() }
            }
            HStack {
                TextField(L10n.text("companion.search_memory"), text: $query).onSubmit { send("memory_items") }
                Button(L10n.text("companion.refresh")) { send("memory_items") }
                Button(L10n.text("companion.reflect_preview")) { send("reflection_preview") }
            }
            if let error = companion.error { Text(error).foregroundStyle(.orange) }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(memories.indices, id: \.self) { index in
                        let item = memories[index]
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item["content"] as? String ?? "").textSelection(.enabled)
                            Text("\(item["memory_type"] as? String ?? "") · \(item["provenance"] as? String ?? "") · \(item["created_at"] as? String ?? "")").font(.caption).foregroundStyle(.secondary)
                            Text(item["id"] as? String ?? "").font(.caption2).textSelection(.enabled)
                            Text(item["evidence_ids"] as? String ?? "[]").font(.caption2).textSelection(.enabled)
                            Button(L10n.text("companion.forget_item"), role: .destructive) { send("memory_forget", memory: item["id"] as? String) }
                        }
                        Divider()
                    }
                    jobList(state["reflections"] as? [[String: Any]] ?? [], reflection: true)
                    jobList(state["proposals"] as? [[String: Any]] ?? [], reflection: false)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(L10n.text("companion.growth_help")).font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(width: 720, height: 600)
        .onAppear { if loadOnAppear { send("memory_items") } }
    }
    @ViewBuilder private func jobList(_ jobs: [[String: Any]], reflection: Bool) -> some View {
        ForEach(jobs.indices, id: \.self) { index in
            let job = jobs[index], status = job["status"] as? String ?? "", id = job["id"] as? String ?? ""
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.text(reflection ? "companion.reflection" : "companion.growth") + " · " + status).font(.headline)
                Text(job["proposed_content"] as? String ?? job["reason"] as? String ?? "").textSelection(.enabled)
                if !reflection { Text("\(job["field"] as? String ?? ""): \(String(describing: job["old_value"] ?? "")) → \(String(describing: job["new_value"] ?? ""))") }
                Text(job["evidence_ids"] as? String ?? "[]").font(.caption).textSelection(.enabled)
                HStack {
                    if status == "preview" {
                        Button(L10n.text("companion.approve")) { send(reflection ? "reflection_commit" : "growth_commit", job: id) }
                        Button(L10n.text("action.cancel")) { send(reflection ? "reflection_cancel" : "growth_cancel", job: id) }
                    }
                    if !reflection && status == "committed" {
                        Button(L10n.text("companion.rollback")) { send("growth_rollback", job: id) }
                    }
                }
            }
            Divider()
        }
    }
}
