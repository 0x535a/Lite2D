import Foundation
import Combine

final class CompanionMonitorController: ObservableObject {
    weak var companion: CompanionCoordinator?
    @Published var query = CompanionMonitorQuery()
    @Published private(set) var page: CompanionMonitorPage?
    @Published private(set) var loading = false
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    @Published private(set) var result: String?
    @Published var selected: CompanionMonitorItem?
    @Published var plan: CompanionMonitorPlan?
    @Published var draft = ""
    @Published var reason = ""
    @Published var editingOperation: String?
    private var queryID = "", operationID = ""
    private var timer: Timer?
    private(set) var visible = false
    var isPolling: Bool { timer != nil }
    func activate() {
        visible = true
        if timer == nil { timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in if self?.loading == false && self?.busy == false { self?.refresh() } } }
        refresh()
    }
    func deactivate() {
        visible = false; timer?.invalidate(); timer = nil; queryID = ""; operationID = ""; loading = false; busy = false; plan = nil
        page = nil; draft = ""; reason = ""; editingOperation = nil
        if let previous = selected { selected = .init(id: previous.id, kind: previous.kind, owner: previous.owner, title: "") }
    }
    func fail(_ message: String) { error = message; loading = false; busy = false }
    func navigate(owner: String = "", section: String) {
        operationID = UUID().uuidString; busy = false
        query = .init(); query.owner = owner; query.section = section
        page = nil; selected = nil; draft = ""; reason = ""; plan = nil; editingOperation = nil; error = nil; result = nil
        refresh()
    }
    func refresh() {
        guard let companion else { return }
        queryID = UUID().uuidString; loading = true
        var request = query
        request.detailID = selected?.id ?? ""; request.detailKind = selected?.kind ?? ""
        request.detailOwner = selected?.owner ?? query.owner
        companion.send(["type": "monitor_query", "requestID": queryID, "query": (try? CompanionMonitorCoding.object(request)) ?? [:]])
    }
    func filterChanged() { query.page = 0; selected = nil; refresh() }
    func select(_ item: CompanionMonitorItem) { selected = item; editingOperation = nil; plan = nil; draft = ""; reason = "" }
    func follow(_ link: CompanionMonitorLink) {
        draft = ""; reason = ""; editingOperation = nil; plan = nil
        selected = .init(id: link.id, kind: link.kind, owner: selected?.owner ?? query.owner, title: link.id)
        refresh()
    }
    func begin(_ operation: String) {
        guard let item = selected else { return }
        editingOperation = operation; draft = item.content; reason = ""; plan = nil; error = nil
        if !["correct", "public_edit"].contains(operation) { preview() }
    }
    func preview() {
        guard !busy, let item = selected, let operation = editingOperation, let companion else { return }
        busy = true; error = nil; operationID = UUID().uuidString
        let action = CompanionMonitorAction(operation: operation, owner: item.owner, kind: item.kind, target: item.id, content: draft, reason: reason)
        companion.send(["type": "monitor_preview", "requestID": operationID, "action": (try? CompanionMonitorCoding.object(action)) ?? [:]])
    }
    func commit() {
        guard !busy, let plan, let companion else { return }
        busy = true; error = nil; operationID = UUID().uuidString
        companion.send(["type": "monitor_commit", "requestID": operationID, "planID": plan.id])
    }
    func reflect() {
        guard !busy, !query.owner.isEmpty, let companion else { return }
        busy = true; operationID = UUID().uuidString
        companion.send(["type": "monitor_reflect", "requestID": operationID, "characterId": query.owner])
    }
    func invalidate(owner: String = "", purge: Bool = false) {
        guard visible, owner.isEmpty || query.owner.isEmpty || query.owner == owner else { return }
        if purge {
            selected = nil; page = nil; plan = nil; draft = ""; reason = ""; editingOperation = nil
            queryID = ""; loading = false
        }
        if !loading && !busy { refresh() }
    }
    func receive(_ event: CompanionObject) {
        let id = event["requestID"] as? String ?? ""
        switch event["type"] as? String {
        case "monitor.page":
            guard id == queryID else { return }
            do {
                let value = try CompanionMonitorCoding.decode(CompanionMonitorPage.self, event)
                if query.page > 0 && query.page * query.pageSize >= value.total {
                    query.page = max(0, value.total - 1) / query.pageSize; loading = false; refresh(); return
                }
                page = value; loading = false; error = nil
                if let selection = selected {
                    if let updated = value.items.first(where: { $0.key == selection.key }) { selected = updated }
                    else if let detail = value.detail { selected = detail }
                    else { selected = nil }
                    if selected?.status == "deleted" { plan = nil; draft = ""; reason = ""; editingOperation = nil }
                }
            } catch { self.error = error.localizedDescription; loading = false }
        case "monitor.plan":
            guard id == operationID else { return }
            busy = false
            do { plan = try CompanionMonitorCoding.decode(CompanionMonitorPlan.self, NativeCompanionData.object(event["plan"])) }
            catch { self.error = error.localizedDescription }
        case "monitor.outcome":
            guard id == operationID else { return }
            busy = false; plan = nil; editingOperation = nil; draft = ""; reason = ""; selected = nil; page = nil
            result = event["result"] as? String
            refresh()
        case "monitor.error":
            guard id == operationID || id == queryID else { return }
            error = event["message"] as? String
            if id == queryID { loading = false } else { busy = false; plan = nil }
        default: break
        }
    }
}
