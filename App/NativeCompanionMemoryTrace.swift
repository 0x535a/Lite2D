import Foundation

// This is local monitoring metadata, never a role prompt or an independent fact.
// Keep references and hashes instead of making another copy of private source text.
struct CompanionGenerationInput: Codable {
    var id: String
    var kind = "reference"
    var group: String
    var digest: String?
    var characters: Int?
    var revision: String?
}

extension NativeCompanionStore {
    func monitorMemoryGeneration(owner: String, memoryID: String) throws -> CompanionMonitorItem {
        guard let row = try rows("SELECT m.*,d.created_by,d.event_id,d.source_ref FROM memory_items m LEFT JOIN memory_details d ON d.memory_id=m.id WHERE m.id=? AND m.owner_character_id=? AND m.status!='deleted'", [memoryID, owner]).first else {
            return .init(id: memoryID, kind: "memory_trace", owner: owner, title: "unavailable", status: "unavailable")
        }
        if let id = try rows("SELECT trace_id FROM generation_bindings WHERE subject=? AND owner=?", ["memory:" + memoryID, owner]).first?["trace_id"] as? String {
            return try monitorGeneration(owner: owner, id: id)
        }
        // Historical rows have no request snapshot. Never call today's activity or
        // a mixed legacy evidence list the inputs that actually produced them.
        var item = CompanionMonitorItem(id: memoryID, kind: "memory_trace", owner: owner, title: "trace_generation")
        item.fields = [.init(key: "trace_method", value: row["provenance"] as? String ?? ""),
                       .init(key: "trace_coverage", value: "trace_historical_partial")]
        var links = evidenceIDs(row).map { CompanionMonitorLink(id: $0) }
        if let event = row["event_id"] as? String { links.append(.init(id: "delivery:" + event)) }
        item.traceSections = [.init(key: "trace_historical_references", links: links)]
        return item
    }
    func monitorGeneration(owner: String, id: String) throws -> CompanionMonitorItem {
        guard let trace = try generationTrace(id, owner: owner) else { return .init(id: id, kind: "generation", owner: owner, title: "unavailable", status: "unavailable") }
        var item = CompanionMonitorItem(id: id, kind: "generation", owner: owner, title: "trace_generation")
        item.fields = [.init(key: "trace_method", value: trace.origin), .init(key: "trace_coverage", value: trace.coverage)] + trace.fields
        if trace.truncated { item.fields.append(.init(key: "trace_limit", value: "trace_truncated")) }
        var sections: [CompanionMonitorTraceSection] = []
        for group in ["trace_cited", "trace_background", "trace_dialogue", "trace_shared", "trace_intentions", "trace_recollection", "trace_pending", "trace_tool_inputs", "trace_identity"] {
            let links = trace.inputs.enumerated().filter { $0.element.group == group }.map { index, ref in
                CompanionMonitorLink(id: id + ":" + String(index), kind: "generation_input", label: ref.kind)
            }
            if !links.isEmpty { sections.append(.init(key: group, links: links)) }
        }
        if !trace.tools.isEmpty { sections.append(.init(key: "trace_tools", fields: trace.tools)) }
        let parents = try rows("SELECT e.parent_id FROM generation_edges e JOIN generation_traces t ON t.id=e.parent_id AND t.owner=e.owner WHERE e.trace_id=? AND e.owner=? ORDER BY t.at", [id, owner])
        if !parents.isEmpty {
            sections.append(.init(key: "trace_ancestry", links: parents.compactMap { row in (row["parent_id"] as? String).map { .init(id: $0, kind: "generation", label: "trace_generation") } }))
        }
        item.traceSections = sections
        return item
    }
    func monitorGenerationInput(owner: String, id: String) throws -> CompanionMonitorItem {
        let parts = id.split(separator: ":")
        guard parts.count == 2, let index = Int(parts[1]), let trace = try generationTrace(String(parts[0]), owner: owner), trace.inputs.indices.contains(index) else {
            return .init(id: id, kind: "generation_input", owner: owner, title: "unavailable", status: "unavailable")
        }
        let ref = trace.inputs[index]
        var item = try monitorReference(owner: owner, id: ref.id, kind: ref.kind == "memory" ? "reference" : ref.kind)
        if let digest = ref.digest {
            let originalSlice = ref.characters.map { String(item.content.prefix($0)) } ?? item.content
            if NativeCompanionData.hash(originalSlice) != digest || ["deleted", "unavailable", "needs_review"].contains(item.status) {
                // Existing records are mutable. Do not present new text as an old input.
                item = .init(id: id, kind: "generation_input", owner: owner, title: "trace_source_changed")
                item.fields = [.init(key: "trace_source_state", value: "trace_changed_help")]
            } else { item.content = originalSlice }
        }
        item.fields.append(.init(key: "trace_input_role", value: ref.group))
        if let digest = ref.digest { item.fields.append(.init(key: "trace_input_hash", value: digest)) }
        if let revision = ref.revision { item.fields.append(.init(key: "trace_input_revision", value: revision)) }
        return item
    }
    func generationLink(subject: String, owner: String) throws -> CompanionMonitorLink? {
        guard let id = try rows("SELECT b.trace_id FROM generation_bindings b JOIN generation_traces t ON t.id=b.trace_id AND t.owner=b.owner WHERE b.subject=? AND b.owner=?", [subject, owner]).first?["trace_id"] as? String else { return nil }
        return .init(id: id, kind: "generation", label: "trace_generation")
    }
}
struct CompanionGenerationTrace: Codable {
    var version = 1
    var origin: String
    var coverage: String
    var fields: [CompanionMonitorField] = []
    var inputs: [CompanionGenerationInput] = []
    var tools: [CompanionMonitorField] = []
    var activitySource: String?
    var truncated = false
}

