import SwiftUI

struct CompanionGroupSidebar: View {
    @ObservedObject var companion: CompanionCoordinator
    @Binding var selection: String?
    var body: some View {
        Section(L10n.text("companion.groups")) {
            ForEach(companion.settings.groups) { group in
                HStack(spacing: 10) {
                    Image(systemName: "bubble.left.and.bubble.right").font(.title3).frame(width: 22)
                        .foregroundStyle(companion.isGroupDisplayConnected(group.id) ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(group.name.isEmpty ? L10n.text("companion.group") : group.name).lineLimit(1)
                        Text(companion.isGroupDisplayConnected(group.id) ? (group.boundDisplayName ?? L10n.text("display.placeholder")) : L10n.text("companion.group_display_missing"))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }.padding(.vertical, 4).tag(CompanionGroupSelection.tag(group.id))
            }
            Button { selection = CompanionGroupSelection.tag(companion.addGroup()) } label: {
                Label(L10n.text("companion.group_add"), systemImage: "plus").foregroundStyle(.secondary)
            }.buttonStyle(.plain).padding(.vertical, 2)
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
            SettingsPageHeader(symbol: "bubble.left.and.bubble.right", tint: connected ? .accentColor : .orange) {
                TextField(L10n.text("companion.group_name"), text: binding(\.name))
                    .textFieldStyle(.plain).font(.system(size: 22, weight: .semibold))
            } status: {
                Circle().fill(connected ? Color.green : .orange).frame(width: 7, height: 7)
                Text(group.boundDisplayName ?? L10n.text("display.placeholder"))
            }
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
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                        GridRow {
                            number("companion.group_width", \.width)
                            number("companion.group_height", \.height)
                        }
                        GridRow {
                            number("companion.group_x", \.positionX)
                            number("companion.group_y", \.positionY)
                        }
                    }.disabled(editing).padding(.vertical, 4)
                    HStack {
                        if editing {
                            Button(L10n.text("companion.bubble_done")) { companion.finishGroupPlacement(id, save: true) }
                                .buttonStyle(.borderedProminent)
                            Button(L10n.text("action.cancel")) { companion.finishGroupPlacement(id, save: false) }
                        } else {
                            Button(L10n.text("companion.group_adjust"), systemImage: "arrow.up.left.and.arrow.down.right") { companion.beginGroupPlacement(id) }.disabled(!connected)
                        }
                    }
                } header: { Text(L10n.text("companion.group_window")) } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.text("companion.group_coordinates"))
                        Text(L10n.text(connected ? "companion.group_adjust_help" : "companion.group_display_help"))
                    }
                }
                Section {
                    ForEach(companion.manager?.records ?? [], id: \.settings.id) { record in
                        Toggle(isOn: Binding(
                            get: { companion.character(record.settings.id).groupID == id },
                            set: { companion.assignGroup(record.settings.id, to: $0 ? id : nil) })) {
                            Label(record.settings.localizedDisplayName, systemImage: "person.crop.square")
                        }.toggleStyle(.switch)
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
    // Label and field share one grid row so the four values line up as a compact 2x2 block.
    @ViewBuilder private func number(_ key: String, _ path: WritableKeyPath<CompanionGroupSettings, Double>) -> some View {
        Text(L10n.text(key)).foregroundStyle(.secondary).gridColumnAlignment(.leading)
        TextField("", value: binding(path), format: .number.precision(.fractionLength(0)))
            .labelsHidden().textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).monospacedDigit()
            .frame(minWidth: 80, maxWidth: .infinity).accessibilityLabel(L10n.text(key))
    }
}
