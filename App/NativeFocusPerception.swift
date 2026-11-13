import AppKit
import AppIntents
import OSLog

struct CompanionFocusResult {
    var quiet: Bool
    var state: String
}

@MainActor final class NativeFocusPerception {
    typealias Provider = () async throws -> CompanionFocusResult
    private let provider: Provider
    private let defaults: UserDefaults
    private let sink: (CompanionMacSignal) -> Void
    private var epochs: [String: Int] = [:]
    private var generation = 0
    private var timer: Timer?
    private var tokens: [NSObjectProtocol] = []
    private var distributedTokens: [NSObjectProtocol] = []
    private var query: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var queryBusy = false
    private var settle: Task<Void, Never>?
    private var pendingRefresh = false
    private var lastExplicit: String?
    private var lastReportedState: String?
    private let logger = Logger(subsystem: "local.lite2d.player", category: "CompanionFocus")
    init(defaults: UserDefaults = UserDefaults(suiteName: "local.lite2d.player") ?? .standard, provider: Provider? = nil, sink: @escaping (CompanionMacSignal) -> Void) {
        self.defaults = defaults; self.sink = sink
        self.provider = provider ?? {
            let filter = try await CompanionQuietFocusFilter.current
            return .init(quiet: filter.quiet, state: "available")
        }
    }
    func configure(epochs: [String: Int]) {
        let selected = epochs.filter { ["macos.focus", "macos.explicit_activity"].contains($0.key) }
        guard self.epochs != selected else { return }
        stop(); self.epochs = selected
        guard !selected.isEmpty else { return }
        let expected = generation
        for name in ["Lite2D.CompanionFocusChanged", "Lite2D.CompanionActivityChanged"] {
            let notification = Notification.Name(name)
            tokens.append(NotificationCenter.default.addObserver(forName: notification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in guard let self, self.generation == expected else { return }; self.changed(name: name) }
            })
            distributedTokens.append(DistributedNotificationCenter.default().addObserver(forName: notification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in guard let self, self.generation == expected else { return }; self.changed(name: name) }
            })
        }
        if let epoch = selected["macos.focus"] { publish(.init(quiet: true, state: "starting"), epoch: epoch) }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        timer?.tolerance = 5
    }
    private func changed(name: String) {
        if name == "Lite2D.CompanionFocusChanged", let epoch = epochs["macos.focus"] {
            publish(.init(quiet: true, state: "starting"), epoch: epoch)
            pendingRefresh = true
            settle?.cancel()
            settle = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 750_000_000) } catch { return }
                guard let self else { return }
                if !self.queryBusy { self.pendingRefresh = false; self.refresh() }
            }
        } else { refresh() }
    }
    private func refresh() {
        CompanionActivityIntent.purgeExpiredInput(defaults: defaults)
        if let epoch = epochs["macos.explicit_activity"], let value = defaults.dictionary(forKey: "CompanionExplicitActivity"),
           let id = value["id"] as? String, UUID(uuidString: id) != nil, id != lastExplicit,
           let raw = value["category"] as? String, let category = CompanionActivityCategory(rawValue: raw),
           let at = value["at"] as? Double, at <= Date().timeIntervalSince1970 + 30, Date().timeIntervalSince1970 - at <= 300 {
            lastExplicit = id
            sink(.init(source: "macos.explicit_activity", type: "activity.explicit", category: category, confidence: 1, subject: "user_chosen_activity", epoch: epoch, sourceAt: Date(timeIntervalSince1970: at)))
        }
        guard let epoch = epochs["macos.focus"], !queryBusy else { return }
        queryBusy = true
        let expected = generation, provider = self.provider
        query = Task { [weak self] in
            let result: CompanionFocusResult
            do { result = try await provider() }
            catch SetFocusFilterIntentError.notFound { result = .init(quiet: false, state: "available") }
            catch { result = .init(quiet: true, state: "temporarily_unavailable") }
            guard let self, !Task.isCancelled, expected == self.generation else { return }
            self.queryBusy = false; self.timeout?.cancel(); self.timeout = nil
            if self.pendingRefresh { self.changed(name: "Lite2D.CompanionFocusChanged"); return }
            self.publish(result, epoch: epoch)
        }
        timeout = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
            guard let self, expected == self.generation, self.queryBusy else { return }
            self.publish(.init(quiet: true, state: "temporarily_unavailable"), epoch: epoch)
            // Keep one in-flight system query; do not pile up queries when the OS service is stalled.
        }
    }
    private func publish(_ result: CompanionFocusResult, epoch: Int) {
        let known = result.state == "available", quiet = result.state != "available" || result.quiet
        let state = known ? (quiet ? "quiet" : "inactive") : "unknown"
        if lastReportedState != state {
            // Only bounded state labels enter diagnostics; no Focus names or configuration IDs.
            logger.notice("Scoped Focus state: \(state, privacy: .public)")
            lastReportedState = state
        }
        sink(.init(source: "macos.focus", type: "focus.filter_state", subject: !known ? "app_filter_unknown" : (quiet ? "app_filter_quiet" : "app_filter_not_active"), health: result.state, epoch: epoch, focusQuiet: quiet))
    }
    func stop() {
        generation += 1; epochs = [:]; query?.cancel(); query = nil; timeout?.cancel(); timeout = nil; queryBusy = false
        timer?.invalidate(); timer = nil; settle?.cancel(); settle = nil; pendingRefresh = false
        lastReportedState = nil
        for token in tokens { NotificationCenter.default.removeObserver(token) }; tokens = []
        for token in distributedTokens { DistributedNotificationCenter.default().removeObserver(token) }; distributedTokens = []
    }
}
