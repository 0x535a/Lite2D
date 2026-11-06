import SwiftUI

struct CompanionGroupsSection: View {
    @ObservedObject var companion: CompanionCoordinator
    @State private var expanded: Set<UUID>
    init(companion: CompanionCoordinator, initiallyExpanded: Set<UUID> = []) {
        self.companion = companion; _expanded = State(initialValue: initiallyExpanded)
    }
    var body: some View {
        Section {
            ForEach(companion.settings.groups) { group in
                DisclosureGroup(group.name.isEmpty ? L10n.text("companion.group") : group.name, isExpanded: Binding(
                    get: { expanded.contains(group.id) },
                    set: { if $0 { expanded.insert(group.id) } else { expanded.remove(group.id) } })) {
                    CompanionGroupEditor(companion: companion, id: group.id)
                }
            }
            Button(L10n.text("companion.group_add"), systemImage: "plus") { expanded.insert(companion.addGroup()) }
            Text(L10n.text("companion.group_help")).font(.caption).foregroundStyle(.secondary)
        } header: { Text(L10n.text("companion.groups")) }
    }
}

private struct CompanionGroupEditor: View {
    @ObservedObject var companion: CompanionCoordinator
    let id: UUID
    @State private var deleting = false
    private var group: CompanionGroupSettings { companion.settings.groups.first { $0.id == id } ?? .init() }
    private var editing: Bool { companion.groupEditingID == id }
    private func binding<T>(_ key: WritableKeyPath<CompanionGroupSettings, T>) -> Binding<T> {
        Binding(get: { group[keyPath: key] }, set: { value in companion.updateGroup(id) { $0[keyPath: key] = value } })
    }
    var body: some View {
        TextField(L10n.text("companion.group_name"), text: binding(\.name))
        HStack {
            number("companion.group_width", \.width)
            number("companion.group_height", \.height)
        }.disabled(editing)
        HStack {
            number("companion.group_x", \.x)
            number("companion.group_y", \.y)
        }.disabled(editing)
        Text(L10n.text("companion.group_coordinates")).font(.caption).foregroundStyle(.secondary)
        HStack {
            if editing {
                Button(L10n.text("companion.bubble_done")) { companion.finishGroupPlacement(id, save: true) }
                Button(L10n.text("action.cancel")) { companion.finishGroupPlacement(id, save: false) }
            } else {
                Button(L10n.text("companion.group_adjust")) { companion.beginGroupPlacement(id) }
            }
            Spacer()
            Button(L10n.text("companion.group_delete"), role: .destructive) { deleting = true }
        }
        .confirmationDialog(L10n.text("companion.group_delete_confirm"), isPresented: $deleting, titleVisibility: .visible) {
            Button(L10n.text("companion.group_delete"), role: .destructive) { companion.deleteGroup(id) }
        }
        if editing { Text(L10n.text("companion.group_adjust_help")).font(.caption).foregroundStyle(.secondary) }
        Text(L10n.text("companion.group_members")).font(.caption).foregroundStyle(.secondary)
        ForEach(companion.manager?.records ?? [], id: \.settings.id) { record in
            Toggle(record.settings.localizedDisplayName, isOn: Binding(
                get: { companion.character(record.settings.id).groupID == id },
                set: { companion.assignGroup(record.settings.id, to: $0 ? id : nil) }))
        }
    }
    private func number(_ key: String, _ path: WritableKeyPath<CompanionGroupSettings, Double>) -> some View {
        LabeledContent(L10n.text(key)) {
            TextField("", value: binding(path), format: .number.precision(.fractionLength(0)))
                .labelsHidden().frame(width: 72).accessibilityLabel(L10n.text(key))
        }
    }
}
