import Foundation
import Darwin

// One Controller owns a data root; offline management must not reset a live runtime.
final class NativeCompanionRootLock {
    private let descriptor: Int32
    init(root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        descriptor = Darwin.open(root.appendingPathComponent("controller.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw NativeCompanionData.error("Cannot open Controller lock") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(descriptor); throw NativeCompanionData.error("A Controller already owns this data root; close Lite2D before offline management") }
    }
    deinit { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
}

private final class NativeCompanionTopic {
    let id = UUID().uuidString
    let source: String?
    let started = NativeCompanionData.now()
    let initiator: String
    var isManual = false
    var opportunity: CompanionOpportunity?
    var decisionId: String?
    var outputIds: [String] = []
    var snapshotExpires: [String: Date] = [:]
    var participants: [String]
    var speaker: String
    var queue: [CompanionObject] = []
    var sentBy = Set<String>()
    var utterances = 0, requests = 0
    var cancelled = false
    var task: Task<Void, Never>?
    var timeout: Task<Void, Never>?
    init(speaker: String, source: String?) { self.speaker = speaker; self.initiator = speaker; self.source = source; participants = [speaker] }
}

actor NativeCompanionRuntime {
    let root: URL
    let promptFile: URL
    let helper: NativeClaudeHelper
    let observers: NativeCompanionObservers
    let opencode: String
    let executable: String
    let emitToHost: (CompanionObject) -> Void
    private let providers: CompanionObject?
    private let injectedRoles: NativeCompanionRoleClient?
    private let manageOpenCodeService: Bool
    private let managePerceptionSensors: Bool
    private let interruptibility: (() -> CompanionInterruptContext)?
    private var serviceMonitor: NativeOpenCodeServiceMonitor?
    private var openCodeService: CompanionObject = ["state": "disabled"]
    private var rootLock: NativeCompanionRootLock?
    private var store: NativeCompanionStore!
    private var prompt: NativeCompanionPrompt!
    private var roles: NativeCompanionRoleClient!
    private var broker: NativeCompanionBroker?
    private var config: CompanionObject = [:]
    private var macPerception: NativeMacPerception?
    private var calendarPerception: NativeCalendarPerception?
    private var notificationPerception: NativeNotificationPerception?
    private var focusPerception: NativeFocusPerception?
    private var directoryPerception: NativeDirectoryPerception?
    private var audioPerception: NativeAudioPerception?
    private var windowPerception: NativeWindowPerception?
    private var audioActive = false
    private var energyConstrained = false
    private var focusQuiet = false
    private var perceptionSettings = CompanionPerceptionSettings()
    private var perceptionStatus: [String: CompanionObject] = [:]
    private var activityContext: CompanionActivityContext?
    private var perceptionIdleSeconds: Double = 0
    private var perceptionSessionAvailable = false
    private var perceptionSleeping = false
    private var lastMacSamples: [String: UInt64] = [:]
    private var perceptionSignatures: [String: (String, Date)] = [:]
    private var perceptionConfiguration = UUID()
    private var perceptionPruneAt = Date.distantPast
    private var initiativeAt = Date.distantPast
    private var lastDecisions: [String: String] = [:]
    private var tokens: [String: String] = [:]
    private var searches: [UUID: Task<String, Error>] = [:]
    private var sessions: [NativeObservedSession] = []
    private var sources: [String: CompanionObject] = [:]
    private var roleErrors: [String: String] = [:]
    private var candidates: [String: CompanionObject] = [:]
    private var topic: NativeCompanionTopic?
    private var timer: Task<Void, Never>?
    private var dailyTask: Task<Void, Never>?
    private var dailyBusy = false
    private var dailyCheckAt = Date.distantPast
    private var pollAt = Date.distantPast
    private var polling = false
    private var nextIdle = Double.infinity
    private var lastTopic: Double = 0
    private var stopped = false
    private var ready = false
    private var sourceRevision: [String: Int] = [:]
    init(root: URL, promptFile: URL, opencode: String, codex: String, node: String, helperScript: URL, executable: String,
         idleSeconds: Double = 60, claudeRoot: URL? = nil, providers: CompanionObject? = nil,
         roles: NativeCompanionRoleClient? = nil, manageOpenCodeService: Bool = true, managePerceptionSensors: Bool = true,
         interruptibility: (() -> CompanionInterruptContext)? = nil, emit: @escaping (CompanionObject) -> Void) {
        self.root = root; self.promptFile = promptFile; self.opencode = opencode; self.executable = executable; self.providers = providers; injectedRoles = roles; emitToHost = emit
        self.manageOpenCodeService = manageOpenCodeService
        self.managePerceptionSensors = managePerceptionSensors; self.interruptibility = interruptibility
        var env = ProcessInfo.processInfo.environment
        if let claudeRoot { env["CLAUDE_CONFIG_DIR"] = claudeRoot.path }
        helper = NativeClaudeHelper(node: node, script: helperScript, idleSeconds: idleSeconds, environment: env)
        observers = NativeCompanionObservers(codex: codex, helper: helper, claudeRoot: claudeRoot)
    }
    func start(automatic: Bool = true) async throws {
        guard !stopped else { throw CancellationError() }
        rootLock = try NativeCompanionRootLock(root: root)
        store = try NativeCompanionStore(root: root); prompt = try NativeCompanionPrompt.load(promptFile)
        try store.exportNotes(); lastTopic = store.get("lastTopic") as? Double ?? 0
        let broker = NativeCompanionBroker { [weak self] token, request in
            guard let self else { throw NativeCompanionData.error("Companion stopped") }
            return try await self.tool(token: token, name: request["name"] as? String ?? "", args: NativeCompanionData.object(request["arguments"]))
        }
        self.broker = broker
        let endpoint = try await broker.start()
        guard !stopped else { broker.close(); throw CancellationError() }
        roles = injectedRoles ?? NativeCompanionRoles(root: root, store: store, prompt: prompt, promptFile: promptFile,
            executable: opencode, helper: executable, toolEndpoint: endpoint, providers: providers, register: { [weak self] id in await self?.register(id) ?? "" })
        await roles.reapStale()
        if manageOpenCodeService {
            serviceMonitor = NativeOpenCodeServiceMonitor(executable: opencode) { [weak self] state in await self?.serviceChanged(state) }
        }
        ready = true
        emit("ready", ["history": (try? store.history()) ?? []])
        if automatic {
            timer = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                    guard let self else { return }; await self.tick()
                }
            }
        }
    }
    private func register(_ id: String) -> String {
        tokens = tokens.filter { $0.value != id }
        let token = UUID().uuidString + UUID().uuidString; tokens[token] = id; return token
    }
    private func emit(_ type: String, _ payload: CompanionObject = [:]) {
        guard !stopped else { return }
        if ["utterance", "error", "record.changed", "topic.start", "topic.end", "conversation.focus"].contains(type), let event = try? store?.event(type, payload) { emitToHost(event) }
        else { var event = payload; event["type"] = type; event["protocolVersion"] = 1; event["createdAt"] = NativeCompanionData.iso(); emitToHost(event) }
    }
    private var enabled: Bool { config["enabled"] as? Bool == true }
    private var paused: Bool { config["paused"] as? Bool == true }
    private var interval: Double { max(0, min(1440, config["intervalMinutes"] as? Double ?? 30)) }
    private var hourly: Int { max(1, min(120, config["hourlyRequests"] as? Int ?? 12)) }
    private var model: String { config["model"] as? String ?? "" }
    private var characters: [CompanionObject] { NativeCompanionData.array(config["characters"]).filter { NativeCompanionData.validID($0["id"] as? String ?? "") } }
    private var visible: [CompanionObject] { characters.filter { $0["enabled"] as? Bool == true && $0["visible"] as? Bool == true } }
    private func sourceEnabled(_ backend: String) -> Bool { enabled && NativeCompanionData.object(NativeCompanionData.object(config["sources"])[backend])["enabled"] as? Bool == true }
    private func status() {
        emit("status", ["perception": perceptionStatus, "sources": sources, "openCodeService": openCodeService, "busy": topic != nil || dailyBusy, "roleErrors": roleErrors,
            "dailyArchives": (try? store.rows("SELECT owner,status,end_at,error FROM daily_archives ORDER BY end_at DESC LIMIT 20")) ?? [],
            "nextIdle": nextIdle.isFinite ? nextIdle : NSNull()])
    }
    private func serviceChanged(_ state: CompanionObject) {
        guard !stopped else { return }
        let wasRunning = openCodeService["state"] as? String == "running"
        openCodeService = state
        if !wasRunning && state["state"] as? String == "running" { pollAt = .distantPast }
        status()
    }
    func configure(_ next: CompanionObject) async {
        let previousInterval = interval, previousEnabled = enabled, previousPaused = paused
        let old = Dictionary(uniqueKeysWithValues: NativeCompanionData.backends.map { ($0, sourceEnabled($0)) })
        config = next
        await configurePerception()
        dailyCheckAt = .distantPast
        if !enabled || next["sleeping"] as? Bool == true { dailyTask?.cancel() }
        if next["webSearchEnabled"] as? Bool == false {
            for task in searches.values { task.cancel() }
            searches.removeAll()
        }
        await serviceMonitor?.setEnabled(enabled)
        if interval != previousInterval || (!previousEnabled && enabled) || (previousPaused && !paused) { scheduleIdle() }
        for backend in NativeCompanionData.backends where old[backend] != sourceEnabled(backend) {
            sourceRevision[backend, default: 0] += 1
            await observers.reset(backend); sessions.removeAll { $0.backend == backend }; candidates = candidates.filter { $0.value["backend"] as? String != backend }
            if !sourceEnabled(backend) { await observers.disable(backend) }
            if backend == "claude" {
                do { try await observers.setClaudeEnabled(sourceEnabled(backend)) }
                catch { sources[backend] = ["state": "unavailable", "message": NativeCompanionData.clean(error.localizedDescription, limit: 180)] }
            }
            pollAt = .distantPast
        }
        if let opportunity = topic?.opportunity, (try? store.opportunityAuthorized(opportunity, forExpression: true)) != true { stop(reason: "source_revoked", cancelArchive: false) }
        if topic?.opportunity != nil && perceptionSettings.mode != .live { stop(reason: "initiative_mode_changed", cancelArchive: false) }
        if !enabled || paused || topic?.participants.contains(where: { id in !visible.contains(where: { $0["id"] as? String == id }) }) == true || topic?.source.map({ !sourceEnabled($0) }) == true { stop(cancelArchive: false) }
        status()
    }
    private func configurePerception() async {
        let requestID = UUID(); perceptionConfiguration = requestID
        let object = NativeCompanionData.object(config["perception"])
        var settings = (try? CompanionProactiveCoding.decode(CompanionPerceptionSettings.self, NativeCompanionData.string(object))) ?? .init()
        if !enabled { settings.mode = .off; settings.focus = false }
        let wasFocusEnabled = perceptionSettings.focus
        perceptionSettings = settings
        if settings.focus && !wasFocusEnabled { focusQuiet = true }
        var epochs: [String: Int] = [:]
        for source in CompanionPerceptionSettings.sourceNames {
            var policy = CompanionPerceptionPolicy()
            policy.allowedCharacterIds = characters.filter { $0["enabled"] as? Bool == true }.compactMap { $0["id"] as? String }
            policy.allowedUses = [.attention, .audit]
            if settings.shareActivity && ["macos.workspace", "macos.idle", "macos.explicit_activity", "macos.window"].contains(source) {
                policy.allowedUses.append(.activityContext); policy.remoteInferenceAllowed = true
            }
            if settings.shareSchedule && ["macos.calendar", "macos.reminders"].contains(source) {
                policy.allowedUses.append(.expression); policy.remoteInferenceAllowed = true
            }
            if source == "macos.focus" { policy.allowedCharacterIds = [] }
            if source == "macos.window" { policy.resourceScopeRevision = NativeCompanionData.hash(settings.windowAllowlist.joined(separator: ",")) }
            if source == "macos.files" {
                policy.allowedCharacterIds = []; policy.allowedUses = [.audit]
                policy.resourceScopeRevision = NativeCompanionData.hash((try? CompanionProactiveCoding.encode(settings.directories)) ?? "")
            }
            if source == NativeNotificationPerception.source {
                policy.allowedCharacterIds = []; policy.allowedUses = [.audit]
                policy.remoteInferenceAllowed = false; policy.memoryAllowed = false
                policy.resourceScopeRevision = CompanionNotificationDatabase.scopeRevision(apps: settings.notificationAllowlist, content: settings.notificationContent)
            }
            if let effective = try? store.setPerceptionConsent(source: source, enabled: settings.enabled(source), policy: policy) {
                if settings.enabled(source) { epochs[source] = effective.consentEpoch }
                if perceptionStatus[source]?["consentEpoch"] as? Int != effective.consentEpoch || !settings.enabled(source) {
                    perceptionStatus[source] = ["state": settings.enabled(source) ? "starting" : "disabled", "consentEpoch": effective.consentEpoch]
                }
            }
        }
        if settings.mode == .off || !settings.shareActivity { activityContext = nil }
        if !settings.idle { perceptionIdleSeconds = 0 }
        if settings.mode == .off { perceptionSessionAvailable = false }
        if !settings.focus { focusQuiet = false }
        if !settings.audio { audioActive = false }
        if !settings.power { energyConstrained = false }
        guard managePerceptionSensors else { return }
        if macPerception == nil {
            macPerception = await MainActor.run { NativeMacPerception { [weak self] signal in Task { await self?.receiveMacSignal(signal) } } }
        }
        guard requestID == perceptionConfiguration, !stopped, let sensor = macPerception else { return }
        let sleeping = config["sleeping"] as? Bool == true
        await sensor.configure(settings, epochs: epochs, suspended: sleeping)
        if calendarPerception == nil {
            calendarPerception = await MainActor.run { NativeCalendarPerception { [weak self] signal in Task { await self?.receiveCalendarSignal(signal) } } }
        }
        guard requestID == perceptionConfiguration, !stopped else { return }
        await calendarPerception?.configure(epochs: epochs, sleeping: sleeping || perceptionSleeping)
        if notificationPerception == nil {
            notificationPerception = NativeNotificationPerception(store: store) { [weak self] signal in Task { await self?.receiveNotificationSignal(signal) } }
        }
        guard requestID == perceptionConfiguration, !stopped else { return }
        await notificationPerception?.configure(epoch: epochs[NativeNotificationPerception.source], apps: settings.notificationAllowlist, contentAllowed: settings.notificationContent, sleeping: sleeping || perceptionSleeping)
        if focusPerception == nil { focusPerception = await MainActor.run { NativeFocusPerception { [weak self] signal in Task { await self?.receiveMacSignal(signal) } } } }
        guard requestID == perceptionConfiguration, !stopped else { return }
        await focusPerception?.configure(epochs: epochs)
        if directoryPerception == nil { directoryPerception = NativeDirectoryPerception(ownDataRoot: root) { [weak self] signal in Task { await self?.receiveMacSignal(signal) } } }
        guard requestID == perceptionConfiguration, !stopped else { return }
        await directoryPerception?.configure(epoch: epochs["macos.files"], directories: settings.directories, sleeping: sleeping || perceptionSleeping)
        if audioPerception == nil { audioPerception = await MainActor.run { NativeAudioPerception { [weak self] signal in Task { await self?.receiveMacSignal(signal) } } } }
        guard requestID == perceptionConfiguration, !stopped else { return }
        await audioPerception?.configure(epoch: epochs["macos.audio"], sleeping: sleeping || perceptionSleeping)
        if windowPerception == nil { windowPerception = await MainActor.run { NativeWindowPerception { [weak self] signal in Task { await self?.receiveMacSignal(signal) } } } }
        guard requestID == perceptionConfiguration, !stopped else { return }
        await windowPerception?.configure(epoch: epochs["macos.window"], apps: settings.windowAllowlist, sleeping: sleeping || perceptionSleeping)
    }
    private func syncOptionalPerceptionPause() async {
        guard managePerceptionSensors, !stopped else { return }
        let request = perceptionConfiguration
        var epochs: [String: Int] = [:]
        for source in CompanionPerceptionSettings.sourceNames where perceptionSettings.enabled(source) {
            epochs[source] = try? store.perceptionPolicy(source)?.consentEpoch
        }
        let paused = perceptionSleeping || config["sleeping"] as? Bool == true
        await calendarPerception?.configure(epochs: epochs, sleeping: paused)
        guard request == perceptionConfiguration, !stopped else { return }
        await notificationPerception?.configure(epoch: epochs[NativeNotificationPerception.source], apps: perceptionSettings.notificationAllowlist,
            contentAllowed: perceptionSettings.notificationContent, sleeping: paused)
        guard request == perceptionConfiguration, !stopped else { return }
        await directoryPerception?.configure(epoch: epochs["macos.files"], directories: perceptionSettings.directories, sleeping: paused)
        guard request == perceptionConfiguration, !stopped else { return }
        await audioPerception?.configure(epoch: epochs["macos.audio"], sleeping: paused)
        guard request == perceptionConfiguration, !stopped else { return }
        await windowPerception?.configure(epoch: epochs["macos.window"], apps: perceptionSettings.windowAllowlist, sleeping: paused)
    }
    private func receiveNotificationSignal(_ signal: CompanionNotificationSignal) {
        let source = NativeNotificationPerception.source
        guard !stopped, ready, enabled, perceptionSettings.enabled(source),
              let policy = try? store.perceptionPolicy(source), policy.consentEpoch == signal.epoch else { return }
        perceptionStatus[source] = ["state": signal.state, "consentEpoch": signal.epoch, "checkedAt": NativeCompanionData.iso(),
            "baseline": signal.baseline, "observed": signal.observed, "duplicates": signal.duplicates,
            "restricted": signal.restricted, "malformed": signal.malformed, "gaps": signal.gaps]
        status()
    }
    private func receiveCalendarSignal(_ signal: CompanionCalendarSignal) {
        guard !stopped, ready, enabled, perceptionSettings.enabled(signal.source),
              let policy = try? store.perceptionPolicy(signal.source), policy.consentEpoch == signal.epoch else { return }
        perceptionStatus[signal.source] = ["state": signal.health, "consentEpoch": signal.epoch, "checkedAt": NativeCompanionData.iso()]
        guard signal.health == "available", let occurrence = signal.occurrenceId, let phase = signal.phase else {
            if signal.health != "available" { try? store.invalidatePerceptionSource(signal.source) }
            status(); return
        }
        let now = Date()
        var event = CompanionObservation(id: occurrence + ":" + phase, source: signal.source, type: "schedule." + phase, observedAt: now, subject: "scheduled_arrangement", expiresAt: now.addingTimeInterval(120))
        event.policy = policy
        do {
            if let eventID = try store.ingestPerception(event, now: now) {
                for character in visible.prefix(8) {
                    let owner = character["id"] as! String
                    let opportunity = CompanionOpportunity(ownerCharacterId: owner, kind: "schedule." + phase, sourceEventIds: [eventID], topicKey: "schedule:" + occurrence,
                        priority: 0.85, intrusionCost: 0.2, notBefore: now, expiresAt: now.addingTimeInterval(120))
                    _ = try store.saveOpportunity(opportunity, now: now)
                    var gates = CompanionInterruptContext()
                    gates.manualPause = paused; gates.sleeping = perceptionSleeping; gates.sessionAvailable = perceptionSessionAvailable
                    gates.outputBusy = topic != nil || dailyBusy; gates.idleSeconds = perceptionIdleSeconds
                    gates.cooldown = NativeCompanionData.now() - lastTopic < 180000; gates.budgetAvailable = (try store.requestCount()) < hourly
                    try store.recordDecision(CompanionArbiter.decide(opportunity, context: gates, mode: perceptionSettings.mode, at: now))
                }
            }
        } catch { perceptionStatus[signal.source] = ["state": "error", "reason": "event_rejected"] }
        status()
    }
    private func receiveMacSignal(_ signal: CompanionMacSignal) {
        guard !stopped, ready, enabled, perceptionSettings.enabled(signal.source),
              let granted = try? store.perceptionPolicy(signal.source), granted.consentEpoch == signal.epoch else { return }
        guard signal.sampledUptime > (lastMacSamples[signal.source] ?? 0) else { return }
        lastMacSamples[signal.source] = signal.sampledUptime
        let now = Date()
        perceptionStatus[signal.source] = ["state": signal.health, "checkedAt": NativeCompanionData.iso(now), "consentEpoch": signal.epoch]
        if let quiet = signal.focusQuiet {
            focusQuiet = quiet
            if quiet, topic?.isManual == false { stop(reason: "focus_quiet", cancelArchive: false) }
        }
        if let active = signal.audioActive { audioActive = active }
        if let constrained = signal.energyConstrained { energyConstrained = constrained }
        if let seconds = signal.idleSeconds { perceptionIdleSeconds = seconds }
        if let available = signal.sessionAvailable { perceptionSessionAvailable = available }
        if let sleeping = signal.sleeping, sleeping != perceptionSleeping {
            perceptionSleeping = sleeping
            Task { [weak self] in await self?.syncOptionalPerceptionPause() }
        }
        if signal.source == "macos.idle", signal.subject == "active", activityContext?.category == .idle { activityContext = nil }
        if signal.source == "macos.window", signal.category == .unknown, activityContext?.source == "macos.window" { activityContext = nil }
        if let category = signal.category, granted.allowedUses.contains(.activityContext), !(signal.source == "macos.window" && category == .unknown) {
            let preserveWindow = signal.source == "macos.workspace" && perceptionSettings.window && activityContext?.source == "macos.window" && (activityContext?.confidence ?? 0) >= 0.65 && activityContext?.contextScope == signal.contextScope && (activityContext?.expiresAt ?? .distantPast) > now
            let explicitActive = activityContext?.source == "macos.explicit_activity" && (activityContext?.expiresAt ?? .distantPast) > now
            if (!explicitActive || signal.source == "macos.explicit_activity") && !preserveWindow {
                let expiry = min(now.addingTimeInterval(300), (signal.sourceAt ?? now).addingTimeInterval(300))
                activityContext = CompanionActivityContext(category: category, confidence: signal.confidence, observedAt: now, expiresAt: expiry, source: signal.source, consentEpoch: signal.epoch, contextScope: signal.contextScope)
            }
        }
        let signature = signal.type + ":" + signal.subject + ":" + (signal.category?.rawValue ?? "")
        if let previous = perceptionSignatures[signal.source], previous.0 == signature && now.timeIntervalSince(previous.1) < 240 {
            status(); return
        }
        perceptionSignatures[signal.source] = (signature, now)
        let revision = (store.get("perceptionRevision:" + signal.source) as? Int ?? 0) + 1
        try? store.set("perceptionRevision:" + signal.source, revision)
        var event = CompanionObservation(id: signal.source + ":current", source: signal.source, type: signal.type, observedAt: now, sourceAt: signal.sourceAt, subject: signal.subject, expiresAt: now.addingTimeInterval(300))
        event.revision = revision; event.policy = granted; event.confidence = signal.confidence; event.activityCategory = signal.category
        do {
            guard let eventID = try store.ingestPerception(event, now: now) else { return }
            // Initial snapshots establish context; they never count as a fresh expression opportunity.
            if !signal.initial, signal.type == "activity.idle_changed", signal.subject == "active" {
                for character in visible.prefix(8) {
                    let owner = character["id"] as! String
                    guard let intention = try store.intentions(owner: owner).first(where: { !$0.state.terminal && $0.state != .needsReview && $0.expiresAt > now }) else { continue }
                    let opportunity = CompanionOpportunity(ownerCharacterId: owner, kind: "return_to_activity", sourceEventIds: [eventID], relatedIntentionIds: [intention.id], topicKey: intention.topicKey,
                        priority: intention.priority, intrusionCost: 0.25, notBefore: now, expiresAt: now.addingTimeInterval(120))
                    _ = try store.saveOpportunity(opportunity, now: now)
                    var gates = CompanionInterruptContext()
                    gates.enabled = enabled; gates.manualPause = paused; gates.sleeping = perceptionSleeping; gates.sessionAvailable = perceptionSessionAvailable
                    gates.outputBusy = topic != nil || dailyBusy; gates.idleSeconds = perceptionIdleSeconds
                    gates.cooldown = NativeCompanionData.now() - lastTopic < 180000
                    gates.budgetAvailable = (try store.requestCount()) < hourly
                    try store.recordDecision(CompanionArbiter.decide(opportunity, context: gates, mode: perceptionSettings.mode, at: now))
                }
            }
        } catch { perceptionStatus[signal.source] = ["state": "error", "reason": "event_rejected"] }
        status()
    }
    private func scheduleIdle() { nextIdle = interval > 0 ? NativeCompanionData.now() + interval * 60000 : .infinity }
    func tick() async {
        guard ready, !stopped, enabled else { return }
        if Date() >= perceptionPruneAt {
            try? store.pruneProactive(); perceptionPruneAt = Date().addingTimeInterval(60)
        }
        if dailyBusy { return }
        if topic == nil, Date() >= dailyCheckAt, config["sleeping"] as? Bool != true {
            dailyCheckAt = Date().addingTimeInterval(15)
            dailyBusy = true
            dailyTask = Task { [weak self] in await self?.runDaily() }
            await dailyTask?.value
        }
        guard !stopped, enabled, !dailyBusy else { return }
        if Date() >= pollAt && !polling {
            polling = true; pollAt = Date().addingTimeInterval(15)
            let own = Set(((try? store.rows("SELECT value FROM state WHERE key LIKE 'session:%' OR key LIKE 'dailyTaskSession:%' OR key LIKE 'dailyRotation:%'")) ?? []).compactMap { row -> String? in
                (row["value"] as? String)?.data(using: .utf8).flatMap { try? NativeCompanionData.decode($0) } as? String
            })
            // The observers are independent. A failed source never disables others.
            for backend in NativeCompanionData.backends {
                guard !stopped else { break }
                guard sourceEnabled(backend) else { sources[backend] = ["state": "disabled"]; continue }
                if backend == "claude", paused || (visible.isEmpty && sources[backend] != nil) || ((try? store.requestCount()) ?? 0) >= hourly { continue }
                let revision = sourceRevision[backend, default: 0]
                do {
                    if backend == "opencode", let serviceMonitor { _ = try await serviceMonitor.ensureRunning() }
                    let result = try await observers.pollMetadata(backend, excluded: own)
                    guard !stopped, sourceEnabled(backend), sourceRevision[backend, default: 0] == revision else { continue }
                    sessions.removeAll { $0.backend == backend }; sessions += result.sessions
                    sources[backend] = ["state": "available", "count": result.sessions.count, "checkedAt": NativeCompanionData.now()]
                    for var activity in result.changes {
                        activity["candidateAt"] = NativeCompanionData.now(); candidates[activity["sessionRef"] as? String ?? ""] = activity
                    }
                } catch {
                    guard !stopped, sourceEnabled(backend), sourceRevision[backend, default: 0] == revision else { continue }
                    sources[backend] = ["state": "unavailable", "message": NativeCompanionData.clean(error.localizedDescription, limit: 180), "checkedAt": NativeCompanionData.now()]
                }
            }
            polling = false; status()
        }
        if perceptionSettings.mode != .off {
            candidates = [:]
            evaluateInitiative(); return
        }
        let now = NativeCompanionData.now()
        candidates = candidates.filter { now - ($0.value["candidateAt"] as? Double ?? 0) <= 120000 }
        guard !stopped, !paused, !focusQuiet, topic == nil, !visible.isEmpty, now - lastTopic >= (config["cooldownSeconds"] as? Double ?? 180) * 1000 else { return }
        if let candidate = candidates.values.first(where: { now - ($0["candidateAt"] as? Double ?? now) >= 10000 }) {
            candidates.removeValue(forKey: candidate["sessionRef"] as? String ?? "")
            startTopic(reason: "work_activity", evidence: candidate, source: candidate["backend"] as? String)
        } else if now >= nextIdle { scheduleIdle(); startTopic(reason: "idle_opportunity") }
    }
    private func initiativeGates() -> CompanionInterruptContext {
        var value = CompanionInterruptContext()
        value.enabled = enabled; value.manualPause = paused; value.sleeping = perceptionSleeping || config["sleeping"] as? Bool == true
        value.sessionAvailable = interruptibility?().sessionAvailable ?? perceptionSessionAvailable
        value.outputBusy = topic != nil || dailyBusy || config["presentationBusy"] as? Bool == true
        value.idleSeconds = interruptibility?().idleSeconds ?? perceptionIdleSeconds
        value.focusQuiet = focusQuiet || (interruptibility?().focusQuiet ?? false)
        value.audioActive = audioActive; value.energyConstrained = energyConstrained
        value.cooldown = NativeCompanionData.now() - lastTopic < (config["cooldownSeconds"] as? Double ?? 180) * 1000
        value.budgetAvailable = ((try? store.requestCount()) ?? hourly) < hourly
        return value
    }
    private func evaluateInitiative() {
        let now = Date()
        guard now >= initiativeAt else { return }; initiativeAt = now.addingTimeInterval(5)
        let owners = visible.compactMap { $0["id"] as? String }
        do {
            try store.pruneProactive(now: now)
            for owner in owners {
                try store.syncOpenLoopIntentions(owner: owner, now: now)
                for goal in try store.intentions(owner: owner) where [.pending, .deferred, .ready].contains(goal.state) && goal.attemptCount < goal.maxAttempts && goal.expiresAt > now && (goal.notBefore ?? .distantPast) <= now && (goal.cooldownUntil ?? .distantPast) <= now {
                    let value = CompanionOpportunity(ownerCharacterId: owner, kind: "conversation_follow_up", sourceEventIds: [], relatedIntentionIds: [goal.id], topicKey: "intention:" + goal.id,
                        priority: goal.priority, intrusionCost: 0.25, notBefore: now, expiresAt: min(goal.expiresAt, now.addingTimeInterval(300)))
                    _ = try store.saveOpportunity(value, now: now)
                }
            }
            if NativeCompanionData.now() >= nextIdle {
                scheduleIdle()
                for owner in owners {
                    let value = CompanionOpportunity(ownerCharacterId: owner, kind: "intrinsic_interest", sourceEventIds: [], topicKey: "intrinsic:\(Int(now.timeIntervalSince1970 / 300))",
                        priority: 0.5, intrusionCost: 0.3, notBefore: now, expiresAt: now.addingTimeInterval(120))
                    _ = try store.saveOpportunity(value, now: now)
                }
            }
            let options = try store.opportunities(owners: owners, now: now).sorted { lhs, rhs in
                if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
                let l = store.get("lastInitiative:" + lhs.ownerCharacterId) as? Double ?? 0
                let r = store.get("lastInitiative:" + rhs.ownerCharacterId) as? Double ?? 0
                return l == r ? lhs.id < rhs.id : l < r
            }
            let gates = initiativeGates()
            for opportunity in options {
                var decision = CompanionArbiter.decide(opportunity, context: gates, mode: perceptionSettings.mode, at: now)
                if decision.action == "admit", !(try store.opportunityAuthorized(opportunity, now: now, forExpression: true)) {
                    decision.action = "defer"; decision.reasonCodes.append("source_not_shareable"); decision.selectedModality = .silent
                }
                let signature = decision.action + decision.reasonCodes.joined(separator: ",") + ":" + String(Int(now.timeIntervalSince1970 / 60))
                if lastDecisions[opportunity.id] != signature { try store.recordDecision(decision); lastDecisions[opportunity.id] = signature }
                if decision.action == "admit", perceptionSettings.mode == .live, topic == nil, try store.claimOpportunity(opportunity, now: now) {
                    try store.set("lastInitiative:" + opportunity.ownerCharacterId, now.timeIntervalSince1970)
                    startTopic(reason: "initiative", characterID: opportunity.ownerCharacterId, opportunity: opportunity, decisionID: decision.id)
                    break
                }
            }
            if lastDecisions.count > 1024 { lastDecisions = [:] }
        } catch { emit("error", ["message": "Initiative state could not be evaluated."]) }
    }
    private func startTopic(reason: String, evidence: CompanionObject? = nil, source: String? = nil, characterID: String? = nil, opportunity: CompanionOpportunity? = nil, decisionID: String? = nil) {
        guard !stopped, enabled, !paused, topic == nil, !dailyBusy, (!focusQuiet || reason == "manual_test") else { return }
        var choices = visible
        if let characterID { choices = choices.filter { $0["id"] as? String == characterID } }
        guard !choices.isEmpty else { return }
        if let reference = evidence?["sessionRef"] as? String {
            let watching = choices.filter { (store.get("watches:\($0["id"] as? String ?? "")") as? [String] ?? []).contains(reference) }; if !watching.isEmpty { choices = watching }
        }
        let index = (store.get("speakerIndex") as? Int ?? 0) % choices.count
        try? store.set("speakerIndex", index + 1)
        let character = choices[index], id = character["id"] as! String
        let topic = NativeCompanionTopic(speaker: id, source: source)
        topic.isManual = reason == "manual_test"
        topic.opportunity = opportunity; topic.decisionId = decisionID
        if let opportunity {
            do {
                for intentionID in opportunity.relatedIntentionIds {
                    if let value = try store.intentions(owner: id).first(where: { $0.id == intentionID }), value.state != .ready {
                        try store.transitionIntention(intentionID, owner: id, to: .ready, reason: "opportunity_admitted")
                    }
                    try store.transitionIntention(intentionID, owner: id, to: .executing, reason: "generation_started")
                }
            } catch { return }
        }
        self.topic = topic
        lastTopic = NativeCompanionData.now(); try? store.set("lastTopic", lastTopic)
        emit("topic.start", ["topicId": topic.id, "reason": reason]); status()
        topic.timeout = Task { [weak self, weak topic] in
            do { try await Task.sleep(nanoseconds: 90_000_000_000) } catch { return }
            await self?.expire(topic?.id)
        }
        topic.task = Task { [weak self] in await self?.runTopic(topic, reason: reason, evidence: evidence) }
    }
    private func expire(_ id: String?) { if topic?.id == id { stop(reason: "timeout") } }
    private func runTopic(_ topic: NativeCompanionTopic, reason: String, evidence: CompanionObject?) async {
        do {
            var input: CompanionObject = ["reason": reason]
            if evidence != nil { input["observation"] = ["activityCategory": "unknown", "confidence": 0.3, "evidenceType": "agent_history_metadata"] }
            try await turn(id: topic.speaker, input: input, topic: topic)
            while !topic.queue.isEmpty && !topic.cancelled && topic.utterances < 4 {
                let envelope = topic.queue.removeFirst(); let recipient = envelope["to"] as? String ?? ""
                guard visible.contains(where: { $0["id"] as? String == recipient }) else { continue }
                if !topic.participants.contains(recipient) { topic.participants.append(recipient) }
                focus(topic, from: envelope["from"] as? String ?? "", to: recipient)
                try await turn(id: recipient, input: ["reason": "character_message", "from": envelope["from"] ?? "", "message": envelope["text"] ?? ""], topic: topic, envelope: envelope)
            }
        } catch {
            if !topic.cancelled && !stopped { roleErrors[topic.speaker] = NativeCompanionData.clean(error.localizedDescription, limit: 240); emit("error", ["characterId": topic.speaker, "message": NativeCompanionData.clean(error.localizedDescription, limit: 240)]) }
        }
        topic.timeout?.cancel()
        if let opportunity = topic.opportunity, topic.outputIds.isEmpty {
            for id in opportunity.relatedIntentionIds {
                if (try? store.intentions(owner: topic.initiator).contains(where: { $0.id == id && $0.state == .executing })) == true {
                    try? store.transitionIntention(id, owner: topic.initiator, to: .deferred, reason: "no_expression")
                }
            }
        }
        try? store.execute("UPDATE deliveries SET status='cancelled' WHERE topic=? AND status='queued'", [topic.id])
        try? store.execute("UPDATE deliveries SET status='delivery_unknown' WHERE topic=? AND status='delivering'", [topic.id])
        try? store.settleUndeliveredSocialOutputs(topic.id)
        if !topic.cancelled { emit("topic.end", ["topicId": topic.id, "reason": "completed"]) }
        if self.topic === topic { self.topic = nil }; status(); try? store.exportNotes()
    }
    private func reserveRequest() throws -> Bool { try store.spend(hourly) }
    private func turn(id: String, input: CompanionObject, topic: NativeCompanionTopic, envelope: CompanionObject? = nil) async throws {
        try Task.checkCancellation()
        guard !topic.cancelled, topic.requests < 6, topic.utterances < 4, try reserveRequest() else { return }
        topic.requests += 1; topic.speaker = id
        if let envelope { try store.execute("UPDATE deliveries SET status='delivering' WHERE id=?", [envelope["id"]]) }
        var context = input; context["topicId"] = topic.id; context["quotedEvidence"] = true; context["intent"] = prompt.turnIntent
        context["currentTime"] = NativeCompanionData.currentTime()
        if let activity = activityContext, let policy = try? store.perceptionPolicy(activity.source),
           policy.consentEpoch == activity.consentEpoch, policy.permits(id, use: .activityContext, remote: true) {
            context["activity"] = activity.roleProjection(at: Date())
        }
        if input["reason"] as? String == "manual_test" { context["manualTest"] = prompt.manualTest }
        try store.syncOpenLoopIntentions(owner: id)
        let social = try store.recentRoleDialogue(owner: id)
        let pendingIntentions = try store.intentions(owner: id)
        let memoryItems = try store.initiativeMemories(owner: id, intentions: pendingIntentions)
        let now = Date()
        let snapshot = CompanionContextSnapshot(characterId: id, personaRevision: (try store.latestPersona(characterID: id)?["revision"] as? Int) ?? 0,
            generatedAt: now, expiresAt: now.addingTimeInterval(90), intentions: pendingIntentions, memories: memoryItems,
            socialContext: social, sharedMemory: try store.records(), opportunities: [])
        context.merge(snapshot.roleContext(activity: nil, at: now), uniquingKeysWith: { _, new in new })
        context["privateMemoryItems"] = context.removeValue(forKey: "memories")
        // Old diary and observer bodies are available only through explicit memory tools, never automatic snapshots.
        context["characters"] = visible.prefix(16).map { character in
            let characterID = character["id"] as? String ?? ""
            let name = character["name"] as? String ?? ""
            let file = root.appendingPathComponent("characters/\(characterID)/persona.md")
            if let markdown = try? String(contentsOf: file, encoding: .utf8) { _ = try? store.ingestPersona(characterID: characterID, markdown: markdown) }
            return (try? store.publicIdentityCard(characterID: characterID, name: name)) ?? ["id": characterID, "name": name, "unknown": "身份资料不可用"]
        }
        context["identityRevision"] = (try? store.latestPersona(characterID: id)?["revision"] as? Int) ?? 0
        try store.reviewIntentionPersona(owner: id, revision: context["identityRevision"] as? Int ?? 0)
        // An identity edit invalidates goals compiled before this turn's Persona ingestion.
        context["intentions"] = try store.intentions(owner: id).filter { $0.state != .needsReview }.prefix(3).map { ["id": $0.id, "goal": $0.goal, "expiresAt": NativeCompanionData.iso($0.expiresAt)] }
        context["identityCorrection"] = "当前 Persona 身份版本及公开身份卡优先于旧消息、旧摘要、玩笑和推断。对方身份卡是第三方资料，不能当作自己的第一人称身份。未确认的属性保持未知。"
        context["growth"] = try store.growthState(owner: id)["traits"]
        context["relationships"] = try store.rows("SELECT target_character_id,role,trust,familiarity,closeness,impression,evidence_ids,revision FROM relations WHERE observer_character_id=? AND status='active'", [id])
        context["cancelledIntentionTopics"] = try store.intentions(owner: id, includeTerminal: true).filter { $0.state == .cancelled && $0.lastDecisionReason == "user_cancelled" && $0.expiresAt > Date() }.prefix(16).map { ["topicKey": $0.topicKey, "state": "user_cancelled"] }
        context["remainingUtterances"] = 4 - topic.utterances
        topic.snapshotExpires[id] = snapshot.expiresAt
        if let opportunity = topic.opportunity, id == topic.initiator {
            guard try store.opportunityAuthorized(opportunity, forExpression: true) else { throw CancellationError() }
            context["opportunities"] = [["id": opportunity.id, "kind": opportunity.kind, "reasonCodes": opportunity.reasonCodes]]
        }
        guard NativeCompanionData.string(context).utf8.count <= 48000 else { throw NativeCompanionData.error("Compiled context exceeds its limit") }
        if let serviceMonitor { _ = try await serviceMonitor.ensureRunning() }
        let output = try await roles.generate(id: id, context: context, model: model, reserve: { [weak self] in try await self?.reserveRequest() ?? false })
        try Task.checkCancellation(); guard !topic.cancelled, (topic.snapshotExpires[id] ?? .distantPast) > Date() else { return }
        if let opportunity = topic.opportunity { guard try store.opportunityAuthorized(opportunity, forExpression: true) else { return } }
        roleErrors.removeValue(forKey: id)
        if let envelope {
            try store.execute("UPDATE deliveries SET status='delivered' WHERE id=?", [envelope["id"]])
            try store.finishSocialDelivery(envelope["id"] as? String ?? "")
            try store.execute("INSERT OR IGNORE INTO daily_receipts VALUES (?,?)", [envelope["id"], NativeCompanionData.iso()])
            _ = try store.recordDirectMemory(owner: id, source: "told_by_other", eventID: envelope["id"] as? String ?? "", content: "收到角色消息：" + (envelope["text"] as? String ?? ""), sourceActorID: envelope["from"] as? String)
        }
        if topic.sentBy.remove(id) != nil { return }
        let parsed = NativeCompanionData.output(output)
        guard parsed["skip"] as? Bool != true, let text = parsed["text"] as? String, !text.isEmpty else {
            if input["reason"] as? String == "manual_test" { emit("test.result", ["characterId": id, "result": "skipped"]) }; return
        }
        var extra: CompanionObject = ["emotion": parsed["emotion"] ?? "neutral"]; extra["to"] = envelope?["from"]
        say(id: id, text: text, topic: topic, extra: extra)
        if let sender = envelope?["from"] as? String, visible.contains(where: { $0["id"] as? String == sender }) {
            let message = UUID().uuidString; try delivery(message, topic: topic, from: id, to: sender, text: text, status: "delivering")
            do {
                let remote = try await roles.receive(id: sender, from: id, text: text, messageID: message, model: model)
                try store.execute("UPDATE deliveries SET status='accepted_pending_context',remote_id=? WHERE id=?", [remote, message])
            } catch { try store.execute("UPDATE deliveries SET status='delivery_unknown' WHERE id=?", [message]) }
        }
    }
    private func focus(_ topic: NativeCompanionTopic, from: String, to: String) { emit("conversation.focus", ["topicId": topic.id, "speakerId": from, "listenerId": to, "validUntil": NativeCompanionData.iso(Date(timeIntervalSince1970: (topic.started + 90000) / 1000))]) }
    private func delivery(_ id: String, topic: NativeCompanionTopic, from: String, to: String, text: String, status: String) throws {
        try store.execute("INSERT INTO deliveries VALUES (?,?,?,?,?,?,?,?)", [id, topic.id, from, to, text, status, nil, NativeCompanionData.iso()])
    }
    private func say(id: String, text: String, topic: NativeCompanionTopic, extra: CompanionObject = [:]) {
        guard !topic.cancelled, topic.utterances < 4, visible.contains(where: { $0["id"] as? String == id }) else { return }
        let cleaned = NativeCompanionData.clean(text, limit: 300)
        var related: [String] = []
        if id == topic.initiator, let opportunity = topic.opportunity {
            related = opportunity.relatedIntentionIds.filter { target in
                guard let value = try? store.intentions(owner: id).first(where: { $0.id == target && $0.state == .executing }) else { return false }
                return value.targetCharacterId == (extra["to"] as? String)
            }
        }
        let receipt = CompanionOutputReceipt(characterId: id, topicId: topic.id, modality: extra["deliveryId"] == nil ? .bubble : .socialMessage,
            text: cleaned, relatedIntentionIds: related, decisionId: topic.decisionId, deliveryId: extra["deliveryId"] as? String)
        do {
            try store.saveOutputCandidate(receipt)
            if let opportunity = topic.opportunity { try store.proactiveDependency(kind: "output", id: receipt.id, sourceKind: "opportunity", sourceID: opportunity.id) }
            try store.acknowledgeOutput(receipt.id, owner: id, status: .admitted)
            try store.acknowledgeOutput(receipt.id, owner: id, status: .queued)
        } catch { return }
        topic.outputIds.append(receipt.id); topic.utterances += 1
        var event = extra; event["initiativeOutput"] = topic.opportunity != nil
        if let opportunity = topic.opportunity {
            event["perceptionSources"] = opportunity.sourceEventIds.compactMap { (try? store.rows("SELECT source FROM perception_events WHERE id=?", [$0]).first?["source"]) as? String }
        }
        event["expiresAt"] = NativeCompanionData.iso(min(topic.opportunity?.expiresAt ?? .distantFuture, Date().addingTimeInterval(120)))
        event["outputId"] = receipt.id; event["characterId"] = id; event["name"] = characters.first { $0["id"] as? String == id }?["name"]
        event["text"] = cleaned; event["topicId"] = topic.id; emit("utterance", event)
    }
    func tool(token: String, name: String, args: CompanionObject) async throws -> Any {
        guard let actor = tokens[token], enabled, !paused, characters.contains(where: { $0["id"] as? String == actor && $0["enabled"] as? Bool == true }) else { throw NativeCompanionData.error("Character is paused or unauthenticated") }
        if let topic {
            guard (topic.snapshotExpires[actor] ?? Date().addingTimeInterval(1)) > Date() else { throw NativeCompanionData.error("Context snapshot expired") }
            if let opportunity = topic.opportunity { guard try store.opportunityAuthorized(opportunity, forExpression: true) else { throw NativeCompanionData.error("Opportunity authorization changed") } }
        }
        try await roles.reserveContinuation(actor)
        guard !stopped, enabled, !paused, characters.contains(where: { $0["id"] as? String == actor && $0["enabled"] as? Bool == true }) else { throw NativeCompanionData.error("Character access revoked") }
        if ["private_memory_update", "public_record_update", "memory_write", "memory_correct", "memory_forget", "growth_propose", "intention_propose", "intention_cancel", "intention_resume"].contains(name) {
            guard let topic, !topic.cancelled, topic.speaker == actor else { throw NativeCompanionData.error("No active write context") }
        }
        switch name {
        case "web_search":
            guard config["webSearchEnabled"] as? Bool != false else { throw NativeCompanionData.error("Web search is disabled by the user") }
            let id = UUID()
            let task = Task { try await NativeCompanionSearch.search(query: args["query"] as? String ?? "", objective: args["objective"] as? String ?? "") }
            searches[id] = task
            defer { searches.removeValue(forKey: id) }
            let text = try await task.value
            guard !stopped, enabled, !paused, config["webSearchEnabled"] as? Bool != false,
                  tokens[token] == actor, characters.contains(where: { $0["id"] as? String == actor && $0["enabled"] as? Bool == true }) else { throw NativeCompanionData.error("Search access revoked") }
            return ["source": "Exa web search", "untrustedContent": text]
        case "companion_list_characters": return visible.filter { $0["id"] as? String != actor }.map { ["id": $0["id"] ?? "", "name": $0["name"] ?? ""] }
        case "observer_list_sessions": return sessions.filter { sourceEnabled($0.backend) }.prefix(24).map(\.roleObject)
        case "observer_get_recent_work": return sessions.filter { sourceEnabled($0.backend) }.prefix(8).map(\.roleObject)
        case "observer_watch_session", "observer_unwatch_session":
            guard let reference = args["sessionRef"] as? String, let session = sessions.first(where: { $0.roleReference == reference }), sourceEnabled(session.backend) else { throw NativeCompanionData.error("Session not authorized") }
            var watched = (store.get("watches:\(actor)") as? [String] ?? []).filter { $0 != reference }
            if name == "observer_watch_session" { watched.append(reference) }; try store.set("watches:\(actor)", Array(watched.suffix(24))); return ["watching": name == "observer_watch_session"]
        case "observer_get_activity", "observer_get_session_summary":
            guard let reference = args["sessionRef"] as? String, let session = sessions.first(where: { $0.roleReference == reference }), sourceEnabled(session.backend) else { throw NativeCompanionData.error("Activity not authorized or unavailable") }
            return session.roleObject
        case "public_record_list": return try store.records().map { ["path": $0["path"] ?? "", "revision": $0["revision"] ?? ""] }
        case "public_record_read": return try store.readRecord(args["path"] as? String ?? "")
        case "public_record_update":
            let result = try store.updateRecord(actor: actor, name: args["path"] as? String ?? "", content: NativeCompanionData.clean(args["content"] as? String ?? "", limit: 32768), revision: args["expectedRevision"] as? String)
            if result["conflict"] as? Bool != true { try store.exportNotes(); emit("record.changed", ["characterId": actor, "path": args["path"] ?? "", "revision": result["revision"] ?? ""]) }; return result
        case "private_memory_read": return ["content": store.get("memory:\(actor)") as? String ?? "", "provenance": "unclassified_diary", "identityAuthority": false]
        case "private_memory_update":
            guard let content = args["content"] as? String, content.utf8.count <= 32768 else { throw NativeCompanionData.error("Memory exceeds 32 KB") }
            let cleaned = NativeCompanionData.clean(content, limit: 32768)
            try store.set("memory:\(actor)", cleaned)
            _ = try? store.memoryWrite(owner: actor, type: "diary", provenance: "character_edit", content: cleaned)
            try store.exportNotes(); return ["updated": true]
        case "memory_search":
            let query = args["query"] as? String ?? ""
            let types = (args["types"] as? String ?? "").split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let limit = Int(args["limit"] as? String ?? "20") ?? 20
            return ["memories": try store.memorySearch(owner: actor, query: query, types: types, limit: limit)]
        case "memory_read":
            guard let memoryID = args["memoryId"] as? String, let memory = try store.memoryRead(memoryID, owner: actor) else { throw NativeCompanionData.error("Memory not found or not accessible") }
            return memory
        case "memory_write":
            guard let type = args["type"] as? String, let content = args["content"] as? String else { throw NativeCompanionData.error("Memory type and content are required") }
            let evidence = (args["evidenceIds"] as? String ?? "").split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let source = args["source"] as? String ?? "inferred"
            let allowed = ["experienced", "observed", "told_by_other", "inferred"]
            guard allowed.contains(source) else { throw NativeCompanionData.error("Unsupported memory provenance") }
            guard ["event", "fact", "belief", "opinion", "skill", "habit", "reflection", "relation"].contains(type) else { throw NativeCompanionData.error("Unsupported memory type") }
            if source != "inferred" { _ = try store.verifiedEvidence(owner: actor, ids: evidence) }
            // The model's interpretation remains inferred; direct sources are Controller-recorded events.
            let result = try store.memoryWrite(owner: actor, type: type, provenance: "inferred", content: content, evidenceIDs: evidence)
            emit("monitor.invalidate", ["owner": actor]); return result
        case "memory_correct":
            guard let memoryID = args["memoryId"] as? String, let content = args["newContent"] as? String,
                  let expected = Int(args["expectedRevision"] as? String ?? "") else { throw NativeCompanionData.error("Memory correction requires ID, content and revision") }
            let result = try store.memoryCorrect(memoryID, owner: actor, content: content, expectedRevision: expected, reason: args["reason"] as? String ?? "user correction")
            if result["conflict"] as? Bool != true { try store.exportNotes(); emit("monitor.invalidate", ["owner": actor]) }
            return result
        case "memory_forget":
            guard let memoryID = args["memoryId"] as? String else { throw NativeCompanionData.error("Memory ID is required") }
            let forgotten = try store.forgetMemory(memoryID, owner: actor)
            if forgotten {
                try store.exportNotes(); try store.set("sessionPolicy:\(actor)", "memory-invalidated")
                stop(reason: "memory_forgotten")
                emit("monitor.invalidate", ["owner": actor, "purge": true])
            }
            return ["forgotten": forgotten]
        case "growth_propose":
            let evidence = (args["evidenceIds"] as? String ?? "").split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            guard let value = Double(args["value"] as? String ?? "") else { throw NativeCompanionData.error("Growth value must be numeric") }
            return try store.previewGrowth(owner: actor, target: (args["targetCharacterId"] as? String).flatMap { $0.isEmpty ? nil : $0 }, field: args["field"] as? String ?? "", value: value, evidence: evidence, reason: args["reason"] as? String ?? "")
        case "relation_get":
            guard let target = args["targetCharacterId"] as? String, NativeCompanionData.validID(target), target != actor,
                  characters.contains(where: { $0["id"] as? String == target && $0["enabled"] as? Bool == true }) else { throw NativeCompanionData.error("Relationship target is unavailable") }
            return try store.relationGet(observer: actor, target: target) ?? ["observerCharacterId": actor, "targetCharacterId": target, "status": "unknown", "message": "No relationship has been recorded."]
        case "intention_list":
            return ["intentions": try store.intentions(owner: actor).prefix(16).map { try CompanionProactiveCoding.object($0) }]
        case "intention_cancel", "intention_resume":
            guard let id = args["intentionId"] as? String else { throw NativeCompanionData.error("Intention ID required") }
            if name == "intention_resume" {
                guard let value = try store.intentions(owner: actor).first(where: { $0.id == id && $0.state == .needsReview }) else { throw NativeCompanionData.error("Intention is not awaiting review") }
                _ = value
                try store.resumeIntention(id, owner: actor)
            } else { try store.transitionIntention(id, owner: actor, to: .cancelled, reason: "character_review") }
            return ["updated": true]
        case "intention_propose":
            guard let goal = args["goal"] as? String, let topicKey = args["topicKey"] as? String else { throw NativeCompanionData.error("Intention goal and topic key required") }
            let evidence = (args["evidenceIds"] as? String ?? "").split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let target = (args["targetCharacterId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            if let target { guard visible.contains(where: { $0["id"] as? String == target }) else { throw NativeCompanionData.error("Target unavailable") } }
            let parser = ISO8601DateFormatter(), now = Date()
            let date: (String) throws -> Date? = { key in
                guard let raw = args[key] as? String, !raw.isEmpty else { return nil }
                guard let value = parser.date(from: raw) else { throw NativeCompanionData.error("Invalid intention time") }; return value
            }
            let memory = (args["sourceMemoryId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let value = CompanionIntention(ownerCharacterId: actor, targetCharacterId: target, goal: goal, origin: .conversationMemory,
                topicKey: topicKey, sourceMemoryId: memory, evidenceIds: evidence, priority: min(0.8, max(0.1, Double(args["priorityHint"] as? String ?? "0.5") ?? 0.5)),
                notBefore: try date("notBefore"), expiresAt: try date("expiresAt") ?? now.addingTimeInterval(7 * 86400), createdBy: "character_proposal", createdAt: now, updatedAt: now)
            let id = try store.proposeIntention(value)
            emit("monitor.invalidate", ["owner": actor])
            return ["intentionId": id, "state": "pending"]
        case "companion_send_message":
            guard let topic, !topic.cancelled, topic.speaker == actor, let to = args["to"] as? String, to != actor, visible.contains(where: { $0["id"] as? String == to }) else { throw NativeCompanionData.error("No available recipient or topic") }
            guard let raw = args["text"] as? String, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, raw.count <= 300, topic.utterances + topic.queue.count < 4 else { throw NativeCompanionData.error("Message or topic limit exceeded") }
            let text = NativeCompanionData.clean(raw, limit: 300), id = UUID().uuidString
            try delivery(id, topic: topic, from: actor, to: to, text: text, status: "queued")
            if !topic.participants.contains(to) { topic.participants.append(to) }; focus(topic, from: actor, to: to)
            topic.sentBy.insert(actor); say(id: actor, text: text, topic: topic, extra: ["to": to, "deliveryId": id]); topic.queue.append(["id": id, "from": actor, "to": to, "text": text]); return ["messageId": id, "status": "queued"]
        default: throw NativeCompanionData.error("Tool denied")
        }
    }
    func stop(reason: String = "cancelled", cancelArchive: Bool = true) {
        if cancelArchive { dailyTask?.cancel() }
        for task in searches.values { task.cancel() }
        searches.removeAll()
        candidates = [:]; scheduleIdle()
        if let topic, !topic.cancelled {
            topic.cancelled = true; topic.task?.cancel(); topic.timeout?.cancel()
            try? store.cancelTopicOutputs(topic.id, reason: reason)
            emit("topic.end", ["topicId": topic.id, "reason": reason]); Task { await roles?.interrupt() }
        }
    }
    func command(_ command: CompanionObject) async {
        guard ready && !stopped else { return }
        do {
            switch command["type"] as? String {
            case "monitor_query":
                let query = try CompanionMonitorCoding.decode(CompanionMonitorQuery.self, NativeCompanionData.object(command["query"]))
                var page = try store.monitorPage(query, requestID: command["requestID"] as? String ?? "", owners: characters.compactMap { $0["id"] as? String })
                if query.section == "L1" {
                    var state = CompanionMonitorItem(id: "working", kind: "working", owner: query.owner, title: "working")
                    state.fields = [
                        .init(key: "session", value: store.get("session:\(query.owner)") as? String ?? ""),
                        .init(key: "state", value: paused ? "paused" : (!enabled ? "disabled" : "running")),
                        .init(key: "topic", value: topic?.participants.contains(query.owner) == true ? topic?.id ?? "" : ""),
                        .init(key: "speaker", value: topic?.speaker == query.owner ? query.owner : "")]
                    page.items = [state]; page.total = 1
                }
                emit("monitor.page", try CompanionMonitorCoding.object(page))
            case "monitor_preview":
                let action = try CompanionMonitorCoding.decode(CompanionMonitorAction.self, NativeCompanionData.object(command["action"]))
                let plan = try store.monitorPreview(action)
                emit("monitor.plan", ["requestID": command["requestID"] ?? "", "plan": try CompanionMonitorCoding.object(plan)])
            case "monitor_commit":
                let planID = command["planID"] as? String ?? ""
                let intentionAction = try store.monitorPlanAction(planID)?.kind == "intention"
                if !intentionAction { stop(reason: "memory_management"); await roles.interrupt() }
                let action = try store.monitorCommit(planID)
                if intentionAction, topic?.opportunity?.relatedIntentionIds.contains(action.target) == true { stop(reason: "intention_management", cancelArchive: false) }
                if !intentionAction && !action.owner.isEmpty { await roles.forget(action.owner) }
                try store.exportNotes()
                emit("monitor.outcome", try CompanionMonitorCoding.object(CompanionMonitorOutcome(requestID: command["requestID"] as? String ?? "", operation: action.operation, owner: action.owner, target: action.target, result: "completed")))
            case "monitor_reflect":
                guard let id = command["characterId"] as? String, NativeCompanionData.validID(id) else { throw NativeCompanionData.error("Invalid character") }
                let jobs = try store.reflectionPreview(owner: id)
                try store.audit(owner: id, operation: "user.reflection_preview", target: jobs.first?["id"] as? String ?? id, actor: "user", result: jobs.isEmpty ? "insufficient_evidence" : "completed")
                emit("monitor.outcome", try CompanionMonitorCoding.object(CompanionMonitorOutcome(requestID: command["requestID"] as? String ?? "", operation: "reflect", owner: id, target: "", result: jobs.isEmpty ? "insufficient_evidence" : "completed")))
            case "output_receipt":
                guard let id = command["outputId"] as? String, let owner = command["characterId"] as? String,
                      let raw = command["status"] as? String, let state = CompanionOutputStatus(rawValue: raw),
                      [.presented, .completed, .cancelled, .dismissed].contains(state),
                      try store.rows("SELECT id FROM proactive_outputs WHERE id=? AND owner=?", [id, owner]).first != nil else { return }
                try store.acknowledgeOutput(id, owner: owner, status: state, reason: command["reason"] as? String)
            case "perception_window_authorize":
                guard perceptionSettings.enabled("macos.window") else { return }
                await NativeWindowPerception.requestAccess()
            case "perception_authorize":
                let source = command["source"] as? String ?? ""
                guard perceptionSettings.enabled(source), ["macos.calendar", "macos.reminders"].contains(source) else { throw NativeCompanionData.error("Enable the source before requesting access") }
                await calendarPerception?.requestAccess(source: source)
            case "perception_history":
                emit("perception.history", ["decisions": try store.proactiveReplay().map { try CompanionProactiveCoding.object($0) }, "sources": perceptionStatus])
            case "configure": await configure(NativeCompanionData.object(command["config"]))
            case "stop": stop()
            case "trigger":
                guard enabled, !paused else { throw NativeCompanionData.error("Companion is disabled or in Do Not Disturb") }
                guard topic == nil, !dailyBusy else { throw NativeCompanionData.error("A conversation or memory consolidation is already running") }
                guard let id = command["characterId"] as? String, visible.contains(where: { $0["id"] as? String == id }) else { throw NativeCompanionData.error("Enable and show this character before testing") }
                guard try store.requestCount() < hourly else { throw NativeCompanionData.error("Hourly model budget reached") }
                startTopic(reason: "manual_test", characterID: id)
            case "history": emit("history", ["history": try store.history(400)])
            case "records": emit("records", ["records": try store.records()])
            case "memory", "saveMemory":
                guard let id = command["characterId"] as? String, NativeCompanionData.validID(id) else { throw NativeCompanionData.error("Invalid character") }
                if command["type"] as? String == "saveMemory" {
                    guard let content = command["content"] as? String, content.utf8.count <= 32768 else { throw NativeCompanionData.error("Memory exceeds 32 KB") }
                    stop(); try store.set("memory:\(id)", NativeCompanionData.clean(content, limit: 32768)); try store.exportNotes()
                }
                emit("memory", ["characterId": id, "content": store.get("memory:\(id)") as? String ?? ""])
            case "saveRecord":
                stop(); let name = command["path"] as? String ?? ""
                let result = try store.updateRecord(actor: "user", name: name, content: NativeCompanionData.clean(command["content"] as? String ?? "", limit: 32768), revision: command["expectedRevision"] as? String ?? "")
                guard result["conflict"] as? Bool != true else { throw NativeCompanionData.error("Memory changed; refresh and merge your edits.") }
                emit("record.changed", ["characterId": "user", "path": name, "revision": result["revision"] ?? ""]); try store.exportNotes(); emit("records", ["records": try store.records()])
            case "clear":
                stop(); await roles.interrupt(); let scope = command["scope"] as? String ?? ""
                if scope == "history" { try store.execute("DELETE FROM events"); try store.execute("DELETE FROM deliveries") }
                else if scope == "public" { try store.execute("DELETE FROM records"); try store.execute("DELETE FROM changes") }
                else if NativeCompanionData.validID(scope) { try store.forgetCharacter(scope); try store.set("session:\(scope)", NSNull()); await roles.forget(scope) }
                try store.exportNotes(); emit("history", ["history": try store.history()]); emit("records", ["records": try store.records()])
            case "persona":
                guard let id = command["characterId"] as? String, NativeCompanionData.validID(id) else { throw NativeCompanionData.error("Invalid character") }
                let file = root.appendingPathComponent("characters/\(id)/persona.md")
                guard let markdown = try? String(contentsOf: file, encoding: .utf8) else { throw NativeCompanionData.error("Persona is unavailable") }
                let view = try store.runtimePersona(characterID: id, markdown: markdown)
                emit("persona", ["characterId": id, "content": view, "identityRevision": (try store.latestPersona(characterID: id)?["revision"] as? Int) ?? 0])
            case "persona_preview":
                guard let id = command["characterId"] as? String, NativeCompanionData.validID(id), let markdown = command["markdown"] as? String else { throw NativeCompanionData.error("Persona preview requires character and Markdown") }
                emit("persona.preview", try store.personaChangePreview(characterID: id, markdown: markdown))
            case "memory_items":
                guard let id = command["characterId"] as? String, NativeCompanionData.validID(id) else { throw NativeCompanionData.error("Invalid character") }
                emit("memory.items", ["characterId": id, "memories": try store.memorySearch(owner: id, query: command["query"] as? String ?? "", limit: 100), "growth": try store.growthState(owner: id)])
            case "reflection_preview", "reflection_commit", "reflection_cancel", "growth_commit", "growth_rollback", "growth_cancel":
                guard let id = command["characterId"] as? String, NativeCompanionData.validID(id) else { throw NativeCompanionData.error("Invalid character") }
                let job = command["jobId"] as? String ?? ""
                switch command["type"] as? String {
                case "reflection_preview": _ = try store.reflectionPreview(owner: id)
                case "reflection_commit": _ = try store.commitReflection(owner: id, jobID: job)
                case "reflection_cancel": _ = try store.cancelReflection(owner: id, jobID: job)
                case "growth_cancel": try store.execute("UPDATE growth_jobs SET status='cancelled',reason='',updated_at=? WHERE id=? AND owner=? AND status='preview'", [NativeCompanionData.iso(), job, id])
                case "growth_commit": _ = try store.commitGrowth(owner: id, jobID: job)
                default: _ = try store.rollbackGrowth(owner: id, jobID: job)
                }
                emit("memory.items", ["characterId": id, "memories": try store.memorySearch(owner: id, query: "", limit: 100), "growth": try store.growthState(owner: id)])
            case "memory_forget":
                guard let id = command["characterId"] as? String, NativeCompanionData.validID(id) else { throw NativeCompanionData.error("Invalid character") }
                stop(); await roles.interrupt()
                _ = try store.forgetMemory(command["memoryId"] as? String ?? "", owner: id)
                try store.set("sessionPolicy:\(id)", "memory-invalidated"); await roles.forget(id)
                try store.exportNotes()
                emit("memory.items", ["characterId": id, "memories": try store.memorySearch(owner: id, query: "", limit: 100), "growth": try store.growthState(owner: id)])
            case "world_seed_preview":
                let worldID = command["worldId"] as? String ?? "cyberworld-main"
                let participants = command["participants"] as? [String] ?? []
                let perspectives = NativeCompanionData.object(command["perspectives"])
                let preview = try store.previewRelationshipBootstrap(worldID: worldID, participants: participants, premise: command["premise"] as? String ?? "", perspectives: perspectives, idempotencyKey: command["idempotencyKey"] as? String ?? UUID().uuidString)
                emit("world_seed.preview", preview)
            case "world_seed_commit":
                let result = try store.commitRelationshipBootstrap(previewID: command["previewId"] as? String ?? "", approvedBy: command["approvedBy"] as? String ?? "user")
                emit("world_seed.committed", result)
            case "world_seed_rollback":
                let result = try store.rollbackSeedBatch(command["seedBatchId"] as? String ?? "")
                emit("world_seed.rolled_back", result)
            default: throw NativeCompanionData.error("Unknown host command")
            }
        } catch {
            if (command["type"] as? String ?? "").hasPrefix("monitor_") {
                emit("monitor.error", ["requestID": command["requestID"] ?? "", "message": NativeCompanionData.clean(error.localizedDescription, limit: 400)])
            } else { emit("error", ["requestType": command["type"] ?? "", "message": NativeCompanionData.clean(error.localizedDescription, limit: 240)]) }
        }
    }
    func waitForTopic() async { await topic?.task?.value }
    // One job at a time; calendar catch-up does not rotate through empty intermediate Sessions.
    func runDaily(now: Date = Date(), zone: TimeZone = .current) async {
        guard ready, !stopped, enabled, topic == nil, config["sleeping"] as? Bool != true else { dailyBusy = false; return }
        dailyBusy = true
        defer { dailyBusy = false; if !stopped { status() } }
        let memoryStore = store!
        let minute = min(1439, max(0, config["dailyConsolidationMinute"] as? Int ?? 240))
        for character in characters where character["enabled"] as? Bool == true {
            let id = character["id"] as! String
            var batch: CompanionObject?
            do {
                try Task.checkCancellation()
                guard enabled, !stopped else { return }
                guard var job = try memoryStore.dailyPlan(owner: id, minute: minute, now: now, zone: zone),
                      (job["retry_at"] as? Double ?? 0) <= now.timeIntervalSince1970 else { continue }
                batch = job
                let jobID = job["id"] as! String
                if job["status"] as? String == "pending" {
                    let input = NativeCompanionData.object(try NativeCompanionData.decode(Data((job["input"] as! String).utf8)))
                    // Discard stale candidates after user corrections/forgetting. Never regenerate forgotten text.
                    if input["revision"] as? String != (try memoryStore.dailyRevision(id)) {
                        try memoryStore.execute("UPDATE daily_archives SET input=?,error=NULL WHERE id=?", [NativeCompanionData.string([
                            "owner": id, "from": input["from"] ?? "", "to": input["to"] ?? "", "timeZone": zone.identifier,
                            "dialogue": try memoryStore.dailyDialogue(owner: id, from: Date(timeIntervalSince1970: job["start_at"] as! Double), to: Date(timeIntervalSince1970: job["end_at"] as! Double)),
                            "existingMemories": try memoryStore.dailyBackground(owner: id), "openLoops": try memoryStore.dailyPendingContext(owner: id), "revision": try memoryStore.dailyRevision(id), "identity": try memoryStore.publicIdentityCard(characterID: id, name: "")]), jobID])
                        job = try memoryStore.rows("SELECT * FROM daily_archives WHERE id=?", [jobID]).first!
                    }
                    let snapshot = NativeCompanionData.object(try NativeCompanionData.decode(Data((job["input"] as! String).utf8)))
                    let result: CompanionObject
                    if NativeCompanionData.array(snapshot["dialogue"]).isEmpty { result = ["summary": "", "items": [], "resolved": []] }
                    else {
                        guard try memoryStore.spend(hourly) else { throw NativeCompanionData.error("Hourly model budget reached; daily consolidation will retry") }
                        try memoryStore.execute("UPDATE daily_archives SET attempts=attempts+1 WHERE id=?", [jobID])
                        result = try await roles.consolidate(id: id, job: job, model: model, hourlyLimit: hourly)
                    }
                    try Task.checkCancellation()
                    guard enabled, !stopped else { return }
                    try memoryStore.dailyCommit(jobID, output: result)
                }
                try Task.checkCancellation()
                guard enabled, !stopped else { return }
                // Invalidated while awaiting a model: never switch Sessions for that batch.
                guard try memoryStore.rows("SELECT status FROM daily_archives WHERE id=?", [jobID]).first?["status"] as? String == "committed" else { continue }
                let end = job["end_at"] as! Double
                let caughtUp = NativeCompanionDaily.next(after: Date(timeIntervalSince1970: end), minute: minute, zone: zone) > now
                // Empty days with no role Session need no remote work.
                var session: String?
                if caughtUp, memoryStore.get("session:\(id)") is String, memoryStore.get("dailyNeedsRotation:\(id)") as? Bool == true {
                    session = try await roles.rotate(id: id, jobID: jobID, model: model)
                    try memoryStore.set("dailyBridgeFrom:\(id)", end)
                }
                try memoryStore.dailyFinish(jobID, newSession: session, minute: minute, zone: zone, now: now)
                try memoryStore.exportNotes()
                emit("monitor.invalidate", ["owner": id])
            } catch {
                guard !stopped else { return }
                if let job = batch {
                    let attempts = job["attempts"] as? Int ?? 0
                    let delay = min(3600.0, 60 * pow(2, Double(min(attempts, 6))))
                    try? memoryStore.execute("UPDATE daily_archives SET retry_at=?,error=? WHERE id=? AND status IN ('pending','committed')", [now.timeIntervalSince1970 + delay, NativeCompanionData.clean(error.localizedDescription, limit: 240), job["id"]])
                }
            }
        }
    }
    func helperDiagnostics() async -> CompanionObject { await helper.diagnostics() }
    func diagnostics() async -> CompanionObject { ["sources": sources, "openCodeService": openCodeService, "busy": topic != nil || dailyBusy,
        "dailyArchives": (try? store.rows("SELECT owner,status,end_at,error,attempts,usage FROM daily_archives ORDER BY end_at DESC LIMIT 20")) ?? [], "helper": await helper.diagnostics()] }
    func reconcileAfterWake() async { await observers.reconcileClaude(); pollAt = .distantPast }
    func close() async {
        guard !stopped else { return }
        timer?.cancel(); timer = nil; stop(); stopped = true; ready = false
        dailyTask?.cancel(); await dailyTask?.value; dailyTask = nil
        await serviceMonitor?.close(); serviceMonitor = nil
        await windowPerception?.stop(); windowPerception = nil
        await audioPerception?.stop(); audioPerception = nil
        await directoryPerception?.stop(); directoryPerception = nil
        await focusPerception?.stop(); focusPerception = nil
        await notificationPerception?.stop(); notificationPerception = nil
        await calendarPerception?.stop(); calendarPerception = nil
        await macPerception?.stop(); macPerception = nil
        await observers.close(); await roles?.close()
        await topic?.task?.value
        broker?.close(); broker = nil; try? store?.exportNotes(); store = nil; rootLock = nil
    }
}
