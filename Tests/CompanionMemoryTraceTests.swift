import Foundation

enum CompanionMemoryTraceTests {
    static func run(root: URL, check: (Bool, String) throws -> Void) throws {
        let a = "11111111-1111-4111-8111-111111111111", b = "22222222-2222-4222-8222-222222222222"
        let store = try NativeCompanionStore(root: root.appendingPathComponent("memory-traces"))
        let source = try store.memoryWrite(owner: a, type: "fact", provenance: "inferred", content: "PRIVATE_SOURCE_BODY")["memoryId"] as! String
        let other = try store.memoryWrite(owner: b, type: "fact", content: "OTHER_OWNER_SECRET")["memoryId"] as! String
        let persona = try store.ingestPersona(characterID: a, markdown: "I am a cheerful companion.")
        let revision = persona["revision"] as! Int
        let now = Date()
        var activityPolicy = CompanionPerceptionPolicy(); activityPolicy.allowedCharacterIds = [a]; activityPolicy.allowedUses = [.attention, .activityContext]; activityPolicy.remoteInferenceAllowed = true
        _ = try store.setPerceptionConsent(source: "macos.workspace", enabled: true, policy: activityPolicy)
        let activity: CompanionObject = ["category": "programming", "confidence": 0.75, "observedAt": NativeCompanionData.iso(now), "expiresAt": NativeCompanionData.iso(now.addingTimeInterval(300))]
        let context: CompanionObject = ["currentTime": NativeCompanionData.currentTime(now), "activity": activity,
            "privateMemoryItems": [["id": source, "content": "PRIVATE_SOURCE_BODY", "revision": 1]],
            "identityRevision": revision, "characters": [["name": "PRIVATE_IDENTITY_VALUE"]],
            "cognition": ["curiosity": 0.5, "expressionEnergy": 0.45], "untrustedExtra": "PRIVATE_PROJECT_PATH"]
        let generation = try store.captureGeneration(owner: a, context: context, origin: "trace_role_generation", model: "fixture/companion", activitySource: "macos.workspace")
        _ = try store.captureGeneration(owner: a, context: context.merging(["styleExamples": [["response": "PRIVATE_STYLE_BODY"]]]) { _, new in new }, origin: "trace_role_generation", model: "fixture/companion", id: generation, final: true, systemHash: "system-fingerprint")
        let captured = try store.generationTrace(generation, owner: a)!
        try check(captured.coverage == "trace_final_request" && captured.fields.contains { $0.key == "trace_activity" && $0.value.contains("programming") } && captured.fields.contains { $0.key == "trace_time" }, "Generation records exact coarse activity/time projections and final request coverage")
        let payload = try store.rows("SELECT payload FROM generation_traces WHERE id=?", [generation])[0]["payload"] as! String
        try check(!["PRIVATE_SOURCE_BODY", "PRIVATE_IDENTITY_VALUE", "PRIVATE_PROJECT_PATH", "PRIVATE_STYLE_BODY"].contains(where: payload.contains), "Generation audit retains references and fingerprints instead of copying private context bodies")
        try check(captured.inputs.contains { $0.id == source && $0.group == "trace_background" } && captured.inputs.contains { $0.kind == "persona" }, "Background memory and Persona version are independently traceable")
        try store.recordGenerationTool(generation, owner: a, name: "memory_read", result: try store.memoryRead(source, owner: a)!)
        let written = try store.memoryWrite(owner: a, type: "event", provenance: "inferred", content: "A derived thought", evidenceIDs: [source], generationID: generation, generationMethod: "trace_model_memory_write")["memoryId"] as! String
        // A later read must not retroactively become input to the earlier memory.
        try store.recordGenerationTool(generation, owner: a, name: "memory_read", result: ["id": other, "content": "OTHER_OWNER_SECRET"])
        let detail = try store.monitorMemoryGeneration(owner: a, memoryID: written)
        let frozen = try store.generationTrace(detail.id, owner: a)!
        try check(frozen.tools.count == 1 && !frozen.inputs.contains { $0.id == other }, "Memory provenance freezes at write time and excludes subsequent tool results")
        try check(frozen.inputs.contains { $0.id == source && $0.group == "trace_cited" } && frozen.inputs.contains { $0.id == source && $0.group == "trace_background" } && frozen.inputs.contains { $0.id == source && $0.group == "trace_tool_inputs" }, "Explicit citations, supplied background and tool reads remain distinct roles")
        let inputIndex = frozen.inputs.firstIndex { $0.id == source && $0.group == "trace_background" }!
        let reference = try store.monitorGenerationInput(owner: a, id: detail.id + ":\(inputIndex)")
        try check(reference.content == "PRIVATE_SOURCE_BODY", "An unchanged input resolves its actual source content from the original owner-scoped record")
        try store.execute("UPDATE memory_items SET content='NEW_SOURCE_BODY',revision=2 WHERE id=?", [source])
        let changed = try store.monitorGenerationInput(owner: a, id: detail.id + ":\(inputIndex)")
        try check(changed.title == "trace_source_changed" && changed.content.isEmpty, "Changed source text is not displayed as the historical input")
        try check(try store.monitorGeneration(owner: b, id: detail.id).status == "unavailable" && store.monitorMemoryGeneration(owner: b, memoryID: written).status == "unavailable" && store.monitorGenerationInput(owner: b, id: detail.id + ":\(inputIndex)").status == "unavailable", "Generation traces and their input contents enforce owner boundaries")
        // Real utterance records retain the generation link without adding text copies.
        let utterance = try store.event("utterance", ["characterId": a, "text": "If you have been sitting, stretch."])
        let dialogue = "dialogue:\(utterance["sequence"]!)"
        try store.bindGeneration(generation, subject: dialogue, owner: a)
        let dailyContext: CompanionObject = ["dialogue": [["id": dialogue, "text": "If you have been sitting, stretch."]], "existingMemories": [["id": source, "content": "NEW_SOURCE_BODY"]]]
        let daily = try store.captureGeneration(owner: a, context: dailyContext, origin: "trace_daily_consolidation", final: true)
        let dailyMemory = try store.memoryWrite(owner: a, type: "event", provenance: "inferred", content: "We discussed stretching", evidenceIDs: [dialogue, source], createdBy: "daily_consolidation", generationID: daily, generationMethod: "trace_daily_consolidation", citedEvidenceIDs: [dialogue])["memoryId"] as! String
        let dailyDetail = try store.monitorMemoryGeneration(owner: a, memoryID: dailyMemory)
        let dailyTrace = try store.generationTrace(dailyDetail.id, owner: a)!
        try check(dailyTrace.inputs.filter { $0.group == "trace_cited" }.map(\.id) == [dialogue] && dailyTrace.inputs.contains { $0.group == "trace_background" && $0.id == source }, "Daily provenance distinguishes cited dialogue from uncited background memories")
        try check(dailyDetail.traceSections?.contains { $0.key == "trace_ancestry" } == true && store.monitorReference(owner: a, id: dialogue).links.contains { $0.kind == "generation" }, "A consolidated memory can follow its source utterance back to the originating role context")
        // Missing legacy snapshots are not invented from current activity.
        try store.execute("DELETE FROM generation_bindings WHERE subject=?", ["memory:" + source])
        let legacy = try store.monitorMemoryGeneration(owner: a, memoryID: source)
        try check(legacy.fields.contains { $0.value == "trace_historical_partial" } && !legacy.fields.contains { $0.key == "trace_activity" }, "Historical memories explicitly report missing model inputs without guessing environment context")
        var restricted = CompanionMonitorQuery(); restricted.owner = a; restricted.detailOwner = a; restricted.detailID = dailyDetail.id; restricted.detailKind = "generation"
        try check(try store.monitorPage(restricted, requestID: "unauthorized-trace", owners: [b]).detail?.status == "unavailable", "Monitor generation queries also enforce the set of managed character owners")
        let oversized = try store.captureGeneration(owner: a, context: ["existingMemories": (0..<300).map { ["id": String($0) + String(repeating: "x", count: 220), "content": "fixture"] }], origin: "trace_daily_consolidation")
        let oversizedPayload = try store.rows("SELECT payload FROM generation_traces WHERE id=?", [oversized])[0]["payload"] as! String
        try check(oversizedPayload.utf8.count <= 65536 && (try store.generationTrace(oversized, owner: a))?.truncated == true, "Large input sets produce bounded traces with an explicit truncation marker")
        // Retention keeps a memory's source lineage even after the unbound audit window.
        let disposable = try store.captureGeneration(owner: a, context: [:], origin: "trace_role_generation")
        try store.execute("UPDATE generation_traces SET at=0")
        try store.pruneGenerations()
        try check(try store.generationTrace(disposable, owner: a) == nil && store.generationTrace(generation, owner: a) != nil && store.generationTrace(dailyDetail.id, owner: a) != nil, "Unbound trace retention is bounded while memory-dependent ancestry remains available")
        try store.redactGenerationActivity(source: "macos.workspace")
        _ = try store.captureGeneration(owner: a, context: context, origin: "trace_role_generation", id: generation, final: true)
        let redacted = try store.generationTrace(generation, owner: a)!
        try check(redacted.fields.contains { $0.key == "trace_activity" && $0.value == "trace_redacted" }, "A late final-request update cannot reintroduce a source's redacted activity projection")
        let ownBefore = try store.rows("SELECT count(*) n FROM generation_traces WHERE owner=?", [a])[0]["n"] as! Int
        _ = try store.forgetMemory(written, owner: b)
        try check(try store.rows("SELECT count(*) n FROM generation_traces WHERE owner=?", [a])[0]["n"] as? Int == ownBefore, "Unauthorized forgetting cannot purge another role's generation audit")
        _ = try store.forgetMemory(written, owner: a)
        try check(try store.rows("SELECT id FROM generation_traces WHERE owner=?", [a]).isEmpty && !store.rows("SELECT id FROM generation_traces WHERE owner=?", [b]).isEmpty, "Forgetting purges the owner's input traces without affecting another role")
        try store.clearConversationHistory()
        try check(try store.rows("SELECT id FROM generation_traces").isEmpty && store.rows("SELECT subject FROM generation_bindings").isEmpty, "Clearing conversation history also removes retained generation inputs and bindings")
        let page = try CompanionMonitorCoding.object(dailyDetail)
        try check(try CompanionMonitorCoding.decode(CompanionMonitorItem.self, page).traceSections?.isEmpty == false, "Generation sections and labeled references round-trip through the monitor protocol")
    }
}
