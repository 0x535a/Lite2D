import SwiftUI
import AppKit

private func monitorLabel(_ value: String) -> String { CompanionMonitorPresentation.label(value) }

struct CompanionMonitorFrames: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { _, new in new }) }
}
private extension View {
    func monitorFrame(_ key: String) -> some View {
        background(GeometryReader { geometry in
            // Native split columns have separate hosting roots. Use the shared
            // window-global coordinates, not a named space lost at that boundary.
            Color.clear.preference(key: CompanionMonitorFrames.self, value: [key: geometry.frame(in: .global)])
        })
    }
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
    private let layoutID = UUID().uuidString
    init(companion: CompanionCoordinator, loadOnAppear: Bool = true, initialOwner: String = "", initialSection: String = "overview") {
        self.companion = companion; model = companion.monitor; self.loadOnAppear = loadOnAppear
        _navigation = State(initialValue: initialOwner.isEmpty ? initialSection : initialOwner)
        let base = ["views": "L0", "relations": "L4", "traits": "L4", "reflections": "L5", "growth": "L5", "legacy": "role_overview"][initialSection] ?? initialSection
        _rolePage = State(initialValue: initialOwner.isEmpty ? "role_overview" : base)
        _subsection = State(initialValue: base == initialSection ? "" : initialSection)
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
        NavigationSplitView { sidebar } detail: {
            panel.navigationSplitViewColumnWidth(min: 620, ideal: 900)
        }
        .frame(minWidth: 880, minHeight: 600)
        .onAppear {
            model.activeLayoutID = layoutID; model.layoutFrames = [:]
            if loadOnAppear { model.companion = companion; model.activate() }
        }
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
            VStack(alignment: .leading, spacing: 0) {
                header.fixedSize(horizontal: false, vertical: true).monitorFrame("header")
                if !owner.isEmpty { roleNavigation.fixedSize(horizontal: false, vertical: true) }
                if let error = model.error { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled).padding(.horizontal, 24).padding(.bottom, 8) }
                if let result = model.result { Text(monitorLabel(result)).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.bottom, 8) }
                if ["overview", "role_overview"].contains(model.query.section) { overview.frame(maxWidth: .infinity, maxHeight: .infinity) }
                else if model.query.section == "L1" { workingState.frame(maxWidth: .infinity, maxHeight: .infinity) }
                else { browser.frame(maxWidth: .infinity, maxHeight: .infinity).layoutPriority(1) }
            }
            .frame(minWidth: 620, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .monitorFrame("content")
            .coordinateSpace(name: "monitor.content")
            .onPreferenceChange(CompanionMonitorFrames.self) { frames in
                if model.activeLayoutID == layoutID { model.layoutFrames = frames }
            }
    }
    private var header: some View {
        HStack(spacing: 0) {
            SettingsPageHeader(symbol: owner.isEmpty ? "tray.full" : "person.crop.square", autosave: false) {
                Text(owner.isEmpty ? title : roleName).font(.system(size: 22, weight: .semibold)).lineLimit(1).help(owner.isEmpty ? title : roleName)
            } status: {
                Text(model.page.map { L10n.text("monitor.updated", CompanionMonitorPresentation.date($0.at)) } ?? L10n.text("monitor.not_loaded"))
                    .lineLimit(1).textSelection(.enabled)
            }
            ZStack { if model.loading { ProgressView().controlSize(.small) } }.frame(width: 18, height: 18)
            Button(L10n.text("companion.refresh")) { model.refresh() }.disabled(model.loading).padding(.leading, 8).padding(.trailing, 24)
        }
    }
    private var workingState: some View {
        Form {
            if let item = model.page?.items.first {
                Section(L10n.text("monitor.L1")) { fieldGrid(item) }
            } else { Text(L10n.text("monitor.not_loaded")) }
            Section { Text(L10n.text("monitor.working_help")).foregroundStyle(.secondary) }
        }.formStyle(.grouped)
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
        VStack(alignment: .leading, spacing: 10) {
            if model.query.section == "legacy" {
                HStack {
                    Button { rolePage = "role_overview"; subsection = ""; model.navigate(owner: owner, section: "role_overview") } label: { Label(L10n.text("monitor.back_overview"), systemImage: "chevron.left") }
                    Text(L10n.text("monitor.legacy")).foregroundStyle(.secondary)
                }.padding(.vertical, 4)
            } else {
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
            filters.fixedSize(horizontal: false, vertical: true).monitorFrame("filters")
            GeometryReader { available in
            HSplitView {
                VStack(spacing: 0) {
                    if model.page?.items.isEmpty != false {
                        ContentUnavailableView(L10n.text(model.loading && model.page == nil ? "monitor.not_loaded" : "monitor.no_records"), systemImage: "tray").frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List(selection: $selectedKey) {
                            ForEach(model.page?.items ?? [], id: \.key) { item in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(item.title.isEmpty ? monitorLabel(item.status) : itemTitle(item)).lineLimit(2)
                                    let metadata = [name(item.owner), monitorLabel(item.memoryType), monitorLabel(item.source), monitorLabel(item.status)].filter { !$0.isEmpty }.joined(separator: " · ")
                                    if !metadata.isEmpty { Text(metadata).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                                    if !item.at.isEmpty { Text(CompanionMonitorPresentation.date(item.at)).font(.caption2).foregroundStyle(.tertiary) }
                                }.padding(.vertical, 5).tag(item.key).monitorFrame("row:" + item.key)
                            }
                        }.frame(maxWidth: .infinity, maxHeight: .infinity).onChange(of: selectedKey) { _, key in
                            if let item = model.page?.items.first(where: { $0.key == key }), item.key != model.selected?.key { model.select(item) }
                        }
                    }
                    HStack(spacing: 8) {
                        Button { model.query.page = max(0, model.query.page - 1); model.refresh() } label: { Image(systemName: "chevron.left") }
                            .disabled(model.loading || model.query.page == 0)
                        Text(CompanionMonitorPresentation.pagination(page: model.query.page, pageSize: model.query.pageSize, total: model.page?.total ?? 0)).font(.caption).monospacedDigit().lineLimit(1)
                        Button { model.query.page += 1; model.refresh() } label: { Image(systemName: "chevron.right") }
                            .disabled(model.loading || (model.query.page + 1) * model.query.pageSize >= (model.page?.total ?? 0))
                        Spacer()
                    }.padding(12).fixedSize(horizontal: false, vertical: true).monitorFrame("pagination")
                }.frame(minWidth: 280, idealWidth: 340, maxHeight: .infinity).monitorFrame("list_column")
                if let item = model.selected { detail(item).frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity).monitorFrame("detail") }
                else { ContentUnavailableView(L10n.text("monitor.select_item"), systemImage: "sidebar.right").frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity).monitorFrame("detail") }
            }.frame(width: available.size.width, height: available.size.height).monitorFrame("split")
            }.frame(maxWidth: .infinity, maxHeight: .infinity).layoutPriority(1)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    private func itemTitle(_ item: CompanionMonitorItem) -> String {
        if item.kind == "relation" { return roleName + " → " + name(item.title) }
        if ["memory", "public"].contains(item.kind), !item.title.isEmpty { return item.title }
        if ["utterance", "delivery", "error"].contains(item.kind), !item.content.isEmpty { return String(item.content.prefix(120)) }
        return monitorLabel(item.title) + (item.version.isEmpty ? "" : " · " + item.version)
    }
    private var isMemoryList: Bool { ["L2", "L3", "L4", "L5", "legacy"].contains(model.query.section) }
    private var isJobList: Bool { ["reflections", "growth"].contains(model.query.section) }
    private var filters: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !["views", "traits", "relations"].contains(model.query.section) {
                HStack {
                    if model.query.section != "L0" {
                        TextField(L10n.text("companion.search_memory"), text: $model.query.search).onSubmit { model.filterChanged() }
                        Button(L10n.text("monitor.search")) { model.filterChanged() }
                    } else { Spacer() }
                    Picker(L10n.text("monitor.sort"), selection: $model.query.sort) {
                        Text(L10n.text("monitor.newest")).tag("newest"); Text(L10n.text("monitor.oldest")).tag("oldest")
                    }.frame(width: 170).onChange(of: model.query.sort) { _, _ in model.filterChanged() }
                }
            }
            if isMemoryList || isJobList {
                HStack {
                    filterPicker("monitor.status", $model.query.status, isJobList ? ["", "preview", "committed", "cancelled", "rolled_back", "needs_review", "invalidated"] : ["", "active", "superseded", "archived", "needs_review", "deleted"])
                    if isMemoryList {
                        filterPicker("monitor.source", $model.query.source, ["", "experienced", "observed", "told_by_other", "inferred", "world_seed", "legacy_import", "corrected", "character_edit"])
                        filterPicker("monitor.validity", $model.query.validity, ["", "current", "future", "expired"])
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if ["conversation", "audit"].contains(model.query.section) {
                HStack {
                    Picker(L10n.text("role.section"), selection: $model.query.owner) {
                        Text(L10n.text("monitor.all")).tag("")
                        ForEach(roles, id: \.settings.id) { Text($0.settings.localizedDisplayName).tag($0.settings.id.uuidString) }
                    }.onChange(of: model.query.owner) { _, _ in model.filterChanged() }
                    Spacer()
                }
            }
            if isMemoryList || model.query.section == "conversation" {
                DisclosureGroup(L10n.text("monitor.more_filters")) {
                    HStack {
                        TextField(L10n.text("monitor.from"), text: $model.query.from).onSubmit { model.filterChanged() }
                        TextField(L10n.text("monitor.to"), text: $model.query.to).onSubmit { model.filterChanged() }
                        if memoryTypes.count > 2 { filterPicker("monitor.type", $model.query.memoryType, memoryTypes) }
                    }.padding(.top, 6)
                }
            }
        }.textFieldStyle(.roundedBorder).padding(.horizontal, 20).padding(.bottom, 12)
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
                fieldGrid(item)
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
    private func fieldValue(_ field: CompanionMonitorField) -> String {
        guard !field.value.isEmpty else { return L10n.text("monitor.not_provided") }
        if ["occurred_at", "learned_at", "recorded_at", "created_at", "updated_at", "valid_from", "valid_to", "happened_at", "at"].contains(field.key) { return CompanionMonitorPresentation.date(field.value) }
        if field.key == "subjects" { return field.value.components(separatedBy: ", ").map(name).joined(separator: ", ") }
        if ["source_actor_id", "target_character_id", "target", "speaker", "actor", "sender", "recipient", "created_by"].contains(field.key) { return name(field.value) }
        if ["scope", "kind", "validity", "state", "role", "result"].contains(field.key) { return monitorLabel(field.value) }
        return field.value
    }
    private func fieldGrid(_ item: CompanionMonitorItem) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
            ForEach(item.fields.filter { !["raw_hash", "base_hash", "source_ref", "event_id"].contains($0.key) }) { field in
                GridRow {
                    Text(monitorLabel(field.key)).foregroundStyle(.secondary).frame(minWidth: 80, alignment: .leading)
                    Text(fieldValue(field)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
            }
        }.font(.callout)
    }
    private func confirmation(_ plan: CompanionMonitorPlan) -> some View {
        CompanionMonitorConfirmationView(plan: plan, busy: model.busy, error: model.error, cancel: { model.plan = nil }, confirm: { model.commit() })
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

struct CompanionMonitorConfirmationView: View {
    let plan: CompanionMonitorPlan
    var busy = false
    var error: String?
    var expandImpact = false
    @State private var impactExpanded = false
    var cancel: () -> Void
    var confirm: () -> Void
    var reportFrames: (([String: CGRect]) -> Void)?
    private var size: CGSize {
        let available = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1160, height: 780)
        return CGSize(width: min(740, available.width - 80), height: min(650, available.height - 100))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.text("monitor.action." + plan.action.operation)).font(.title2).padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(L10n.text("monitor.impact_help"))
                    Text(L10n.text("monitor.affected") + ": \(plan.affected.count)").font(.headline)
                    if plan.action.kind == "memory", ["archive", "restore", "forget"].contains(plan.action.operation), !plan.before.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L10n.text("monitor.selected_memory")).font(.headline)
                            Text(String(plan.before.prefix(240))).lineLimit(4).textSelection(.enabled)
                        }
                    }
                    if plan.action.operation == "forget" { Text(L10n.text("monitor.forget_help")).foregroundStyle(.orange) }
                    comparison
                    if !plan.affected.isEmpty {
                        DisclosureGroup(isExpanded: $impactExpanded) {
                            ForEach(plan.affected) { Text($0.id).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                        } label: { Text(L10n.text("monitor.evidence")) }
                    }
                    if let error { Text(error).foregroundStyle(.orange) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).monitorFrame("confirmation_scroll")
            Divider()
            HStack {
                Button(L10n.text("action.cancel"), action: cancel).disabled(busy)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button(L10n.text("monitor.confirm"), role: plan.action.operation == "forget" ? .destructive : nil, action: confirm).disabled(busy)
            }.padding(20).fixedSize(horizontal: false, vertical: true).monitorFrame("confirmation_footer")
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .monitorFrame("confirmation").coordinateSpace(name: "monitor.content")
        .onPreferenceChange(CompanionMonitorFrames.self) { reportFrames?($0) }
        .onAppear { impactExpanded = expandImpact }
    }
    private var comparison: some View {
        let values = CompanionMonitorPresentation.previewValues(operation: plan.action.operation, kind: plan.action.kind, before: plan.before, after: plan.after)
        return HStack(alignment: .top, spacing: 16) {
            ScrollView { VStack(alignment: .leading, spacing: 8) { Text(L10n.text("monitor.before")).font(.headline); Text(values.0).textSelection(.enabled) }.frame(maxWidth: .infinity, alignment: .leading) }
            Divider()
            ScrollView { VStack(alignment: .leading, spacing: 8) { Text(L10n.text("monitor.after")).font(.headline); Text(values.1).textSelection(.enabled) }.frame(maxWidth: .infinity, alignment: .leading) }
        }.frame(height: 210)
    }
}
