import Foundation

private let a = "11111111-1111-4111-8111-111111111111"
private let b = "22222222-2222-4222-8222-222222222222"
private final class SearchProtocol: URLProtocol {
    static var responseData = Data()
    static var statusCode = 200
    static var lastRequest: URLRequest?
    static var lastBody = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRequest = request
        Self.lastBody = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }; Self.lastBody.append(contentsOf: buffer.prefix(count))
            }
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.statusCode, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
private final class Events {
    private let lock = NSLock(); private var values: [CompanionObject] = []
    func add(_ event: CompanionObject) { lock.withLock { values.append(event) } }
    func all() -> [CompanionObject] { lock.withLock { values } }
}
private actor FakeRoles: NativeCompanionRoleClient {
    var calls: [String] = []
    var contexts: [CompanionObject] = []
    var receipts = 0
    var handler: ((String, CompanionObject) async throws -> String)?
    func generate(id: String, context: CompanionObject, model: String, reserve: @escaping () async throws -> Bool) async throws -> String {
        calls.append(id); contexts.append(context)
        return try await handler?(id, context) ?? "{\"text\":\"hello\",\"emotion\":\"happy\"}"
    }
    func consolidate(id: String, job: CompanionObject, model: String, hourlyLimit: Int) async throws -> CompanionObject {
        let input = NativeCompanionData.object(try NativeCompanionData.decode(Data((job["input"] as! String).utf8)))
        let ids = NativeCompanionData.array(input["dialogue"]).compactMap { $0["id"] as? String }
        return ["summary": "A promised to watch a movie tomorrow.", "summaryEvidenceIds": ids,
                "items": [["kind": "open_loop", "content": "Watch a movie tomorrow", "evidenceIds": ids]], "resolved": []]
    }
    func rotate(id: String, jobID: String, model: String) async throws -> String { "ses_daily_" + jobID }
    func receive(id: String, from: String, text: String, messageID: String, model: String) async throws -> String { receipts += 1; return "msg_receipt" }
    func reserveContinuation(_ id: String) async throws {}
    func forget(_ id: String) {}
    func interrupt() {}
    func reapStale() {}
    func close() {}
    func setHandler(_ callback: @escaping (String, CompanionObject) async throws -> String) { handler = callback }
    func count() -> Int { calls.count }
    func last() -> String? { calls.last }
}
private actor ServiceFixture {
    var running = false
    var starts = 0
    var fail = false
    func health() throws -> NativeCompanionHTTP {
        guard running else { throw NativeOpenCodeServiceError.stopped }
        return NativeCompanionHTTP(baseURL: URL(string: "http://127.0.0.1:40000")!, registeredPID: 42, registeredVersion: "2.2.5")
    }
    func start() async throws {
        starts += 1
        try await Task.sleep(nanoseconds: 30_000_000)
        if fail { throw NativeOpenCodeServiceError.startFailed }; running = true
    }
    func stopService() { running = false }
    func setFail() { fail = true }
    func stats() -> (running: Bool, starts: Int) { (running, starts) }
}

