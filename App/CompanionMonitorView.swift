import SwiftUI
import AppKit

private func monitorLabel(_ value: String) -> String {
    let key = "monitor.value." + value
    let translated = L10n.text(key)
    return translated == key ? value : translated
}

struct CompanionHistoryView: View {
    @ObservedObject var companion: CompanionCoordinator
    @ObservedObject private var language = LanguageStore.shared
    @ObservedObject var model: CompanionMonitorController
    @State private var navigation: String? = "overview"
    @State private var rolePage = "role_overview"
    @State private var subsection = ""
    @State private var selectedKey: String?
    var loadOnAppear = true
    init(companion: CompanionCoordinator, loadOnAppear: Bool = true, initialOwner: String = "", initialSection: String = "overview") {
        self.companion = companion; model = companion.monitor; self.loadOnAppear = loadOnAppear
        _navigation = State(initialValue: initialOwner.isEmpty ? initialSection : initialOwner)
        _rolePage = State(initialValue: initialOwner.isEmpty ? "role_overview" : initialSection)
    }
    private var roles: [ModelRecord] { companion.manager?.records ?? [] }
    private func roleRow(_ record: ModelRecord) -> some View {
        Label(record.settings.localizedDisplayName, systemImage: "person.crop.square").tag(record.settings.id.uuidString)
    }
    private var owner: String { (navigation.flatMap(UUID.init(uuidString:))).map { $0.uuidString } ?? "" }
    private var roleName: String {
        guard let id = UUID(uuidString: owner) else { return L10n.text("companion.history") }
        return companion.manager?.record(id)?.settings.localizedDisplayName ?? owner
    }
    private func name(_ id: String) -> String {
        guard let uuid = UUID(uuidString: id) else { return id }
        return companion.manager?.record(uuid)?.settings.localizedDisplayName ?? id
    }
    private func navigate() {
        subsection = ""; selectedKey = nil
        model.navigate(owner: owner, section: owner.isEmpty ? navigation ?? "overview" : rolePage)
    }
    var body: some View {
        NavigationSplitView { sidebar } detail: { panel }
        .frame(minWidth: 880, minHeight: 600)
        .onAppear { if loadOnAppear { model.companion = companion; model.activate() } }
        .onDisappear { if loadOnAppear { model.deactivate() } }
        .onChange(of: navigation) { _, _ in navigate() }
        .onChange(of: rolePage) { _, _ in if !owner.isEmpty { navigate() } }
        .onReceive(companion.$settings) { _ in validateSelection() }
        .onChange(of: model.page?.at) { _, _ in validateSelection() }
        .onChange(of: model.selected?.key) { _, key in selectedKey = key }
        .sheet(item: $model.plan) { plan in confirmation(plan) }
    }
    private var sidebar: some View {
            List(selection: $navigation) {
                Section(L10n.text("monitor.global")) {
                    Label(L10n.text("monitor.overview"), systemImage: "square.grid.2x2").tag("overview")
                    Label(L10n.text("companion.conversation"), systemImage: "bubble.left.and.bubble.right").tag("conversation")
                    Label(L10n.text("companion.public_memory"), systemImage: "doc.text").tag("public")
                    Label(L10n.text("monitor.audit"), systemImage: "clock.arrow.circlepath").tag("audit")
                }
                Section(L10n.text("role.section")) {
                    ForEach(roles, id: \.settings.id) { record in roleRow(record) }
                }
            }.navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
    }
    private var panel: some View {
            VStack(spacing: 0) {
                SettingsPageHeader(symbol: owner.isEmpty ? "tray.full" : "person.crop.square", autosave: false) {
                    Text(owner.isEmpty ? title : roleName).font(.system(size: 22, weight: .semibold))
                } status: {
                    if model.loading { ProgressView().controlSize(.small) }
                    Text(model.page?.at.replacingOccurrences(of: "T", with: " ") ?? L10n.text("monitor.not_loaded")).textSelection(.enabled)
                    Spacer()
                    Button(L10n.text("companion.refresh")) { model.refresh() }.disabled(model.loading)
                }
                if !owner.isEmpty { roleNavigation }
                if let error = model.error { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled).padding(.horizontal, 24).padding(.bottom, 8) }
                if let result = model.result { Text(monitorLabel(result)).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 24) }
                if ["overview", "role_overview"].contains(model.query.section) { overview }
                else { browser }
            }
    }
    private var title: String {
        switch navigation {
        case "conversation": return L10n.text("companion.conversation")
        case "public": return L10n.text("companion.public_memory")
        case "audit": return L10n.text("monitor.audit")
        default: return L10n.text("monitor.overview")
        }
    }
    private func validateSelection() {
        if let value = navigation, UUID(uuidString: value) != nil,
           !(companion.manager?.records.contains { $0.settings.id.uuidString == value } ?? false) {
            navigation = "overview"
        }
    }
    private var roleNavigation: some View {
        VStack(spacing: 10) {
            Picker(L10n.text("monitor.layers"), selection: $rolePage) {
                Text(L10n.text("monitor.overview")).tag("role_overview")
                ForEach(0..<6) { layer in Text(L10n.text("monitor.L\(layer)")).tag("L\(layer)") }
            }.pickerStyle(.segmented).labelsHidden()
            if rolePage == "L0" {
                subPicker([("L0", "monitor.versions"), ("views", "monitor.persona_views")])
            } else if rolePage == "L4" {
                subPicker([("L4", "monitor.procedural"), ("relations", "monitor.relations"), ("traits", "monitor.traits"), ("growth", "monitor.growth")])
            } else if rolePage == "L5" {
                HStack {
                    subPicker([("L5", "monitor.reflection_memories"), ("reflections", "monitor.reflection_jobs"), ("growth", "monitor.growth")])
                    Button(L10n.text("companion.reflect_preview")) { model.reflect() }.disabled(model.busy)
                }
            }
        }.padding(.horizontal, 24).padding(.bottom, 12)
    }
    private func subPicker(_ values: [(String, String)]) -> some View {
        Picker(L10n.text("monitor.category"), selection: Binding(get: { subsection.isEmpty ? values[0].0 : subsection }, set: {
            subsection = $0; model.navigate(owner: owner, section: $0)
        })) { ForEach(values, id: \.0) { value in Text(L10n.text(value.1)).tag(value.0) } }
        .pickerStyle(.menu).frame(maxWidth: .infinity, alignment: .leading)
    }
    private var overview: some View {
        Form {
            if model.page?.metrics.isEmpty != false {
                ContentUnavailableView(L10n.text("monitor.not_loaded"), systemImage: "tray")
            }
            ForEach((model.page?.metrics ?? []).map(\.owner).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }, id: \.self) { id in
                Section(name(id)) {
                    ForEach((model.page?.metrics ?? []).filter { $0.owner == id }) { metric in
                        LabeledContent(L10n.text("monitor.metric." + metric.key), value: String(metric.count))
                    }
                    if owner.isEmpty { Button(L10n.text("monitor.inspect_role")) { navigation = id } }
                }
            }
            Section {
                Text(L10n.text("monitor.count_help")).foregroundStyle(.secondary)
                if !owner.isEmpty { Button(L10n.text("monitor.legacy")) { model.navigate(owner: owner, section: "legacy") } }
            }
        }.formStyle(.grouped)
    }
    private var browser: some View {
        VStack(spacing: 0) {
            filters
            HSplitView {
                VStack(spacing: 0) {
                    if model.page?.items.isEmpty != false {
                        ContentUnavailableView(L10n.text("companion.empty_memory"), systemImage: "tray").frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List(selection: $selectedKey) {
                            ForEach(model.page?.items ?? [], id: \.key) { item in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(item.title.isEmpty ? monitorLabel(item.status) : itemTitle(item)).lineLimit(2)
                                    Text([name(item.owner), monitorLabel(item.memoryType), monitorLabel(item.source), monitorLabel(item.status)].filter { !$0.isEmpty }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    if !item.at.isEmpty { Text(item.at.replacingOccurrences(of: "T", with: " ")).font(.caption2).foregroundStyle(.tertiary) }
                                }.padding(.vertical, 5).tag(item.key)
                            }
                        }.onChange(of: selectedKey) { _, key in
                            if let item = model.page?.items.first(where: { $0.key == key }), item.key != model.selected?.key { model.select(item) }
                        }
                    }
                    HStack {
                        Button { model.query.page = max(0, model.query.page - 1); model.refresh() } label: { Image(systemName: "chevron.left") }
                            .disabled(model.loading || model.query.page == 0)
                        Text("\(model.query.page + 1) · \(model.page?.total ?? 0)").font(.caption).monospacedDigit()
                        Button { model.query.page += 1; model.refresh() } label: { Image(systemName: "chevron.right") }
                            .disabled(model.loading || (model.query.page + 1) * model.query.pageSize >= (model.page?.total ?? 0))
                        Spacer()
                    }.padding(12)
                }.frame(minWidth: 250, idealWidth: 320)
                if let item = model.selected { detail(item).frame(minWidth: 300, maxWidth: .infinity) }
                else { ContentUnavailableView(L10n.text("monitor.select_item"), systemImage: "sidebar.right").frame(minWidth: 300, maxWidth: .infinity) }
            }
        }
    }
    private func itemTitle(_ item: CompanionMonitorItem) -> String {
        if item.kind == "relation" { return roleName + " → " + name(item.title) }
        if ["memory", "public"].contains(item.kind), !item.title.isEmpty { return item.title }
        return monitorLabel(item.title) + (item.version.isEmpty ? "" : " · " + item.version)
    }
    private var filters: some View {
        VStack(spacing: 8) {
            HStack {
                TextField(L10n.text("companion.search_memory"), text: $model.query.search).onSubmit { model.filterChanged() }
                Button(L10n.text("monitor.search")) { model.filterChanged() }
                Picker(L10n.text("monitor.sort"), selection: $model.query.sort) {
                    Text(L10n.text("monitor.newest")).tag("newest"); Text(L10n.text("monitor.oldest")).tag("oldest")
                }.frame(width: 160).onChange(of: model.query.sort) { _, _ in model.filterChanged() }
            }
            if ["L2", "L3", "L4", "L5", "legacy", "reflections", "growth"].contains(model.query.section) {
                HStack {
                    filterPicker("monitor.status", $model.query.status, ["", "active", "superseded", "archived", "needs_review", "deleted", "preview", "committed", "cancelled", "rolled_back", "invalidated"])
                    if !["reflections", "growth"].contains(model.query.section) {
                    filterPicker("monitor.source", $model.query.source, ["", "experienced", "observed", "told_by_other", "inferred", "world_seed", "legacy_import", "corrected", "character_edit"])
                    filterPicker("monitor.validity", $model.query.validity, ["", "current", "future", "expired"])
                    }
                }
            }
            if ["conversation", "audit"].contains(model.query.section) {
                Picker(L10n.text("role.section"), selection: $model.query.owner) {
                    Text(L10n.text("monitor.all")).tag("")
                    ForEach(companion.manager?.records ?? [], id: \.settings.id) { Text($0.settings.localizedDisplayName).tag($0.settings.id.uuidString) }
                }.onChange(of: model.query.owner) { _, _ in model.filterChanged() }
            }
            HStack {
                if ["L2", "L3", "L4", "L5", "legacy", "conversation"].contains(model.query.section) {
                    TextField(L10n.text("monitor.from"), text: $model.query.from)
                    TextField(L10n.text("monitor.to"), text: $model.query.to)
                    filterPicker("monitor.type", $model.query.memoryType, memoryTypes)
                }
            }
        }.textFieldStyle(.roundedBorder).padding(.horizontal, 16).padding(.bottom, 10)
    }
    private var memoryTypes: [String] {
        switch model.query.section {
        case "L2": return ["", "event"]
        case "L3": return ["", "fact", "belief", "opinion"]
        case "L4": return ["", "skill", "habit", "relation"]
        case "L5": return ["", "reflection"]
        case "legacy": return ["", "diary"]
        default: return ["", "utterance", "delivery", "error", "topic.start", "topic.end"]
        }
    }
    private func filterPicker(_ title: String, _ selection: Binding<String>, _ values: [String]) -> some View {
        Picker(L10n.text(title), selection: selection) {
            ForEach(values, id: \.self) { value in Text(value.isEmpty ? L10n.text("monitor.all") : monitorLabel(value)).tag(value) }
        }.onChange(of: selection.wrappedValue) { _, _ in model.filterChanged() }
    }
    private func detail(_ item: CompanionMonitorItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(itemTitle(item)).font(.title3).fontWeight(.semibold).textSelection(.enabled)
                if item.status == "deleted" || item.status == "unavailable" {
                    Text(L10n.text(item.status == "deleted" ? "monitor.deleted_help" : "monitor.unavailable_help")).foregroundStyle(.secondary)
                } else if !item.content.isEmpty {
                    Text(item.content).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
                if item.kind == "working" { Text(L10n.text("monitor.working_help")).foregroundStyle(.secondary) }
                if item.kind == "audit" { Text(L10n.text("monitor.audit_help")).foregroundStyle(.secondary) }
                if !item.version.isEmpty && item.kind != "public" { LabeledContent(monitorLabel("revision"), value: item.version).textSelection(.enabled) }
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                    ForEach(item.fields.filter { !["raw_hash", "base_hash", "source_ref", "event_id"].contains($0.key) }) { field in
                        GridRow {
                            Text(monitorLabel(field.key)).foregroundStyle(.secondary)
                            Text(field.value.isEmpty ? L10n.text("monitor.not_provided") : (field.key == "subjects" ? field.value.components(separatedBy: ", ").map(name).joined(separator: ", ") : monitorLabel(name(field.value)))).textSelection(.enabled)
                        }
                    }
                }.font(.callout)
                if !item.links.isEmpty {
                    Divider(); Text(L10n.text("monitor.evidence")).font(.headline)
                    ForEach(Array(item.links.enumerated()), id: \.offset) { index, link in
                        Button { model.follow(link) } label: { Label(L10n.text("monitor.open_reference") + " \(index + 1)", systemImage: "link") }.buttonStyle(.link)
                    }
                }
                if !item.actions.isEmpty {
                    Divider()
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 105))], alignment: .leading) {
                        ForEach(item.actions, id: \.self) { action in
                            Button(L10n.text("monitor.action." + action), role: action == "forget" ? .destructive : nil) { model.begin(action) }.disabled(model.busy)
                        }
                    }
                }
                if let operation = model.editingOperation, ["correct", "public_edit"].contains(operation) {
                    Text(L10n.text("monitor.edit_copy")).font(.headline)
                    TextEditor(text: $model.draft).font(.system(.body, design: .monospaced)).frame(minHeight: 160).border(.quaternary)
                    TextField(L10n.text("monitor.reason"), text: $model.reason)
                    Button(L10n.text("monitor.preview")) { model.preview() }.disabled(model.busy || model.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                DisclosureGroup(L10n.text("monitor.technical")) {
                    Text(item.id).textSelection(.enabled)
                    if item.kind == "public" { Text(item.version).textSelection(.enabled) }
                    ForEach(item.fields.filter { ["raw_hash", "base_hash", "source_ref", "event_id"].contains($0.key) }) { field in Text(field.key + ": " + field.value).textSelection(.enabled) }
                }.font(.caption)
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func confirmation(_ plan: CompanionMonitorPlan) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.text("monitor.action." + plan.action.operation)).font(.title2)
            Text(L10n.text("monitor.impact_help"))
            Text(L10n.text("monitor.affected") + ": \(plan.affected.count)").font(.headline)
            if plan.action.operation == "forget" { Text(L10n.text("monitor.forget_help")).foregroundStyle(.orange) }
            if !plan.before.isEmpty || !plan.after.isEmpty {
                HStack(alignment: .top) {
                    ScrollView { VStack(alignment: .leading) { Text(L10n.text("monitor.before")).font(.headline); Text(plan.before).textSelection(.enabled) }.frame(maxWidth: .infinity, alignment: .leading) }
                    Divider()
                    ScrollView { VStack(alignment: .leading) { Text(L10n.text("monitor.after")).font(.headline); Text(plan.after).textSelection(.enabled) }.frame(maxWidth: .infinity, alignment: .leading) }
                }.frame(minHeight: 170, maxHeight: 280)
            }
            if !plan.affected.isEmpty {
                DisclosureGroup(L10n.text("monitor.evidence")) { ForEach(plan.affected) { Text($0.id).font(.caption).textSelection(.enabled) } }
            }
            if let error = model.error { Text(error).foregroundStyle(.orange) }
            HStack {
                Button(L10n.text("action.cancel")) { model.plan = nil }.disabled(model.busy)
                Spacer()
                Button(L10n.text("monitor.confirm"), role: plan.action.operation == "forget" ? .destructive : nil) { model.commit() }.disabled(model.busy)
                if model.busy { ProgressView().controlSize(.small) }
            }
        }.padding(24).frame(width: 720)
    }
    static func makeWindow(coordinator: CompanionCoordinator) -> NSWindow {
        let host = NSHostingController(rootView: CompanionHistoryView(companion: coordinator)); host.sizingOptions = []
        let window = NSWindow(contentViewController: host)
        window.title = L10n.text("companion.history"); window.isReleasedWhenClosed = false
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.contentMinSize = NSSize(width: 920, height: 650); window.setContentSize(NSSize(width: 1160, height: 780)); window.center()
        return window
    }
}
