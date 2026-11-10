import Foundation

private actor DailyFixture: NativeCompanionRoleClient {
    let store: NativeCompanionStore
    var archiveCalls = 0, rotations = 0
    var failArchive = false, failRotation = false
    init(store: NativeCompanionStore) { self.store = store }
    func setFailure(archive: Bool = false, rotation: Bool = false) { failArchive = archive; failRotation = rotation }
    func generate(id: String, context: CompanionObject, model: String, reserve: @escaping () async throws -> Bool) async throws -> String { "{\"skip\":true}" }
    func receive(id: String, from: String, text: String, messageID: String, model: String) async throws -> String { "receipt" }
    func reserveContinuation(_ id: String) async throws {}
    func forget(_ id: String) {}
    func interrupt() {}
    func reapStale() {}
    func close() {}
    func consolidate(id: String, job: CompanionObject, model: String, hourlyLimit: Int) async throws -> CompanionObject {
        archiveCalls += 1
        if failArchive { throw NativeCompanionData.error("Archive fixture offline") }
        let input = NativeCompanionData.object(try NativeCompanionData.decode(Data((job["input"] as! String).utf8)))
        let ids = NativeCompanionData.array(input["dialogue"]).compactMap { $0["id"] as? String }
        return ["summary": "Agreed to watch a movie tomorrow.", "summaryEvidenceIds": ids,
                "items": [["kind": "open_loop", "content": "Watch a movie tomorrow", "evidenceIds": ids]], "resolved": []]
    }
    func rotate(id: String, jobID: String, model: String) async throws -> String {
        if failRotation { throw NativeCompanionData.error("Rotation fixture offline") }
        rotations += 1
        try store.set("session:\(id)", "ses_daily_\(rotations)")
        return "ses_daily_\(rotations)"
    }
}