@main struct NativeCompanionTests {
    static var checks: [String] = []
    static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw NativeCompanionData.error(message) }; checks.append(message); print("PASS: \(message)")
    }
    static func main() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lite2d-native-tests-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let args = CommandLine.arguments
            guard args.count >= 5 else { throw NativeCompanionData.error("Expected helper, prompt, node and app paths") }
            let script = URL(fileURLWithPath: args[1]), promptFile = URL(fileURLWithPath: args[2]), node = args[3], executable = args[4]
            let clock = ISO8601DateFormatter()
            let singapore = NativeCompanionData.currentTime(clock.date(from: "2026-11-09T16:30:00Z")!, timeZone: TimeZone(identifier: "Asia/Singapore")!)
            try check(singapore["local"] as? String == "2026-11-10T00:30:00+08:00" && singapore["weekday"] as? String == "Tuesday" && singapore["utcOffsetSeconds"] as? Int == 28800, "Local clock uses the local calendar date across UTC midnight")
            let newYork = TimeZone(identifier: "America/New_York")!
            let beforeDST = NativeCompanionData.currentTime(clock.date(from: "2026-11-01T05:30:00Z")!, timeZone: newYork)
            let afterDST = NativeCompanionData.currentTime(clock.date(from: "2026-11-01T06:30:00Z")!, timeZone: newYork)
            try check(beforeDST["local"] as? String == "2026-11-01T01:30:00-04:00" && afterDST["local"] as? String == "2026-11-01T01:30:00-05:00" && afterDST["utcOffsetSeconds"] as? Int == -18000, "Clock offsets follow daylight saving transitions at the supplied instant")
            let store = try NativeCompanionStore(root: root.appendingPathComponent("store"))
            try store.set("session:\(a)", "ses_existing"); try store.set("memory:\(a)", "private")
            let first = try store.readRecord("shared.md"), revision = first["revision"] as! String
            let result = try store.updateRecord(actor: a, name: "shared.md", content: "A wrote this", revision: revision)
            try check(result["revision"] as? String != revision, "Native store retains transactional revisions")
            try check(try store.updateRecord(actor: b, name: "shared.md", content: "overwrite", revision: revision)["conflict"] as? Bool == true, "Concurrent record overwrite is refused")
            try check(try store.rows("SELECT actor FROM changes").first?["actor"] as? String == a, "Record audit preserves author")
            try check(try store.readRecord("shared.md")["exists"] as? Bool == true && store.readRecord("plans.md")["exists"] as? Bool == false, "Shared notes explicitly distinguish existing and new paths")
            let created = try store.updateRecord(actor: a, name: "plans.md", content: "A suggested a tea party.")
            try check(created["conflict"] == nil, "First shared note can be created without a prior revision read")
            try check(try store.updateRecord(actor: b, name: "plans.md", content: "Blind overwrite")["conflict"] as? Bool == true, "Omitting a revision cannot overwrite an existing shared note")
            let merged = try store.updateRecord(actor: b, name: "plans.md", content: "A suggested a tea party; B agreed.", revision: created["revision"] as? String)
            try check(merged["conflict"] == nil && (try store.readRecord("plans.md")["content"] as? String) == "A suggested a tea party; B agreed.", "Another companion can merge shared notes using the current revision")
            var rejected = false; do { _ = try store.readRecord("../bad.md") } catch { rejected = true }
            try check(rejected, "Record path traversal is rejected")
            try store.exportNotes()
            try check(try String(contentsOf: store.root.appendingPathComponent("characters/\(a)/memory.md"), encoding: .utf8) == "private", "Native memory projection matches existing file format")
            let reopened = try NativeCompanionStore(root: store.root)
            try check(reopened.get("session:\(a)") as? String == "ses_existing" && reopened.get("memory:\(a)") as? String == "private", "Existing database sessions and memory survive reopening")
            try check(try reopened.memorySearch(owner: a, query: "private").contains { $0["provenance"] as? String == "legacy_import" }, "Legacy private memory is backfilled into structured storage")
            let persona = """
            ---
            character_id: test
            ---
            # Persona

            ## 1. 我是谁
            你是测试角色，喜欢谨慎记录事实。

            ## 4. 和姐姐的关系
            你尊重姐姐，但不会替她发言。
            """
            let personaRevision = try reopened.ingestPersona(characterID: a, markdown: persona)
            try check(personaRevision["revision"] as? Int == 1, "Persona edits create a versioned identity revision")
            try check((try reopened.personaChangePreview(characterID: a, markdown: persona.replacingOccurrences(of: "谨慎", with: "谨慎且诚实")))["changed"] as? Bool == true, "Persona edits support a non-destructive change preview")
            let card = try reopened.publicIdentityCard(characterID: a, name: "测试角色")
            try check((card["confirmed"] as? String)?.contains("测试角色") == true && card["unknown"] != nil, "Public identity cards expose confirmed content and preserve unknowns")
            try check((try reopened.runtimePersona(characterID: a, markdown: persona)).contains("Controller-managed identity context"), "Runtime Persona view includes traceable managed identity context")
            let written = try reopened.memoryWrite(owner: a, type: "fact", provenance: "experienced", content: "A observed a real event", evidenceIDs: ["event-1"])
            let memoryID = written["memoryId"] as! String
            try check(try reopened.memorySearch(owner: a, query: "real event").contains { $0["id"] as? String == memoryID }, "Structured memory search is scoped to its owner")
            let corrected = try reopened.memoryCorrect(memoryID, owner: a, content: "A corrected the event", expectedRevision: 1, reason: "verified source")
            try check(corrected["conflict"] == nil && (try reopened.memoryRead(memoryID, owner: a)) == nil, "Memory correction supersedes the old revision")
            let forgetID = try reopened.memoryWrite(owner: a, type: "fact", content: "temporary secret") ["memoryId"] as! String
            try check(try reopened.forgetMemory(forgetID, owner: a) && (try reopened.memoryRead(forgetID, owner: a)) == nil, "Forgotten memory leaves ordinary retrieval and indexes")
            let seedPreview = try reopened.previewRelationshipBootstrap(worldID: "cyberworld", participants: [a, b], premise: "The sisters have known each other for years.", perspectives: [
                a: ["role": "younger_sister", "trust": 0.8, "impression": "warm and impulsive"],
                b: ["role": "elder_sister", "trust": 0.9, "impression": "calm and careful"]
            ], idempotencyKey: "seed-22-33-v1")
            let seedID = seedPreview["previewId"] as! String
            try check(seedPreview["status"] as? String == "preview", "Relationship bootstrap supports a dry-run preview")
            let committed = try reopened.commitRelationshipBootstrap(previewID: seedID, approvedBy: "user")
            try check(committed["status"] as? String == "committed" && (try reopened.relationGet(observer: a, target: b))?["role"] as? String == "younger_sister", "Relationship bootstrap commits directional views atomically")
            let replay = try reopened.previewRelationshipBootstrap(worldID: "cyberworld", participants: [a, b], premise: "ignored", perspectives: [:], idempotencyKey: "seed-22-33-v1")
            try check(replay["idempotent"] as? Bool == true && replay["previewId"] as? String == seedID, "Relationship bootstrap retries are idempotent")
            try check((try reopened.rollbackSeedBatch(seedID))["status"] as? String == "rolled_back" && (try reopened.relationGet(observer: a, target: b)) == nil, "Relationship bootstrap rollback archives both directional views")
            let evolved = persona.replacingOccurrences(of: "谨慎", with: "谨慎且诚实")
            _ = try reopened.ingestPersona(characterID: a, markdown: evolved)
            let restored = try reopened.ingestPersona(characterID: a, markdown: persona)
            try check(restored["revision"] as? Int == 3 && (try reopened.latestPersona(characterID: a))?["markdown"] as? String == persona, "Restoring an older Persona creates the current revision instead of reviving stale claims")
            let previewConflict = try reopened.personaChangePreview(characterID: a, markdown: evolved)
            try check(!(previewConflict["conflicts"] as? [CompanionObject] ?? []).isEmpty, "Persona preview identifies changed identity claims")
            try check(!(try reopened.memorySearch(owner: a, query: "")).contains { $0["provenance"] as? String == "world_seed" }, "Seed rollback removes background memories from normal recall")
            let lifecycle = try NativeCompanionStore(root: root.appendingPathComponent("lifecycle"))
            let ev1 = try lifecycle.memoryWrite(owner: a, type: "event", provenance: "experienced", content: "We verified the compiler output")["memoryId"] as! String
            let ev2 = try lifecycle.memoryWrite(owner: a, type: "event", provenance: "told_by_other", content: "B told me the tests passed", sourceActorID: b)["memoryId"] as! String
            _ = try lifecycle.memoryWrite(owner: b, type: "event", content: "Other actor private source")
            let reflection = try lifecycle.reflectionPreview(owner: a).first!
            let jobID = reflection["id"] as! String
            try check(try lifecycle.reflectionPreview(owner: a).first?["id"] as? String == jobID, "Reflection preview is idempotent for the same evidence set")
            let summarized = try lifecycle.commitReflection(owner: a, jobID: jobID)
            let summaryID = summarized["memoryId"] as! String
            try check(try lifecycle.memoryRead(summaryID, owner: a)?["provenance"] as? String == "inferred", "Reviewed consolidation preserves inferred provenance and evidence IDs")
            var wrongOwner = false
            do { _ = try lifecycle.commitReflection(owner: b, jobID: jobID) } catch { wrongOwner = true }
            try check(wrongOwner && (try lifecycle.memoryRead(summaryID, owner: b)) == nil, "Reflection jobs and source memories cannot cross owners")
            var repeatedCommit = false
            do { _ = try lifecycle.commitReflection(owner: a, jobID: jobID) } catch { repeatedCommit = true }
            try check(repeatedCommit, "A reviewed reflection cannot commit twice")
            _ = try lifecycle.forgetMemory(ev1, owner: a)
            try check((try lifecycle.memoryRead(summaryID, owner: a)) == nil && (try lifecycle.rows("SELECT content FROM memory_items WHERE id=?", [ev1]).first?["content"] as? String) == "", "Forgetting purges source text and invalidates derived summaries")
            let afterRestart = try NativeCompanionStore(root: lifecycle.root)
            try check((try afterRestart.memorySearch(owner: a, query: "compiler")).isEmpty, "Deleted evidence and summaries stay forgotten after restart")
            let synthetic = try NativeCompanionStore(root: root.appendingPathComponent("synthetic"))
            _ = try synthetic.memoryWrite(owner: a, type: "fact", provenance: "world_seed", content: "Synthetic history")
            _ = try synthetic.memoryWrite(owner: a, type: "fact", provenance: "inferred", content: "Repeated guess")
            try check((try synthetic.reflectionPreview(owner: a)).isEmpty, "Synthetic background and repeated inference cannot bootstrap reflection evidence")
            _ = try lifecycle.memoryWrite(owner: a, type: "event", content: "Another real result")
            let cancel = try lifecycle.reflectionPreview(owner: a).first!["id"] as! String
            try check(try lifecycle.cancelReflection(owner: a, jobID: cancel) && !lifecycle.cancelReflection(owner: a, jobID: cancel), "Reflection cancellation is explicit and cannot report success twice")
            let growthStore = try NativeCompanionStore(root: root.appendingPathComponent("growth"))
            let seed = try growthStore.previewRelationshipBootstrap(worldID: "test", participants: [a, b], premise: "Test background", perspectives: [:], idempotencyKey: "growth-seed")
            let growthSeed = seed["previewId"] as! String
            _ = try growthStore.commitRelationshipBootstrap(previewID: growthSeed, approvedBy: "user")
            let g1 = try growthStore.memoryWrite(owner: a, type: "event", provenance: "told_by_other", content: "B shared a real result", sourceActorID: b)["memoryId"] as! String
            let g2 = try growthStore.memoryWrite(owner: a, type: "event", provenance: "experienced", content: "We collaborated again", sourceActorID: b)["memoryId"] as! String
            let g = try growthStore.previewGrowth(owner: a, target: b, field: "familiarity", value: 0.55, evidence: [g1, g2], reason: "Two actual exchanges")
            let gid = g["id"] as! String
            try check((try growthStore.relationGet(observer: a, target: b))?["familiarity"] as? Double == 0.5, "Growth previews never change live relationship state")
            _ = try growthStore.commitGrowth(owner: a, jobID: gid)
            try check((try growthStore.relationGet(observer: a, target: b))?["familiarity"] as? Double == 0.55 && (try growthStore.relationGet(observer: b, target: a))?["familiarity"] as? Double == 0.5, "Reviewed growth updates only the actor's directional relationship")
            let fresh = try ["Third collaboration", "Fourth collaboration", "Fifth collaboration", "Sixth collaboration"].map {
                try growthStore.memoryWrite(owner: a, type: "event", content: $0, sourceActorID: b)["memoryId"] as! String
            }
            let stale = try growthStore.previewGrowth(owner: a, target: b, field: "familiarity", value: 0.6, evidence: Array(fresh.prefix(2)), reason: "Pending another review")
            _ = try growthStore.rollbackGrowth(owner: a, jobID: gid)
            var staleRejected = false
            do { _ = try growthStore.commitGrowth(owner: a, jobID: stale["id"] as! String) } catch { staleRejected = true }
            try check(staleRejected, "Stale growth proposals cannot overwrite a later rollback")
            let capped = try growthStore.previewGrowth(owner: a, target: b, field: "familiarity", value: 0.56, evidence: Array(fresh.suffix(2)), reason: "Over daily allowance")
            var cappedRejected = false
            do { _ = try growthStore.commitGrowth(owner: a, jobID: capped["id"] as! String) } catch { cappedRejected = true }
            try check(cappedRejected, "Daily growth caps include changes that were subsequently rolled back")
            var identityRejected = false
            do { _ = try growthStore.previewGrowth(owner: a, field: "identity", value: 0.51, evidence: [g1, g2], reason: "Not allowed") } catch { identityRejected = true }
            try check(identityRejected, "Growth cannot change locked identity or system policy")
            let trait = try growthStore.previewGrowth(owner: a, field: "carefulness", value: 0.53, evidence: [g1, g2], reason: "Learned to verify")
            _ = try growthStore.commitGrowth(owner: a, jobID: trait["id"] as! String)
            try check((try growthStore.growthState(owner: a)["traits"] as? [CompanionObject])?.first?["value"] as? Double == 0.53, "Reviewed trait growth is persisted separately from locked Persona")
            let rolled = try growthStore.rollbackSeedBatch(growthSeed)
            try check(!(rolled["conflicts"] as? [String] ?? []).isEmpty && (try growthStore.relationGet(observer: a, target: b)) != nil, "Seed rollback preserves later real relationship changes and reports conflicts")
            _ = try growthStore.forgetMemory(g1, owner: a)
            try check((try growthStore.growthState(owner: a)["traits"] as? [CompanionObject] ?? []).isEmpty, "Growth with invalidated evidence is withheld from runtime traits")
            let pack = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("doc/companion/persona_pack")
            if FileManager.default.fileExists(atPath: pack.appendingPathComponent("persona_22.md").path) {
                let personas = try ["22", "33"].map { try String(contentsOf: pack.appendingPathComponent("persona_\($0).md"), encoding: .utf8) }
                let identity = try NativeCompanionStore(root: root.appendingPathComponent("pack-identities"))
                _ = try identity.ingestPersona(characterID: a, markdown: personas[0])
                _ = try identity.ingestPersona(characterID: b, markdown: personas[1])
                let c22 = try identity.publicIdentityCard(characterID: a, name: "22")
                let c33 = try identity.publicIdentityCard(characterID: b, name: "33")
                let text22 = c22["confirmed"] as? String ?? "", text33 = c33["confirmed"] as? String ?? ""
                try check(text22.contains("姐姐") && text22.contains("160cm") && !text22.contains("你是机娘"), "Actual 22 Persona projects her own identity without 33's machine-body setting")
                try check(text33.contains("妹妹") && text33.contains("机娘") && text33.contains("146cm"), "Actual 33 Persona retains her own machine identity and younger-sister role")
                try check(!text22.contains("呜哇，又报错") && !text33.contains("先给我完整错误"), "Persona examples do not become public identity facts")
                try check(text22.contains("来源：S01") && text33.contains("来源：S01"), "Public identity cards preserve source attribution from the pack")
                let inference = try identity.memoryWrite(owner: b, type: "belief", provenance: "inferred", content: "玩笑推测：姐姐可能也要充电")
                let generated = try identity.runtimePersona(characterID: b, markdown: personas[1])
                try check(generated.contains(inference["memoryId"] as? String ?? "missing") && generated.contains("not identity or independent evidence"), "Generated Persona continuity cites source memory and remains separate from identity")
                try check((try identity.publicIdentityCard(characterID: a, name: "22"))["confirmed"] as? String == text22, "33's private joke cannot alter 22's identity card")
                let edited = personas[0].replacingOccurrences(of: "身高160cm", with: "身高161cm")
                _ = try identity.ingestPersona(characterID: a, markdown: edited)
                let correctedCard = try identity.publicIdentityCard(characterID: a, name: "22")
                try check((correctedCard["confirmed"] as? String)?.contains("161cm") == true && correctedCard["identityRevision"] as? String == "2", "Explicit user Persona correction changes only that actor's current public version")
                let identityRestart = try NativeCompanionStore(root: identity.root)
                try check((try identityRestart.publicIdentityCard(characterID: b, name: "33"))["confirmed"] as? String == text33, "Restart preserves the actual 33 identity independently of 22 revisions")
            } else { print("SKIP: private Persona pack unavailable; release acceptance requires it locally") }
            let timed = try growthStore.memoryWrite(owner: b, type: "event", content: "Yesterday's event learned today", eventID: "event-real", occurredAt: "2026-01-01T00:00:00Z", learnedAt: "2026-01-02T00:00:00Z")
            let timedMemory = try growthStore.memoryRead(timed["memoryId"] as! String, owner: b)!
            try check(timedMemory["occurred_at"] as? String != timedMemory["learned_at"] as? String && timedMemory["event_id"] as? String == "event-real", "Memory preserves separate occurred, learned and recorded times plus event identity")
            _ = try growthStore.memoryWrite(owner: b, type: "fact", content: "三三是机娘，需要充电")
            try check(!(try growthStore.memorySearch(owner: b, query: "机娘")).isEmpty, "Chinese substring recall falls back when the tokenizer has no matching token")
            let revisionSource = try growthStore.memoryWrite(owner: b, type: "fact", content: "sensitive previous value")["memoryId"] as! String
            let revised = try growthStore.memoryCorrect(revisionSource, owner: b, content: "corrected value", expectedRevision: 1, reason: "user correction")["memoryId"] as! String
            _ = try growthStore.forgetMemory(revised, owner: b)
            try check((try growthStore.rows("SELECT content FROM memory_items WHERE id=?", [revisionSource]).first?["content"] as? String) == "", "Forgetting a corrected memory also purges its predecessor chain")
            // Simulate the original pre-edge-table database and verify migration reconstructs dependencies.
            let oldEvent = try growthStore.memoryWrite(owner: b, type: "event", content: "old direct source")["memoryId"] as! String
            let oldSummary = try growthStore.memoryWrite(owner: b, type: "reflection", provenance: "inferred", content: "old derived summary", evidenceIDs: [oldEvent])["memoryId"] as! String
            try growthStore.execute("DELETE FROM memory_dependencies WHERE memory_id=?", [oldSummary])
            let migrated = try NativeCompanionStore(root: growthStore.root)
            _ = try migrated.forgetMemory(oldEvent, owner: b)
            try check((try migrated.memoryRead(oldSummary, owner: b)) == nil, "Upgrade reconstructs dependency edges for pre-existing structured memories")
            let provenance = try NativeCompanionStore(root: root.appendingPathComponent("provenance"))
            let observed = try provenance.recordDirectMemory(owner: b, source: "observed", eventID: "actual-work-1", content: "Observer supplied an unverified activity summary")
            let heard = try provenance.recordDirectMemory(owner: a, source: "told_by_other", eventID: "actual-work-1", content: "B told me about the result", sourceActorID: b)
            try check((try provenance.memoryRead(observed["memoryId"] as! String, owner: b))?["provenance"] as? String == "observed" && (try provenance.memoryRead(heard["memoryId"] as! String, owner: a))?["provenance"] as? String == "told_by_other", "The same underlying event preserves independent observed and told-by-other perspectives")
            let replayed = try provenance.recordDirectMemory(owner: a, source: "told_by_other", eventID: "actual-work-1", content: "Repeated delivery", sourceActorID: b)
            try check(replayed["memoryId"] as? String == heard["memoryId"] as? String && (try provenance.memorySearch(owner: a, query: "")).count == 1, "Repeated direct event delivery does not create duplicate evidence")
            _ = try provenance.forgetMemory(heard["memoryId"] as! String, owner: a)
            _ = try provenance.recordDirectMemory(owner: a, source: "told_by_other", eventID: "actual-work-1", content: "Replay after deletion", sourceActorID: b)
            try check((try provenance.memorySearch(owner: a, query: "")).isEmpty, "A forgotten direct event cannot be revived by delivery replay")
            let same1 = try provenance.memoryWrite(owner: b, type: "event", content: "Another view", eventID: "same-event")["memoryId"] as! String
            let same2 = try provenance.memoryWrite(owner: b, type: "event", content: "Repeated view", eventID: "same-event")["memoryId"] as! String
            var duplicateEvidence = false
            do { _ = try provenance.verifiedEvidence(owner: b, ids: [same1, same2], minimum: 2) } catch { duplicateEvidence = true }
            try check(duplicateEvidence, "Different memories of one event do not count as independent growth evidence")
            let expired = try provenance.memoryWrite(owner: b, type: "fact", content: "No longer valid", validTo: "2020-01-01T00:00:00Z")["memoryId"] as! String
            let future = try provenance.memoryWrite(owner: b, type: "fact", content: "Not yet valid", validFrom: "2099-01-01T00:00:00Z")["memoryId"] as! String
            try check((try provenance.memoryRead(expired, owner: b)) == nil && (try provenance.memoryRead(future, owner: b)) == nil, "Ordinary recall excludes expired and not-yet-valid facts")
            try check(reopened.get("sessionPolicy:\(a)") as? String == "memory-invalidated", "Correcting a memory invalidates cached role Session policy")
            let rollbackStore = try NativeCompanionStore(root: root.appendingPathComponent("seed-transactions"))
            let firstSeed = try rollbackStore.previewRelationshipBootstrap(worldID: "test", participants: [a, b], premise: "First setting", perspectives: [a: ["role": "younger_sister", "trust": 0.8]], idempotencyKey: "layer-one")["previewId"] as! String
            _ = try rollbackStore.commitRelationshipBootstrap(previewID: firstSeed, approvedBy: "user")
            let secondSeed = try rollbackStore.previewRelationshipBootstrap(worldID: "test", participants: [a, b], premise: "Replacement setting", perspectives: [a: ["role": "friend", "trust": 0.3]], idempotencyKey: "layer-two")["previewId"] as! String
            _ = try rollbackStore.commitRelationshipBootstrap(previewID: secondSeed, approvedBy: "user")
            _ = try rollbackStore.rollbackSeedBatch(secondSeed)
            try check((try rollbackStore.relationGet(observer: a, target: b))?["trust"] as? Double == 0.8, "Rolling back a replacement seed restores the previous directional relationship")
            let failureStore = try NativeCompanionStore(root: root.appendingPathComponent("seed-failure"))
            let failedSeed = try failureStore.previewRelationshipBootstrap(worldID: "test", participants: [a, b], premise: "Atomic setting", perspectives: [:], idempotencyKey: "failure")["previewId"] as! String
            try failureStore.execute("CREATE TRIGGER fail_second_edge BEFORE INSERT ON relations WHEN NEW.observer_character_id='\(b)' BEGIN SELECT RAISE(ABORT,'fixture failure'); END")
            var atomicFailure = false
            do { _ = try failureStore.commitRelationshipBootstrap(previewID: failedSeed, approvedBy: "user") } catch { atomicFailure = true }
            try check(atomicFailure && (try failureStore.rows("SELECT id FROM relations")).isEmpty && (try failureStore.rows("SELECT id FROM world_events")).isEmpty && (try failureStore.memorySearch(owner: a, query: "")).isEmpty, "A failed seed transaction leaves no half relationship, world event or background memory")
            let third = "33333333-3333-4333-8333-333333333333"
            let multi = try failureStore.previewRelationshipBootstrap(worldID: "test", participants: [a, b, third], premise: "Three separate perspectives", perspectives: [a: [b: ["role": "friend"], third: ["role": "colleague"]]], idempotencyKey: "multi")["previewId"] as! String
            try failureStore.execute("DROP TRIGGER fail_second_edge")
            _ = try failureStore.commitRelationshipBootstrap(previewID: multi, approvedBy: "user")
            try check((try failureStore.rows("SELECT id FROM relations WHERE status='active'")).count == 6 && (try failureStore.relationGet(observer: a, target: third))?["role"] as? String == "colleague", "Three-character initialization creates all six directional perspectives atomically")
            _ = ev2
            try check(try store.spend(1, now: 1_000_000) && !store.spend(1, now: 1_000_001), "Rolling request budget prevents overspend")
            try check(NativeCompanionData.text(["type": "thinking", "text": "secret"]).isEmpty && NativeCompanionData.text(["type": "tool_result", "content": "secret output"]) == "[tool completed]", "Observer normalization excludes reasoning and raw tool output")
            try check(NativeCompanionData.output("{\"command\":\"execute\"}")["skip"] as? Bool == true, "Malformed model JSON never becomes a command")
            let prompt = try NativeCompanionPrompt.load(promptFile)
            try check(NativeCompanionMCP.tools(prompt).count == 25 && prompt.system(persona: "raw ${persona}").hasSuffix("PERSONA:\nraw ${persona}"), "All 25 tool schemas and unchanged Persona composition load natively")
            let searchResult: CompanionObject = ["jsonrpc": "2.0", "id": 1, "result": ["content": [["type": "text", "text": "Title: Example\nURL: https://example.com"]]]]
            let searchJSON = try NativeCompanionData.json(searchResult)
            let searchSSE = Data(("event: message\r\ndata: " + String(decoding: searchJSON, as: UTF8.self) + "\r\n\r\n").utf8)
            try check(try NativeCompanionSearch.result(searchJSON) == NativeCompanionSearch.result(searchSSE), "Search decodes both JSON and MCP event streams while preserving source URLs")
            let searchConfig = URLSessionConfiguration.ephemeral; searchConfig.protocolClasses = [SearchProtocol.self]
            let searchSession = URLSession(configuration: searchConfig)
            defer { searchSession.invalidateAndCancel() }
            SearchProtocol.responseData = searchSSE
            let searchText = try await NativeCompanionSearch.search(query: "public topic", objective: "find facts", session: searchSession)
            let searchRequest = SearchProtocol.lastRequest!
            let body = NativeCompanionData.object(try NativeCompanionData.decode(SearchProtocol.lastBody))
            let searchParams = NativeCompanionData.object(body["params"])
            try check(searchRequest.url?.absoluteString == "https://mcp.exa.ai/mcp?tools=web_search_exa" && searchRequest.value(forHTTPHeaderField: "Authorization") == nil && searchParams["name"] as? String == "web_search_exa" && searchText.contains("https://example.com"), "Search pins its upstream endpoint and tool without forwarding local credentials")
            SearchProtocol.statusCode = 429
            var rateLimited = false
            do { _ = try await NativeCompanionSearch.search(query: "public topic", objective: "find facts", session: searchSession) } catch { rateLimited = true }
            try check(rateLimited, "Search HTTP failures return errors instead of invented results")
            let allowed = NativeCompanionRoles.rules.filter { $0["effect"] as? String == "allow" }.compactMap { $0["action"] as? String }
            try check(allowed.count == 75 && !allowed.contains(where: { $0.contains("*") || $0.contains("shell") || $0.contains("sonarqube") }), "Role permissions allow exact internal tool names and deny arbitrary third-party MCP tools")
            for invalid: CompanionObject in [["id": 1, "error": ["code": -1]], ["id": 1, "result": ["isError": true, "content": [["type": "text", "text": "failed"]]]], ["id": 2, "result": [:]]] {
                var rejected = false
                do { _ = try NativeCompanionSearch.result(NativeCompanionData.json(invalid)) } catch { rejected = true }
                try check(rejected, "Search rejects MCP errors and unrelated responses")
            }
            var invalidQuery = false
            do { _ = try await NativeCompanionSearch.search(query: " ", objective: "test") } catch { invalidQuery = true }
            try check(invalidQuery, "Empty search queries are rejected before networking")

            let registration = root.appendingPathComponent("service.json")
            var absent = false
            do { _ = try NativeCompanionHTTP.discover(registration: registration) } catch { absent = error as? NativeOpenCodeServiceError == .stopped }
            try check(absent, "Missing service registration reports stopped rather than a file error")
            try NativeCompanionData.json(["url": "http://example.com:40000", "pid": 42]).write(to: registration)
            var nonlocal = false
            do { _ = try NativeCompanionHTTP.discover(registration: registration) } catch { nonlocal = error as? NativeOpenCodeServiceError == .invalidRegistration }
            try check(nonlocal, "Service discovery rejects non-loopback registrations")
            let fixture = ServiceFixture(), serviceEvents = Events()
            let monitor = NativeOpenCodeServiceMonitor(executable: "/missing/opencode", interval: 0.08,
                health: { try await fixture.health() }, starter: { try await fixture.start() }, changed: { serviceEvents.add($0) })
            await monitor.setEnabled(true)
            async let client1 = monitor.ensureRunning()
            async let client2 = monitor.ensureRunning()
            _ = try await client1; _ = try await client2
            let firstStart = await fixture.stats()
            try check(firstStart.starts == 1 && serviceEvents.all().contains(where: { $0["state"] as? String == "starting" }), "Concurrent monitor and observer requests start the service only once")
            await fixture.stopService()
            for _ in 0..<30 {
                if await fixture.stats().running { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            let recovered = await fixture.stats()
            try check(recovered.running && recovered.starts == 2, "Monitor automatically restarts a stopped OpenCode service")
            await monitor.setEnabled(false)
            let leftRunning = await fixture.stats()
            let disabledState = await monitor.snapshot()
            try check(leftRunning.running && (disabledState["state"] as? String) == "disabled", "Disabling Companion stops monitoring without stopping OpenCode")
            await fixture.stopService()
            try await Task.sleep(nanoseconds: 200_000_000)
            try check(await fixture.stats().starts == 2, "Disabled monitoring never restarts the service")
            let gatedFixture = ServiceFixture(), healthEntered = NativeAsyncValue<Bool>(), healthRelease = NativeAsyncValue<Bool>()
            let gatedMonitor = NativeOpenCodeServiceMonitor(executable: "/missing/opencode", interval: 10,
                health: {
                    let value = try await gatedFixture.health()
                    healthEntered.resolve(.success(true))
                    _ = try await healthRelease.wait(seconds: 5)
                    return value
                }, starter: { try await gatedFixture.start() }, changed: { _ in })
            await gatedMonitor.setEnabled(true)
            let gatedAttempt = Task { try await gatedMonitor.ensureRunning() }
            _ = try await healthEntered.wait(seconds: 5)
            await gatedMonitor.setEnabled(false)
            healthRelease.resolve(.success(true))
            _ = try? await gatedAttempt.value
            try check(await gatedMonitor.snapshot()["state"] as? String == "disabled", "A late startup health response cannot overwrite the disabled service state")
            await gatedMonitor.close()
            let failing = ServiceFixture(); await failing.setFail()
            let failedMonitor = NativeOpenCodeServiceMonitor(executable: "/missing/opencode", interval: 0.05,
                health: { try await failing.health() }, starter: { try await failing.start() }, changed: { _ in })
            await failedMonitor.setEnabled(true)
            do { _ = try await failedMonitor.ensureRunning() } catch { }
            do { _ = try await failedMonitor.ensureRunning() } catch { }
            let failedState = await failedMonitor.snapshot(), failedStats = await failing.stats()
            try check(failedState["state"] as? String == "failed" && failedStats.starts == 1, "Failed automatic startup is visible and retries use backoff")
            await failedMonitor.close(); await monitor.close()

            let claudeRoot = root.appendingPathComponent("claude"), directory = claudeRoot.appendingPathComponent("projects/-fixture")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("\(a).jsonl")
            let user: CompanionObject = ["uuid": "user-1", "parentUuid": NSNull(), "sessionId": a, "type": "user", "cwd": "/fixture", "timestamp": "2026-11-05T00:00:00.000Z", "isSidechain": false,
                "message": ["role": "user", "content": "fixture first message"]]
            let answer: CompanionObject = ["uuid": "answer-1", "parentUuid": "user-1", "sessionId": a, "type": "assistant", "cwd": "/fixture", "timestamp": "2026-11-05T00:00:01.000Z", "isSidechain": false,
                "message": ["role": "assistant", "content": [["type": "text", "text": "fixture reply"]]]]
            try (NativeCompanionData.string(user) + "\n" + NativeCompanionData.string(answer) + "\n").write(to: file, atomically: true, encoding: .utf8)
            var environment = ProcessInfo.processInfo.environment; environment["CLAUDE_CONFIG_DIR"] = claudeRoot.path
            let helper = NativeClaudeHelper(node: node, script: script, idleSeconds: 0.7, environment: environment)
            let before = await helper.diagnostics(); try check(before["starts"] as? Int == 0 && before["running"] as? Bool == false, "SDK helper is not started until requested")
            async let one = helper.call("list", ["limit": 100])
            async let two = helper.call("list", ["limit": 100])
            let listed = try await one; _ = try await two
            try check(NativeCompanionData.array(listed).contains { $0["sessionId"] as? String == a }, "Official Claude SDK lists the isolated fixture")
            let coalesced = await helper.diagnostics(); try check(coalesced["starts"] as? Int == 1 && coalesced["requests"] as? Int == 1, "Concurrent identical SDK requests coalesce into one worker call")
            let recent = NativeCompanionData.array(try await helper.call("recent", ["sessionId": a]))
            try check(recent.count == 2 && recent.last?["text"] as? String == "fixture reply", "SDK retains canonical message-chain reading")
            let reused = await helper.diagnostics(); try check(reused["starts"] as? Int == 1, "Consecutive SDK requests reuse the same Node process")
            try await Task.sleep(nanoseconds: 1_100_000_000)
            try check(await helper.diagnostics()["running"] as? Bool == false, "SDK helper exits after idle grace period")
            var denied = false; do { _ = try await helper.call("query") } catch { denied = true }
            try check(denied, "SDK worker whitelist refuses query and arbitrary methods")
            await helper.stop()

            let failureScript = root.appendingPathComponent("worker-fixture.mjs")
            try """
            import {createInterface} from 'node:readline';
            console.log(JSON.stringify({type:'ready',protocolVersion:1}));
            const lines=createInterface({input:process.stdin});
            lines.on('line',line=>{const m=JSON.parse(line);if(m.method==='info'){process.exit(7);}else if(m.method==='shutdown'){process.exit(0);}else setTimeout(()=>console.log(JSON.stringify({id:m.id,result:[]})),250);});
            """.write(to: failureScript, atomically: true, encoding: .utf8)
            let failureHelper = NativeClaudeHelper(node: node, script: failureScript, idleSeconds: 1)
            let pending = Task { try await failureHelper.call("recent", ["sessionId": a]) }
            try await Task.sleep(nanoseconds: 100_000_000)
            await failureHelper.stop()
            var revoked = false; do { _ = try await pending.value } catch { revoked = true }
            try check(revoked, "Source revocation rejects an in-flight SDK result")
            var crashed = false; do { _ = try await failureHelper.call("info", ["sessionId": a]) } catch { crashed = true }
            let beforeRetry = await failureHelper.diagnostics()["starts"] as? Int
            do { _ = try await failureHelper.call("list") } catch { }
            let afterRetry = await failureHelper.diagnostics()["starts"] as? Int
            try check(crashed && afterRetry == beforeRetry, "Worker crash applies backoff without repeated respawn")
            await failureHelper.stop()

            let observedHelper = NativeClaudeHelper(node: node, script: script, idleSeconds: 0.5, environment: environment)
            let observers = NativeCompanionObservers(codex: "/missing/codex", helper: observedHelper, claudeRoot: claudeRoot)
            try await observers.setClaudeEnabled(true)
            let firstPoll = try await observers.poll("claude", excluded: [])
            try check(firstPoll.sessions.count == 1 && firstPoll.changes.isEmpty, "First SDK baseline does not replay old history")
            let callsBefore = await observedHelper.diagnostics()["requests"] as? Int
            try await Task.sleep(nanoseconds: 1_100_000_000)
            _ = try await observers.poll("claude", excluded: []); _ = try await observers.poll("claude", excluded: [])
            let quiet = await observedHelper.diagnostics()
            try check(quiet["starts"] as? Int == 1 && quiet["running"] as? Bool == false && quiet["requests"] as? Int == callsBefore, "Quiet polls never restart Node or invoke SDK")
            let next: CompanionObject = ["uuid": "user-2", "parentUuid": "answer-1", "sessionId": a, "type": "user", "cwd": "/fixture", "timestamp": "2026-11-05T00:00:02.000Z", "message": ["role": "user", "content": "a real change"]]
            let reply: CompanionObject = ["uuid": "answer-2", "parentUuid": "user-2", "sessionId": a, "type": "assistant", "cwd": "/fixture", "timestamp": "2026-11-05T00:00:03.000Z", "isSidechain": false, "message": ["role": "assistant", "content": [["type": "text", "text": "a changed reply"]]]]
            let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd(); try handle.write(contentsOf: Data((NativeCompanionData.string(next) + "\n" + NativeCompanionData.string(reply) + "\n").utf8)); try handle.close()
            var changedPoll = (sessions: [NativeObservedSession](), changes: [CompanionObject]())
            for _ in 0..<16 {
                try await Task.sleep(nanoseconds: 500_000_000)
                changedPoll = try await observers.poll("claude", excluded: [])
                if !changedPoll.changes.isEmpty { break }
            }
            try check(changedPoll.changes.count == 1, "Swift FSEvents wakes SDK only after a real transcript change")
            let afterChange = await observedHelper.diagnostics()
            for _ in 0..<20 { _ = try await observers.poll("claude", excluded: []) }
            let afterBurst = await observedHelper.diagnostics()
            try check(afterChange["requests"] as? Int == afterBurst["requests"] as? Int && afterBurst["starts"] as? Int == 2, "Repeated change polls reuse the worker and never launch one process per poll")
            try await observers.setClaudeEnabled(false)
            try check(await observedHelper.diagnostics()["running"] as? Bool == false, "Revoking Claude source stops its helper")
            await observers.close()

            let events = Events(), fake = FakeRoles(), runtimeRoot = root.appendingPathComponent("runtime")
            let runtime = NativeCompanionRuntime(root: runtimeRoot, promptFile: promptFile, opencode: "/missing/opencode", codex: "/missing/codex", node: node, helperScript: script, executable: executable, roles: fake, manageOpenCodeService: false, emit: events.add)
            try await runtime.start(automatic: false)
            let chars: [CompanionObject] = [["id": a, "name": "A", "enabled": true, "visible": true], ["id": b, "name": "B", "enabled": true, "visible": true]]
            await runtime.command(["type": "configure", "config": ["enabled": true, "characters": chars, "intervalMinutes": 0, "hourlyRequests": 12]])
            await runtime.command(["type": "trigger", "characterId": b]); await runtime.waitForTopic()
            try check(await fake.last() == b && events.all().contains { $0["type"] as? String == "utterance" && $0["characterId"] as? String == b }, "Native manual trigger selects the requested Persona")
            let timeContext = NativeCompanionData.object(await fake.contexts.last?["currentTime"])
            try check(timeContext["timeZone"] as? String == TimeZone.current.identifier && (timeContext["utc"] as? String).flatMap(clock.date(from:)).map { abs($0.timeIntervalSinceNow) < 10 } == true, "Role generation receives a fresh host clock snapshot")
            await runtime.command(["type": "configure", "config": ["enabled": true, "paused": true, "characters": chars]])
            let count = await fake.count(); await runtime.command(["type": "trigger", "characterId": a])
            try check(await fake.count() == count && events.all().contains { $0["type"] as? String == "error" && $0["requestType"] as? String == "trigger" }, "Native Do Not Disturb rejects manual generation")
            await runtime.command(["type": "configure", "config": ["enabled": true, "hourlyRequests": 1, "characters": chars]])
            await runtime.command(["type": "trigger", "characterId": a])
            try check(await fake.count() == count && events.all().contains { ($0["message"] as? String ?? "").contains("budget") }, "Native manual triggers retain the shared request budget")
            await runtime.command(["type": "configure", "config": ["enabled": true, "hourlyRequests": 12, "characters": chars]])
            await fake.setHandler { _, _ in try await Task.sleep(nanoseconds: 30_000_000_000); return "late speech" }
            await runtime.command(["type": "trigger", "characterId": a])
            try await Task.sleep(nanoseconds: 30_000_000)
            await runtime.command(["type": "stop"]); await runtime.waitForTopic()
            try check(!events.all().contains { $0["text"] as? String == "late speech" }, "Cancellation prevents delayed generated speech from appearing")
            await runtime.close()
            try await CompanionDailyTests.run(root: root, prompt: promptFile, helper: script, node: node, executable: executable, check: check)
            try CompanionMonitorTests.run(root: root, check: check)
            try await CompanionFocusTests.run(check: check)
            try CompanionNotificationTests.run(root: root, check: check)
            try await CompanionNotificationTests.runLifecycle(root: root, check: check)
            try await CompanionInitiativeTests.run(root: root, prompt: promptFile, helper: script, node: node, executable: executable, check: check)
            try CompanionContextTests.run(root: root, check: check)
            try CompanionCalendarTests.run(check: check)
            try CompanionProactiveTests.run(root: root, check: check)
            try await CompanionMacPerceptionTests.run(check: check)
            print("PASS: \(checks.count) native Companion checks")
            try FileManager.default.removeItem(at: root)
        } catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }
}