extension NativeCompanionStore {
    func generationSchema() throws {
        try execute("CREATE TABLE IF NOT EXISTS generation_traces(id TEXT PRIMARY KEY,owner TEXT NOT NULL,at REAL NOT NULL,payload TEXT NOT NULL)")
        try execute("CREATE INDEX IF NOT EXISTS generation_traces_owner_at ON generation_traces(owner,at)")
        try execute("CREATE TABLE IF NOT EXISTS generation_bindings(subject TEXT NOT NULL,owner TEXT NOT NULL,trace_id TEXT NOT NULL,PRIMARY KEY(subject,owner))")
        try execute("CREATE INDEX IF NOT EXISTS generation_bindings_trace ON generation_bindings(trace_id)")
        try execute("CREATE TABLE IF NOT EXISTS generation_edges(trace_id TEXT NOT NULL,parent_id TEXT NOT NULL,owner TEXT NOT NULL,PRIMARY KEY(trace_id,parent_id))")
    }
    func generationTrace(_ id: String, owner: String) throws -> CompanionGenerationTrace? {
        guard let payload = try rows("SELECT payload FROM generation_traces WHERE id=? AND owner=?", [id, owner]).first?["payload"] as? String else { return nil }
        return try CompanionProactiveCoding.decode(CompanionGenerationTrace.self, payload)
    }
    private func writeGeneration(_ id: String, owner: String, trace: CompanionGenerationTrace) throws {
        try CompanionProactiveCoding.require(NativeCompanionData.validID(owner) && NativeCompanionData.validID(id), "Invalid generation identity")
        var bounded = trace
        if let source = bounded.activitySource,
           try perceptionPolicy(source)?.permits(owner, use: .activityContext, remote: true) != true {
            bounded.fields.removeAll { $0.key == "trace_activity" }
            bounded.fields.append(.init(key: "trace_activity", value: "trace_redacted"))
            bounded.activitySource = nil
        }
        var payload = try CompanionProactiveCoding.encode(bounded)
        while payload.utf8.count > 65536 && !bounded.inputs.isEmpty {
            bounded.truncated = true; bounded.inputs.removeLast()
            payload = try CompanionProactiveCoding.encode(bounded)
        }
        try CompanionProactiveCoding.require(payload.utf8.count <= 65536, "Generation trace exceeds its budget")
        try execute("INSERT INTO generation_traces VALUES (?,?,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload WHERE owner=excluded.owner", [id, owner, Date().timeIntervalSince1970, payload])
    }
    func bindGeneration(_ id: String?, subject: String, owner: String) throws {
        guard let id, try generationTrace(id, owner: owner) != nil else { return }
        try execute("INSERT OR REPLACE INTO generation_bindings VALUES (?,?,?)", [subject, owner, id])
    }
    private func generationSubject(_ input: CompanionGenerationInput) -> String {
        input.kind == "memory" ? "memory:" + input.id : input.id
    }
    private func attachGenerationParents(_ id: String, owner: String, inputs: [CompanionGenerationInput]) throws {
        for input in inputs {
            if let parent = try rows("SELECT trace_id FROM generation_bindings WHERE subject=? AND owner=?", [generationSubject(input), owner]).first?["trace_id"] as? String, parent != id {
                try execute("INSERT OR IGNORE INTO generation_edges VALUES (?,?,?)", [id, parent, owner])
            }
        }
    }
    private func generationInputs(_ context: CompanionObject) -> [CompanionGenerationInput] {
        var result: [CompanionGenerationInput] = []
        func add(_ values: Any?, group: String, idKey: String = "id", kind: String = "memory", textKey: String = "content") {
            for row in NativeCompanionData.array(values) {
                guard let id = row[idKey] as? String, !id.isEmpty else { continue }
                let text = row[textKey] as? String
                result.append(.init(id: id, kind: kind, group: group, digest: text.map(NativeCompanionData.hash), characters: text?.count, revision: row["revision"].map { String(describing: $0) }))
            }
        }
        add(context["privateMemoryItems"], group: "trace_background")
        add(context["existingMemories"], group: "trace_background")
        add(context["socialContext"], group: "trace_dialogue", kind: "reference", textKey: "text")
        add(context["dialogue"], group: "trace_dialogue", kind: "reference", textKey: "text")
        if let id = context["messageId"] as? String, let text = context["message"] as? String {
            result.append(.init(id: "delivery:" + id, kind: "reference", group: "trace_pending", digest: NativeCompanionData.hash(text), characters: text.count))
        }
        add(context["sharedMemory"], group: "trace_shared", idKey: "path", kind: "public")
        add(context["intentions"], group: "trace_intentions", kind: "intention", textKey: "goal")
        add(context["openLoops"], group: "trace_intentions")
        let recall = NativeCompanionData.object(context["recollection"])
        add(recall["recentRecollection"], group: "trace_recollection", idKey: "memoryId")
        add(recall["unfinished"], group: "trace_recollection", idKey: "memoryId")
        add(recall["interveningDialogue"], group: "trace_recollection", kind: "reference", textKey: "text")
        for row in NativeCompanionData.array(context["pendingCompanionMessages"]) {
            if let id = row["messageId"] as? String, let text = row["text"] as? String {
                result.append(.init(id: "delivery:" + id, kind: "reference", group: "trace_pending", digest: NativeCompanionData.hash(text), characters: text.count))
            }
        }
        return result
    }
    @discardableResult func captureGeneration(owner: String, context: CompanionObject, origin: String, model: String = "", id: String? = nil, final: Bool = false, systemHash: String? = nil, activitySource: String? = nil) throws -> String {
        try transaction {
            let key = id ?? UUID().uuidString
            var trace = CompanionGenerationTrace(origin: origin, coverage: final ? "trace_final_request" : "trace_runtime_context")
            trace.fields = [.init(key: "trace_model", value: model), .init(key: "trace_captured_at", value: NativeCompanionData.iso()),
                            .init(key: "trace_context_hash", value: NativeCompanionData.hash(NativeCompanionData.string(context))),
                            .init(key: "trace_context_fields", value: context.keys.filter { !$0.hasPrefix("_") }.sorted().joined(separator: ", "))]
            if let reason = context["reason"] as? String { trace.fields.append(.init(key: "trace_reason", value: reason)) }
            let opportunities = NativeCompanionData.array(context["opportunities"]).prefix(3).map { $0.filter { ["kind", "reasonCodes"].contains($0.key) } }
            if !opportunities.isEmpty { trace.fields.append(.init(key: "trace_opportunities", value: NativeCompanionData.string(Array(opportunities)))) }
            for (key, label) in [("currentTime", "trace_time"), ("activity", "trace_activity"), ("cognition", "trace_cognition")] {
                let value = NativeCompanionData.object(context[key])
                let allowed: [String]
                switch key {
                case "currentTime": allowed = ["utc", "local", "timeZone", "utcOffsetSeconds", "weekday"]
                case "activity": allowed = ["category", "confidence", "observedAt", "expiresAt"]
                default: allowed = ["curiosity", "socialInterest", "expressionEnergy", "affect"]
                }
                let bounded = value.filter { allowed.contains($0.key) }
                if !bounded.isEmpty { trace.fields.append(.init(key: label, value: NativeCompanionData.string(bounded))) }
            }
            if let revision = context["identityRevision"] ?? context["personaRevision"] { trace.fields.append(.init(key: "trace_persona_revision", value: String(describing: revision))) }
            if let systemHash { trace.fields.append(.init(key: "trace_system_hash", value: systemHash)) }
            if let session = get("session:\(owner)") as? String { trace.fields.append(.init(key: "trace_session", value: NativeCompanionData.hash(session))) }
            // Values are intentionally not copied: these sections may contain private free text.
            for key in ["characters", "identity", "growth", "relationships", "styleExamples"] where context[key] != nil {
                trace.fields.append(.init(key: "trace_component_" + key, value: NativeCompanionData.hash(NativeCompanionData.string(context[key]!))))
            }
            trace.inputs = generationInputs(context)
            if let revision = context["identityRevision"] as? Int ?? context["personaRevision"] as? Int,
               let persona = try rows("SELECT id FROM persona_revisions WHERE character_id=? AND revision=?", [owner, revision]).first?["id"] as? String {
                trace.inputs.append(.init(id: persona, kind: "persona", group: "trace_identity"))
            }
            trace.truncated = trace.inputs.count > 256
            trace.inputs = Array(trace.inputs.prefix(256))
            let previous = try generationTrace(key, owner: owner)
            trace.activitySource = activitySource ?? previous?.activitySource
            if previous?.fields.contains(where: { $0.key == "trace_activity" && $0.value == "trace_redacted" }) == true {
                trace.fields.removeAll { $0.key == "trace_activity" }
                trace.fields.append(.init(key: "trace_activity", value: "trace_redacted"))
                trace.activitySource = nil
            }
            trace.tools = previous?.tools ?? []
            try writeGeneration(key, owner: owner, trace: trace)
            try attachGenerationParents(key, owner: owner, inputs: trace.inputs)
            return key
        }
    }
    func recordGenerationTool(_ id: String?, owner: String, name: String, args: CompanionObject = [:], result: Any) throws {
        guard let id else { return }
        try transaction {
            guard var trace = try generationTrace(id, owner: owner) else { return }
            if trace.tools.count >= 32 { trace.truncated = true; try writeGeneration(id, owner: owner, trace: trace); return }
            trace.tools.append(.init(key: name, value: NativeCompanionData.iso() + " · " + NativeCompanionData.hash(NativeCompanionData.string(args)) + " → " + NativeCompanionData.hash(NativeCompanionData.string(result))))
            var inputs: [CompanionGenerationInput] = []
            let object = NativeCompanionData.object(result)
            let memories = name == "memory_search" ? NativeCompanionData.array(object["memories"]) : (name == "memory_read" ? [object] : [])
            for memory in memories {
                if let key = memory["id"] as? String, let text = memory["content"] as? String {
                    inputs.append(.init(id: key, kind: "memory", group: "trace_tool_inputs", digest: NativeCompanionData.hash(text), characters: text.count, revision: memory["revision"].map { String(describing: $0) }))
                }
            }
            if name == "public_record_read", let path = object["path"] as? String ?? args["path"] as? String, let text = object["content"] as? String {
                inputs.append(.init(id: path, kind: "public", group: "trace_tool_inputs", digest: NativeCompanionData.hash(text), characters: text.count, revision: object["revision"] as? String))
            }
            if name == "private_memory_read", let text = object["content"] as? String {
                if let key = try rows("SELECT id FROM memory_items WHERE owner_character_id=? AND memory_type='diary' AND status!='deleted' AND content=? ORDER BY rowid DESC LIMIT 1", [owner, text]).first?["id"] as? String {
                    inputs.append(.init(id: key, kind: "memory", group: "trace_tool_inputs", digest: NativeCompanionData.hash(text), characters: text.count))
                }
            }
            trace.truncated = trace.truncated || trace.inputs.count + inputs.count > 256
            trace.inputs += inputs.prefix(max(0, 256 - trace.inputs.count))
            try writeGeneration(id, owner: owner, trace: trace)
            try attachGenerationParents(id, owner: owner, inputs: inputs)
        }
    }
    func recordMemoryGeneration(memoryID: String, owner: String, method: String, citations: [String], generationID: String?, eventID: String?) throws {
        let key = UUID().uuidString
        var trace = try generationID.flatMap { try generationTrace($0, owner: owner) } ?? CompanionGenerationTrace(origin: method, coverage: "trace_sources_only")
        trace.origin = method
        trace.fields.append(.init(key: "trace_written_at", value: NativeCompanionData.iso()))
        var cited = citations
        if let eventID, !eventID.isEmpty, cited.isEmpty { cited = ["delivery:" + eventID] }
        let inputs = Array(Set(cited)).sorted().prefix(128).map { value -> CompanionGenerationInput in
            let kind = NativeCompanionData.validID(value) ? "memory" : "reference"
            let source = try? monitorReference(owner: owner, id: value)
            let text = source?.content
            return .init(id: value, kind: kind, group: "trace_cited", digest: text.flatMap { $0.isEmpty ? nil : NativeCompanionData.hash($0) }, characters: text?.isEmpty == false ? text?.count : nil)
        }
        trace.inputs = Array(inputs) + trace.inputs.filter { $0.group != "trace_cited" }
        trace.truncated = trace.truncated || cited.count > 128 || trace.inputs.count > 384
        trace.inputs = Array(trace.inputs.prefix(384))
        try writeGeneration(key, owner: owner, trace: trace)
        try bindGeneration(key, subject: "memory:" + memoryID, owner: owner)
        // Copy only source ancestry, not the still-running generation: later tool reads
        // must not appear as information available to an earlier memory write.
        if let generationID {
            try execute("INSERT OR IGNORE INTO generation_edges SELECT ?,parent_id,owner FROM generation_edges WHERE trace_id=? AND owner=?", [key, generationID, owner])
        }
        try attachGenerationParents(key, owner: owner, inputs: trace.inputs)
    }
    func purgeGenerations(owner: String? = nil) throws {
        for table in ["generation_edges", "generation_bindings", "generation_traces"] {
            if let owner { try execute("DELETE FROM \(table) WHERE owner=?", [owner]) }
            else { try execute("DELETE FROM \(table)") }
        }
    }
    func redactGenerationActivity(source: String) throws {
        for row in try rows("SELECT id,owner,payload FROM generation_traces WHERE json_extract(payload,'$.activitySource')=?", [source]) {
            var trace = try CompanionProactiveCoding.decode(CompanionGenerationTrace.self, row["payload"] as! String)
            trace.fields.removeAll { $0.key == "trace_activity" }
            trace.fields.append(.init(key: "trace_activity", value: "trace_redacted"))
            trace.activitySource = nil
            try writeGeneration(row["id"] as! String, owner: row["owner"] as! String, trace: trace)
        }
    }
    func pruneGenerations(now: Date = Date()) throws {
        try transaction {
            // Retain ancestry needed by memories. Other contexts: 24h, latest 512
            // globally. UNION (not UNION ALL) also makes accidental cycles finite.
            try execute("""
                WITH RECURSIVE retained(id) AS (
                  SELECT b.trace_id FROM generation_bindings b JOIN memory_items m ON b.subject='memory:'||m.id AND b.owner=m.owner_character_id WHERE m.status!='deleted'
                  UNION SELECT id FROM (SELECT id FROM generation_traces WHERE at>=? ORDER BY at DESC LIMIT 512)
                  UNION SELECT e.parent_id FROM generation_edges e JOIN retained r ON r.id=e.trace_id
                ) DELETE FROM generation_traces WHERE id NOT IN (SELECT id FROM retained)
                """, [now.timeIntervalSince1970 - 86400])
            try execute("DELETE FROM generation_bindings WHERE trace_id NOT IN (SELECT id FROM generation_traces)")
            try execute("DELETE FROM generation_edges WHERE trace_id NOT IN (SELECT id FROM generation_traces) OR parent_id NOT IN (SELECT id FROM generation_traces)")
        }
    }
}
