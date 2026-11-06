import SwiftUI

struct CompanionGroupSidebar: View {
    @ObservedObject var companion: CompanionCoordinator
    @Binding var selection: String?
    var body: some View {
        Section(L10n.text("companion.groups")) {
            ForEach(companion.settings.groups) { group in
                HStack(spacing: 10) {
                    Image(systemName: "bubble.left.and.bubble.right").font(.title3)
                        .foregroundStyle(companion.isGroupDisplayConnected(group.id) ? Color.accentColor : .orange)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(group.name.isEmpty ? L10n.text("companion.group") : group.name).lineLimit(1)
                        Text(companion.isGroupDisplayConnected(group.id) ? (group.boundDisplayName ?? L10n.text("display.placeholder")) : L10n.text("companion.group_display_missing"))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }.padding(.vertical, 4).tag(CompanionGroupSelection.tag(group.id))
            }
            Button(L10n.text("companion.group_add"), systemImage: "plus") {
                selection = CompanionGroupSelection.tag(companion.addGroup())
            }.buttonStyle(.borderless)
        }
        .onChange(of: companion.settings.groups.map(\.id)) { _, ids in
            if let id = CompanionGroupSelection.id(selection), !ids.contains(id) { selection = "general" }
        }
    }
}

struct CompanionGroupPage: View {
    @ObservedObject var companion: CompanionCoordinator
    let id: UUID
    @State private var deleting = false
    private var group: CompanionGroupSettings { companion.settings.groups.first { $0.id == id } ?? .init() }
    private var editing: Bool { companion.groupEditingID == id }
    private var connected: Bool { companion.isGroupDisplayConnected(id) }
    private func binding<T>(_ key: WritableKeyPath<CompanionGroupSettings, T>) -> Binding<T> {
        Binding(get: { group[keyPath: key] }, set: { value in companion.updateGroup(id) { $0[keyPath: key] = value } })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                TextField(L10n.text("companion.group_name"), text: binding(\.name))
                    .textFieldStyle(.plain).font(.system(size: 25, weight: .semibold))
                HStack(spacing: 6) {
                    Circle().fill(connected ? Color.green : .orange).frame(width: 7, height: 7)
                    Text(group.boundDisplayName ?? L10n.text("display.placeholder"))
                    Spacer()
                    Text(L10n.text("settings.autosave")).font(.caption)
                }.font(.callout).foregroundStyle(.secondary)
            }.padding(24)
            Form {
                Section {
                    Picker(L10n.text("display.assigned"), selection: Binding(get: { group.displayUUID ?? "" }, set: { companion.bindGroup(id, to: $0) })) {
                        if !connected {
                            Text(group.boundDisplayName.map { L10n.text("display.disconnected_name", $0) } ?? L10n.text("display.placeholder")).tag(group.displayUUID ?? "")
                        }
                        ForEach(Array((companion.manager?.displayRegistry.displays ?? []).enumerated()), id: \.element.id) { index, display in
                            Text(L10n.text("format.numbered", display.name, String(index + 1))).tag(display.id)
                        }
                    }
                    HStack {
                        number("companion.group_width", \.width)
                        number("companion.group_height", \.height)
                    }.disabled(editing)
                    HStack {
                        number("companion.group_x", \.positionX)
                        number("companion.group_y", \.positionY)
                    }.disabled(editing)
                    Text(L10n.text("companion.group_coordinates")).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        if editing {
                            Button(L10n.text("companion.bubble_done")) { companion.finishGroupPlacement(id, save: true) }
                            Button(L10n.text("action.cancel")) { companion.finishGroupPlacement(id, save: false) }
                        } else {
                            Button(L10n.text("companion.group_adjust")) { companion.beginGroupPlacement(id) }.disabled(!connected)
                        }
                    }
                    Text(L10n.text(connected ? "companion.group_adjust_help" : "companion.group_display_help"))
                        .font(.caption).foregroundStyle(.secondary)
                } header: { Text(L10n.text("companion.group_window")) }
                Section {
                    ForEach(companion.manager?.records ?? [], id: \.settings.id) { record in
                        Toggle(record.settings.localizedDisplayName, isOn: Binding(
                            get: { companion.character(record.settings.id).groupID == id },
                            set: { companion.assignGroup(record.settings.id, to: $0 ? id : nil) }))
                    }
                } header: { Text(L10n.text("companion.group_members")) }
                Section {
                    Button(L10n.text("companion.group_delete"), role: .destructive) { deleting = true }
                } header: { Text(L10n.text("companion.group_management")) }
            }.formStyle(.grouped)
        }
        .confirmationDialog(L10n.text("companion.group_delete_confirm"), isPresented: $deleting, titleVisibility: .visible) {
            Button(L10n.text("companion.group_delete"), role: .destructive) { companion.deleteGroup(id) }
        }
    }
    private func number(_ key: String, _ path: WritableKeyPath<CompanionGroupSettings, Double>) -> some View {
        LabeledContent(L10n.text(key)) {
            TextField("", value: binding(path), format: .number.precision(.fractionLength(0)))
                .labelsHidden().frame(width: 72).accessibilityLabel(L10n.text(key))
        }
    }
}