enum CompanionDailyTests {
    static func run(root: URL, prompt: URL, helper: URL, node: String, executable: String, check: (Bool, String) throws -> Void) async throws {
        let a = "11111111-1111-4111-8111-111111111111", b = "22222222-2222-4222-8222-222222222222"
        let parser = ISO8601DateFormatter(), zone = TimeZone(identifier: "Asia/Singapore")!
        let day = parser.date(from: "2026-11-10T20:00:00Z")! // local Nov 11, 04:00
        let ny = TimeZone(identifier: "America/New_York")!
        let spring = NativeCompanionDaily.next(after: parser.date(from: "2026-03-08T06:59:00Z")!, minute: 150, zone: ny)
        try check(parser.string(from: spring) == "2026-03-08T07:00:00Z", "Daily schedule advances through a missing DST time")
        let autumn = NativeCompanionDaily.next(after: parser.date(from: "2026-11-01T04:00:00Z")!, minute: 90, zone: ny)
        try check(parser.string(from: autumn) == "2026-11-01T05:30:00Z", "Daily schedule chooses the first repeated local time")
        let store = try NativeCompanionStore(root: root.appendingPathComponent("daily-store"))
        try store.set("session:\(a)", "ses_old")
        try store.execute("INSERT INTO events(at,type,payload) VALUES (?,'utterance',?)", [NativeCompanionData.iso(day.addingTimeInterval(-1800)), NativeCompanionData.string(["characterId": a, "text": "Let's watch a movie tomorrow.", "topicId": "movie"])])
        try store.execute("INSERT INTO events(at,type,payload) VALUES (?,'utterance',?)", [NativeCompanionData.iso(day.addingTimeInterval(-1700)), NativeCompanionData.string(["characterId": b, "text": "B private aside."])])
        try store.execute("INSERT INTO deliveries VALUES ('unread','movie',?,?,?,'accepted_pending_context','remote',?)", [b, a, "Unread reply", NativeCompanionData.iso(day.addingTimeInterval(-1600))])
        try check(try store.dailyPlan(owner: a, minute: 240, now: day.addingTimeInterval(-3600), zone: zone) == nil, "First daily initialization defers model calls until the next scheduled boundary")
        let job = try store.dailyPlan(owner: a, minute: 240, now: day, zone: zone)!
        let input = NativeCompanionData.object(try NativeCompanionData.decode(Data((job["input"] as! String).utf8)))
        let dialogue = NativeCompanionData.array(input["dialogue"]), ids = dialogue.compactMap { $0["id"] as? String }
        try check(dialogue.count == 1 && dialogue.first?["text"] as? String == "Let's watch a movie tomorrow.", "Daily evidence excludes other characters' private speech and unread deliveries")
        let jobID = job["id"] as! String
        try check(try store.dailyPlan(owner: a, minute: 300, now: day, zone: zone)?["id"] as? String == jobID, "Changing the time cannot replace a frozen archive batch")
        var bad = false
        do { try store.dailyCommit(jobID, output: ["summary": "fake", "summaryEvidenceIds": ["other-character"], "items": [], "resolved": []]) } catch { bad = true }
        try check(bad && (try store.memorySearch(owner: a, query: "", limit: 100)).isEmpty, "Invalid evidence rejects the entire archive transaction")
        let result: CompanionObject = ["summary": "We discussed a movie.", "summaryEvidenceIds": ids, "items": [["kind": "open_loop", "content": "Watch a movie tomorrow", "evidenceIds": ids]], "resolved": []]
        try store.dailyCommit(jobID, output: result)
        try store.dailyCommit(jobID, output: result)
        try check(try store.memorySearch(owner: a, query: "", limit: 100).count == 2, "A committed batch is idempotent across repeated submissions")
        let wake = try store.dailyWake(a)
        try check(NativeCompanionData.array(wake["unfinished"]).count == 1 && NativeCompanionData.array(wake["recentRecollection"]).count == 1, "A fresh Session can recover the recap and unfinished agreement")
        try check(try store.monitorReference(owner: a, id: ids[0]).content.contains("movie") && store.monitorReference(owner: b, id: ids[0]).content.isEmpty, "Archive evidence links are inspectable only by their owner")
        let reopened = try NativeCompanionStore(root: store.root)
        try check(try reopened.dailyPlan(owner: a, minute: 240, now: day, zone: zone)?["status"] as? String == "committed", "A restart resumes session switching after the memory transaction")
        try store.dailyFinish(jobID, newSession: "ses_new", minute: 300, zone: zone, now: day)
        let schedule = NativeCompanionData.object(store.get("dailySchedule:\(a)"))
        try check(schedule["cursor"] as? Double == day.timeIntervalSince1970 && schedule["due"] as? Double == day.addingTimeInterval(3600).timeIntervalSince1970, "Updated time preserves the processed boundary and schedules the next local occurrence")
        let forgotten = NativeCompanionData.array(wake["unfinished"])[0]["memoryId"] as! String
        _ = try store.forgetMemory(forgotten, owner: a)
        try check(NativeCompanionData.array(try store.dailyWake(a)["unfinished"]).isEmpty && NativeCompanionData.array(try store.dailyWake(a)["recentRecollection"]).isEmpty, "Forgetting invalidates derived recaps and clears wake-up memory")
        try check(try store.rows("SELECT input,result FROM daily_archives").allSatisfy { $0["input"] as? String == "{}" && $0["result"] as? String == "{}" }, "Forgotten text cannot survive in archived task snapshots")

        // A reply sent before the boundary but read later belongs to the later cycle.
        let late = try NativeCompanionStore(root: root.appendingPathComponent("daily-late"))
        try late.execute("INSERT INTO deliveries VALUES ('late','topic',?,?,?,'delivered','remote',?)", [b, a, "I read this after the boundary", NativeCompanionData.iso(day.addingTimeInterval(-120))])
        try late.execute("INSERT INTO daily_receipts VALUES ('late',?)", [NativeCompanionData.iso(day.addingTimeInterval(120))])
        try check(try late.dailyDialogue(owner: a, from: day.addingTimeInterval(-3600), to: day).isEmpty && late.dailyDialogue(owner: a, from: day, to: day.addingTimeInterval(3600)).count == 1, "Delayed receipts are attributed to consumption time, so no daily cycle loses them")
        let scoped = try NativeCompanionStore(root: root.appendingPathComponent("daily-resolution"))
        try scoped.execute("INSERT INTO events(at,type,payload) VALUES (?,'utterance',?)", [NativeCompanionData.iso(day.addingTimeInterval(-60)), NativeCompanionData.string(["characterId": a, "text": "Watch a movie tomorrow"])])
        _ = try scoped.dailyPlan(owner: a, minute: 240, now: day.addingTimeInterval(-3600), zone: zone)
        let firstJob = try scoped.dailyPlan(owner: a, minute: 240, now: day, zone: zone)!
        let firstInput = NativeCompanionData.object(try NativeCompanionData.decode(Data((firstJob["input"] as! String).utf8)))
        let firstEvidence = NativeCompanionData.array(firstInput["dialogue"]).compactMap { $0["id"] as? String }
        try scoped.dailyCommit(firstJob["id"] as! String, output: ["summary": "", "items": [["kind": "open_loop", "content": "Watch a movie tomorrow", "evidenceIds": firstEvidence]], "resolved": []])
        let loopID = try scoped.dailyLoops(a)[0]["id"] as! String
        try scoped.dailyFinish(firstJob["id"] as! String, newSession: nil, minute: 240, zone: zone, now: day)
        try scoped.execute("INSERT INTO events(at,type,payload) VALUES (?,'utterance',?)", [NativeCompanionData.iso(day.addingTimeInterval(60)), NativeCompanionData.string(["characterId": a, "text": "We finished the movie"])])
        let secondJob = try scoped.dailyPlan(owner: a, minute: 240, now: day.addingTimeInterval(86400), zone: zone)!
        let secondInput = NativeCompanionData.object(try NativeCompanionData.decode(Data((secondJob["input"] as! String).utf8)))
        let secondEvidence = NativeCompanionData.array(secondInput["dialogue"]).compactMap { $0["id"] as? String }
        try scoped.dailyCommit(secondJob["id"] as! String, output: ["summary": "", "items": [], "resolved": [["memoryId": loopID, "evidenceIds": secondEvidence]]])
        try check(try scoped.dailyLoops(a).isEmpty && scoped.memoryRead(loopID, owner: a)?["continuityStatus"] as? String == "resolved", "A supported resolution removes a promise from pending recall while retaining its inspectable history")

        let runtimeRoot = root.appendingPathComponent("daily-runtime"), runtimeStore = try NativeCompanionStore(root: runtimeRoot)
        try runtimeStore.set("session:\(a)", "ses_original")
        try runtimeStore.execute("INSERT INTO events(at,type,payload) VALUES (?,'utterance',?)", [NativeCompanionData.iso(day.addingTimeInterval(-60)), NativeCompanionData.string(["characterId": a, "text": "Tomorrow's movie"])])
        let fake = DailyFixture(store: runtimeStore)
        let runtime = NativeCompanionRuntime(root: runtimeRoot, promptFile: prompt, opencode: "/missing", codex: "/missing", node: node, helperScript: helper, executable: executable, roles: fake, manageOpenCodeService: false, emit: { _ in })
        try await runtime.start(automatic: false)
        await runtime.configure(["enabled": true, "paused": true, "characters": [["id": a, "enabled": true, "visible": true]], "hourlyRequests": 12])
        await runtime.runDaily(now: day.addingTimeInterval(-3600), zone: zone)
        await fake.setFailure(archive: true)
        await runtime.runDaily(now: day, zone: zone)
        try check(runtimeStore.get("session:\(a)") as? String == "ses_original" && (try runtimeStore.memorySearch(owner: a, query: "")).isEmpty, "A failed model task preserves the live Session and writes no memories")
        await fake.setFailure(rotation: true)
        await runtime.runDaily(now: day.addingTimeInterval(120), zone: zone)
        try check(try runtimeStore.rows("SELECT status FROM daily_archives").first?["status"] as? String == "committed" && runtimeStore.get("session:\(a)") as? String == "ses_original", "A failed rotation retains committed memories without discarding the old Session")
        let calls = await fake.archiveCalls
        await fake.setFailure()
        await runtime.runDaily(now: day.addingTimeInterval(300), zone: zone)
        try check(await fake.archiveCalls == calls && runtimeStore.get("session:\(a)") as? String == "ses_daily_1", "Rotation retries never repeat paid memory generation; quiet hours allow silent consolidation")
        let beforeEmpty = await fake.archiveCalls
        await runtime.runDaily(now: day.addingTimeInterval(86400), zone: zone)
        let emptyCalls = await fake.archiveCalls, emptyRotations = await fake.rotations
        try check(emptyCalls == beforeEmpty && emptyRotations == 1, "Empty days advance the archive without model calls or unnecessary Session creation")
        await runtime.configure(["enabled": false, "characters": [["id": a, "enabled": true]]])
        await runtime.runDaily(now: day.addingTimeInterval(172800), zone: zone)
        try check(await fake.archiveCalls == beforeEmpty, "Disabling Companion prevents daily archive tasks")
        await runtime.close()
    }
}
