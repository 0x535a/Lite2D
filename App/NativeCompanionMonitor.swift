import Foundation

extension NativeCompanionStore {
    func monitorSchema() throws {
        try execute("CREATE TABLE IF NOT EXISTS monitor_previews(id TEXT PRIMARY KEY,payload TEXT NOT NULL,fingerprint TEXT NOT NULL,expires_at TEXT NOT NULL,status TEXT NOT NULL)")
        try execute("CREATE TABLE IF NOT EXISTS monitor_audit_details(audit_id TEXT PRIMARY KEY,actor TEXT,result TEXT)")
        try execute("CREATE TABLE IF NOT EXISTS reflection_outputs(job_id TEXT PRIMARY KEY,memory_id TEXT NOT NULL UNIQUE)")
    }
    private func monitorText(_ value: Any?) -> String {
        if value == nil || value is NSNull { return "" }
        return String(describing: value!)
    }
    private func monitorFields(_ row: CompanionObject, _ keys: [String]) -> [CompanionMonitorField] {
        keys.map { .init(key: $0, value: monitorText(row[$0])) }
    }
    func monitorMetrics(owners: [String]) throws -> [CompanionMonitorMetric] {
        var result: [CompanionMonitorMetric] = []
        for owner in owners {
            let groups: [(String, String)] = [
                ("L0", "SELECT COUNT(*) AS n FROM persona_claims WHERE character_id=? AND status='active'"),
                ("L2", "SELECT COUNT(*) AS n FROM memory_items WHERE owner_character_id=? AND memory_type='event' AND status='active'"),
                ("L3", "SELECT COUNT(*) AS n FROM memory_items WHERE owner_character_id=? AND memory_type IN ('fact','belief','opinion') AND status='active'"),
                ("L4", "SELECT COUNT(*) AS n FROM relations WHERE observer_character_id=? AND status='active'"),
                ("procedural", "SELECT COUNT(*) AS n FROM memory_items WHERE owner_character_id=? AND memory_type IN ('skill','habit','relation') AND status='active'"),
                ("L5", "SELECT COUNT(*) AS n FROM memory_items WHERE owner_character_id=? AND memory_type='reflection' AND status='active'"),
                ("legacy", "SELECT COUNT(*) AS n FROM memory_items WHERE owner_character_id=? AND memory_type='diary' AND status!='deleted'"),
                ("review", "SELECT COUNT(*) AS n FROM memory_items WHERE owner_character_id=? AND status='needs_review'"),
                ("reflection_pending", "SELECT COUNT(*) AS n FROM reflection_jobs WHERE owner_character_id=? AND status='preview'"),
                ("growth_pending", "SELECT COUNT(*) AS n FROM growth_jobs WHERE owner=? AND status='preview'")]
            for (key, sql) in groups { result.append(.init(owner: owner, key: key, count: try rows(sql, [owner]).first?["n"] as? Int ?? 0)) }
        }
        return result
    }
    func monitorMemory(_ row: CompanionObject) throws -> CompanionMonitorItem {
        let id = monitorText(row["id"]), owner = monitorText(row["owner_character_id"]), status = monitorText(row["status"])
        var all = row
        if let details = try rows("SELECT * FROM memory_details WHERE memory_id=?", [id]).first { all.merge(details, uniquingKeysWith: { _, new in new }) }
        var item = CompanionMonitorItem(id: id, kind: "memory", owner: owner, title: String(monitorText(row["content"]).prefix(90)))
        item.content = status == "deleted" ? "" : monitorText(row["content"])
        item.status = status; item.memoryType = monitorText(row["memory_type"]); item.source = monitorText(row["provenance"])
        item.at = monitorText(row["created_at"]); item.version = monitorText(row["revision"])
        let parser = ISO8601DateFormatter(), now = Date()
        let from = (all["valid_from"] as? String).flatMap(parser.date), to = (all["valid_to"] as? String).flatMap(parser.date)
        all["validity"] = from.map { $0 > now } == true ? "future" : (to.map { $0 <= now } == true ? "expired" : "current")
        if status != "deleted" {
            item.fields = monitorFields(all, ["scope", "occurred_at", "learned_at", "recorded_at", "updated_at", "valid_from", "valid_to", "validity", "confidence", "salience", "created_by", "source_actor_id", "event_id", "source_ref"])
            let subjects = (all["subject_ids"] as? String)?.data(using: .utf8).flatMap { try? NativeCompanionData.decode($0) } as? [String] ?? []
            item.fields.append(.init(key: "subjects", value: subjects.joined(separator: ", ")))
            item.links = evidenceIDs(row).map { .init(id: $0) }
            if let predecessor = row["supersedes_id"] as? String { item.links.append(.init(id: predecessor, kind: "memory")) }
            for child in try rows("SELECT id FROM memory_items WHERE supersedes_id=? AND owner_character_id=?", [id, owner]) { item.links.append(.init(id: monitorText(child["id"]), kind: "memory")) }
            if status == "active" { item.actions = ["correct", "archive", "forget"] }
            else if status == "archived" { item.actions = ["restore", "forget"] }
            else { item.actions = ["forget"] }
        }
        return item
    }
    private func monitorJob(_ row: CompanionObject, kind: String) throws -> CompanionMonitorItem {
        let owner = monitorText(row[kind == "reflection" ? "owner_character_id" : "owner"])
        var item = CompanionMonitorItem(id: monitorText(row["id"]), kind: kind, owner: owner, title: kind == "reflection" ? "reflection" : monitorText(row["field"]))
        item.status = monitorText(row["status"]); item.at = monitorText(row["created_at"]); item.source = "inferred"
        item.content = monitorText(row[kind == "reflection" ? "proposed_content" : "reason"])
        item.links = evidenceIDs(row).map { .init(id: $0) }
        item.fields = monitorFields(row, ["target", "field", "old_value", "new_value", "base_revision", "updated_at"])
        if item.status == "preview" { item.actions = ["approve", "cancel"] }
        if item.status == "committed" {
            if kind == "growth" { item.actions = ["rollback"] }
            else if let output = try rows("SELECT memory_id FROM reflection_outputs WHERE job_id=?", [item.id]).first?["memory_id"] as? String {
                item.links.append(.init(id: output, kind: "memory")); item.actions = ["rollback"]
            }
        }
        return item
    }
    func monitorReference(owner: String, id: String, kind: String = "reference") throws -> CompanionMonitorItem {
        let cutoff = get("memoryCutoff:\(owner)") as? String ?? ""
        if id.hasPrefix("dialogue:"), let seq = Int(id.dropFirst(9)),
           let row = try rows("SELECT at,payload FROM events WHERE seq=? AND type='utterance' AND at>=?", [seq, cutoff]).first {
            let data = NativeCompanionData.object(try NativeCompanionData.decode(Data((row["payload"] as! String).utf8)))
            if data["characterId"] as? String == owner {
                var item = CompanionMonitorItem(id: id, kind: "event", owner: owner, title: String((data["text"] as? String ?? "").prefix(90)))
                item.content = data["text"] as? String ?? ""; item.at = row["at"] as? String ?? ""; item.source = "experienced"
                return item
            }
        }
        if id.hasPrefix("delivery:"), let row = try rows("SELECT d.*,r.received_at AS at FROM deliveries d JOIN daily_receipts r ON r.delivery_id=d.id WHERE d.id=? AND d.recipient=? AND d.status IN ('delivered','context_consumed') AND r.received_at>=?", [String(id.dropFirst(9)), owner, cutoff]).first {
            var item = CompanionMonitorItem(id: id, kind: "event", owner: owner, title: String((row["text"] as? String ?? "").prefix(90)))
            item.content = row["text"] as? String ?? ""; item.at = row["at"] as? String ?? ""; item.source = "told_by_other"
            return item
        }
        if kind == "public", let row = try? readRecord(id), row["exists"] as? Bool == true {
            var item = CompanionMonitorItem(id: id, kind: "public", owner: "", title: id)
            item.content = monitorText(row["content"]); item.version = monitorText(row["revision"]); item.actions = ["public_edit"]; return item
        }
        if kind == "persona", let row = try rows("SELECT * FROM persona_revisions WHERE id=? AND character_id=?", [id, owner]).first { return monitorPersona(row) }
        if let row = try rows("SELECT * FROM reflection_jobs WHERE id=? AND owner_character_id=?", [id, owner]).first { return try monitorJob(row, kind: "reflection") }
        if let row = try rows("SELECT * FROM growth_jobs WHERE id=? AND owner=?", [id, owner]).first { return try monitorJob(row, kind: "growth") }
        if kind == "reference", let row = try rows("SELECT * FROM persona_revisions WHERE id=? AND character_id=?", [id, owner]).first { return monitorPersona(row) }
        if let row = try rows("SELECT * FROM memory_items WHERE id=? AND owner_character_id=?", [id, owner]).first { return try monitorMemory(row) }
        if let row = try rows("SELECT * FROM world_events WHERE id=? AND EXISTS (SELECT 1 FROM memory_items m JOIN memory_dependencies d ON m.id=d.memory_id WHERE m.owner_character_id=? AND d.evidence_id=world_events.id)", [id, owner]).first {
            var item = CompanionMonitorItem(id: id, kind: "reference", owner: owner, title: monitorText(row["event_type"]))
            item.source = monitorText(row["source_kind"]); item.fields = monitorFields(row, ["synthetic", "happened_at", "created_at"]); return item
        }
        if try rows("SELECT 1 FROM memory_items m JOIN memory_details d ON m.id=d.memory_id WHERE d.event_id=? AND m.owner_character_id=? AND m.status='deleted'", [id, owner]).first != nil {
            return .init(id: id, kind: "reference", owner: owner, title: "deleted", status: "deleted")
        }
        if let row = try rows("SELECT * FROM deliveries WHERE id=? AND (sender=? OR recipient=?)", [id, owner, owner]).first {
            var item = CompanionMonitorItem(id: id, kind: "delivery", owner: owner, title: "delivery")
            item.content = monitorText(row["text"]); item.status = monitorText(row["status"]); item.fields = monitorFields(row, ["sender", "recipient", "topic", "at"]); return item
        }
        return .init(id: id, kind: "reference", owner: owner, title: "unavailable", status: "unavailable")
    }
    private func monitorPersona(_ row: CompanionObject) -> CompanionMonitorItem {
        var item = CompanionMonitorItem(id: monitorText(row["id"]), kind: "persona", owner: monitorText(row["character_id"]), title: "persona_revision")
        item.content = monitorText(row["markdown"]); item.version = monitorText(row["revision"]); item.source = monitorText(row["source_kind"]); item.at = monitorText(row["created_at"])
        item.fields = monitorFields(row, ["actor", "raw_hash", "base_hash"])
        let current = try? monitorPersonaFile(item.owner)
        let latest = try? latestPersona(characterID: item.owner)
        item.status = latest?["id"] as? String == item.id && current == item.content ? "current_revision" : "historical_revision"
        item.actions = current == item.content ? [] : ["persona_restore"]
        return item
    }
    func monitorPage(_ input: CompanionMonitorQuery, requestID: String, owners: [String]) throws -> CompanionMonitorPage {
        var q = input; q.page = min(max(0, q.page), 10_000_000); q.pageSize = min(max(q.pageSize, 1), 100)
        var result = CompanionMonitorPage(requestID: requestID, query: q, items: [], total: 0)
        if !q.detailID.isEmpty { result.detail = try monitorReference(owner: q.detailOwner.isEmpty ? q.owner : q.detailOwner, id: q.detailID, kind: q.detailKind) }
        if ["overview", "role_overview"].contains(q.section) {
            result.metrics = try monitorMetrics(owners: q.owner.isEmpty ? owners : [q.owner]); return result
        }
        var sql = "", args: [Any?] = [], mapper: ((CompanionObject) throws -> CompanionMonitorItem)?
        if ["L2", "L3", "L4", "L5", "legacy"].contains(q.section) {
            let types = ["L2": ["event"], "L3": ["fact", "belief", "opinion"], "L4": ["skill", "habit", "relation"], "L5": ["reflection"], "legacy": ["diary"]][q.section]!
            sql = "SELECT m.* FROM memory_items m LEFT JOIN memory_details d ON d.memory_id=m.id WHERE m.owner_character_id=? AND m.memory_type IN (" + types.map { _ in "?" }.joined(separator: ",") + ")"
            args = [q.owner]; args.append(contentsOf: types)
            if !q.status.isEmpty { sql += " AND m.status=?"; args.append(q.status) }
            if !q.memoryType.isEmpty { sql += " AND m.memory_type=?"; args.append(q.memoryType) }
            if !q.source.isEmpty { sql += " AND m.provenance=?"; args.append(q.source) }
            if !q.search.isEmpty { sql += " AND m.status!='deleted' AND m.content LIKE ?"; args.append("%" + q.search + "%") }
            let now = NativeCompanionData.iso()
            if q.validity == "future" { sql += " AND julianday(d.valid_from)>julianday(?)"; args.append(now) }
            if q.validity == "expired" { sql += " AND julianday(d.valid_to)<=julianday(?)"; args.append(now) }
            if q.validity == "current" { sql += " AND (d.valid_from IS NULL OR julianday(d.valid_from)<=julianday(?)) AND (d.valid_to IS NULL OR julianday(d.valid_to)>julianday(?))"; args += [now, now] }
            if !q.from.isEmpty { sql += " AND m.created_at>=?"; args.append(q.from) }
            if !q.to.isEmpty { sql += " AND m.created_at<=?"; args.append(q.to + (q.to.count == 10 ? "T23:59:59Z" : "")) }
            let order = q.sort == "oldest" ? "ASC" : "DESC"
            let count = try rows("SELECT COUNT(*) AS n FROM (" + sql + ")", args).first?["n"] as? Int ?? 0
            result.total = count
            result.items = try rows(sql + " ORDER BY m.created_at \(order),m.rowid \(order) LIMIT ? OFFSET ?", args + [q.pageSize, q.page * q.pageSize]).map(monitorMemory)
            // Relations and review jobs are independently paged, not mixed with a page of memories.
            return result
        }
        switch q.section {
        case "traits":
            result.items = try rows("SELECT t.* FROM traits t WHERE owner=? AND NOT EXISTS (SELECT 1 FROM growth_jobs g WHERE g.owner=t.owner AND g.field=t.field AND g.target IS NULL AND g.status='needs_review')", [q.owner]).map { row in
                var item = CompanionMonitorItem(id: monitorText(row["field"]), kind: "trait", owner: q.owner, title: monitorText(row["field"]))
                item.fields = monitorFields(row, ["value", "revision"])
                return item
            }; result.total = result.items.count; return result
        case "relations":
            sql = "SELECT * FROM relations WHERE observer_character_id=?"; args = [q.owner]
            mapper = { row in
                var item = CompanionMonitorItem(id: self.monitorText(row["id"]), kind: "relation", owner: q.owner, title: self.monitorText(row["target_character_id"]))
                item.status = self.monitorText(row["status"]); item.content = self.monitorText(row["impression"])
                item.version = self.monitorText(row["revision"]); item.at = self.monitorText(row["updated_at"])
                item.fields = self.monitorFields(row, ["target_character_id", "role", "trust", "familiarity", "closeness", "seed_batch_id"])
                item.links = self.evidenceIDs(row).map { .init(id: $0) }
                item.links += try self.rows("SELECT id FROM growth_jobs WHERE owner=? AND target=? ORDER BY created_at DESC LIMIT 30", [q.owner, row["target_character_id"]]).map { .init(id: self.monitorText($0["id"]), kind: "growth") }
                return item
            }
        case "reflections", "growth":
            let reflection = q.section == "reflections"
            sql = "SELECT * FROM \(reflection ? "reflection_jobs" : "growth_jobs") WHERE \(reflection ? "owner_character_id" : "owner")=?"; args = [q.owner]
            if !q.status.isEmpty { sql += " AND status=?"; args.append(q.status) }
            if !q.search.isEmpty { sql += " AND \(reflection ? "proposed_content" : "reason") LIKE ?"; args.append("%\(q.search)%") }
            mapper = { try self.monitorJob($0, kind: reflection ? "reflection" : "growth") }
        case "L0":
            sql = "SELECT * FROM persona_revisions WHERE character_id=?"; args = [q.owner]; mapper = monitorPersona
        case "views":
            var items = try rows("SELECT * FROM persona_views WHERE character_id=?", [q.owner]).map { row -> CompanionMonitorItem in
                var item = CompanionMonitorItem(id: monitorText(row["view_kind"]), kind: "view", owner: q.owner, title: monitorText(row["view_kind"]))
                item.content = monitorText(row["content"]); item.source = "controller_generated"; item.version = monitorText(row["identity_revision"])
                item.at = monitorText(row["generated_at"]); return item
            }
            if let raw = try monitorPersonaFile(q.owner) {
                var item = CompanionMonitorItem(id: "user_file", kind: "view", owner: q.owner, title: "user_file"); item.content = raw; item.source = "user_persona_edit"; items.insert(item, at: 0)
            }
            for claim in try personaClaims(characterID: q.owner) {
                var item = CompanionMonitorItem(id: "claim:" + monitorText(claim["field"]), kind: "claim", owner: q.owner, title: monitorText(claim["field"]))
                item.content = monitorText(claim["value"]); item.source = monitorText(claim["provenance"]); item.status = monitorText(claim["status"])
                item.fields = monitorFields(claim, ["kind", "confidence", "lock_level"]); items.append(item)
            }
            result.items = items; result.total = items.count; return result
        case "public":
            sql = "SELECT r.*,c.actor,c.at FROM records r LEFT JOIN changes c ON c.id=(SELECT MAX(x.id) FROM changes x WHERE x.path=r.path) WHERE 1=1"
            if !q.search.isEmpty { sql += " AND (r.path LIKE ? OR r.content LIKE ?)"; args = ["%\(q.search)%", "%\(q.search)%"] }
            mapper = { row in
                var item = CompanionMonitorItem(id: self.monitorText(row["path"]), kind: "public", owner: "", title: self.monitorText(row["path"]))
                item.content = self.monitorText(row["content"]); item.version = self.monitorText(row["revision"]); item.fields = self.monitorFields(row, ["actor", "at"]); item.actions = ["public_edit"]; return item
            }
        case "audit":
            sql = "SELECT * FROM (SELECT m.*,d.actor,d.result FROM memory_audit m LEFT JOIN monitor_audit_details d ON d.audit_id=m.id UNION ALL SELECT 'public:'||CAST(id AS TEXT),'','public.record.changed',path,at,actor,'completed' FROM changes) WHERE 1=1"
            if !q.owner.isEmpty { sql += " AND (owner=? OR actor=?)"; args += [q.owner, q.owner] }
            if !q.search.isEmpty { sql += " AND (operation LIKE ? OR target LIKE ?)"; args += ["%\(q.search)%", "%\(q.search)%"] }
            mapper = { row in
                var item = CompanionMonitorItem(id: self.monitorText(row["id"]), kind: "audit", owner: self.monitorText(row["owner"]), title: self.monitorText(row["operation"]))
                item.at = self.monitorText(row["at"]); item.fields = self.monitorFields(row, ["target", "actor", "result"])
                let operation = self.monitorText(row["operation"])
                item.links = [.init(id: self.monitorText(row["target"]), kind: operation.contains("public") ? "public" : (operation.contains("persona") ? "persona" : "reference"))]; return item
            }
        case "conversation":
            sql = "SELECT * FROM (SELECT CAST(seq AS TEXT) AS id,at,type,payload FROM events WHERE type IN ('utterance','error','topic.start','topic.end') UNION ALL SELECT id,at,'delivery' AS type,json_object('text',text,'characterId',sender,'to',recipient,'status',status,'topicId',topic) AS payload FROM deliveries) WHERE 1=1"
            if !q.owner.isEmpty { sql += " AND (json_extract(payload,'$.characterId')=? OR json_extract(payload,'$.to')=?)"; args += [q.owner, q.owner] }
            if !q.memoryType.isEmpty { sql += " AND type=?"; args.append(q.memoryType) }
            if !q.search.isEmpty { sql += " AND payload LIKE ?"; args.append("%\(q.search)%") }
            if !q.from.isEmpty { sql += " AND at>=?"; args.append(q.from) }
            if !q.to.isEmpty { sql += " AND at<=?"; args.append(q.to + "T23:59:59Z") }
            mapper = { row in
                let payload = NativeCompanionData.object((row["payload"] as? String)?.data(using: .utf8).flatMap { try? NativeCompanionData.decode($0) })
                var item = CompanionMonitorItem(id: self.monitorText(row["id"]), kind: self.monitorText(row["type"]), owner: self.monitorText(payload["characterId"]), title: self.monitorText(row["type"]))
                item.content = self.monitorText(payload["text"] ?? payload["message"]); item.at = self.monitorText(row["at"]); item.status = self.monitorText(payload["status"])
                item.fields = self.monitorFields(payload, ["to", "topicId", "reason"])
                if item.kind == "delivery" { item.links = try self.rows("SELECT m.id FROM memory_items m JOIN memory_details d ON m.id=d.memory_id WHERE d.event_id=? AND m.owner_character_id=?", [item.id, item.owner]).map { .init(id: self.monitorText($0["id"]), kind: "memory") } }
                return item
            }
        default: return result
        }
        result.total = try rows("SELECT COUNT(*) AS n FROM (" + sql + ")", args).first?["n"] as? Int ?? 0
        let orderColumn = ["public": "path", "audit": "at", "conversation": "at", "relations": "updated_at", "L0": "revision"][q.section] ?? "created_at"
        let direction = q.sort == "oldest" ? "ASC" : "DESC"
        let tie = q.section == "public" || q.section == "L0" ? "" : ",id " + direction
        result.items = try rows(sql + " ORDER BY \(orderColumn) \(direction)\(tie) LIMIT ? OFFSET ?", args + [q.pageSize, q.page * q.pageSize]).map { try mapper!($0) }
        return result
    }
    func monitorPersonaFile(_ owner: String) throws -> String? {
        guard NativeCompanionData.validID(owner) else { throw NativeCompanionData.error("Invalid character") }
        let directory = root.appendingPathComponent("characters/\(owner)")
        let file = directory.appendingPathComponent("persona.md")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        for url in [root.appendingPathComponent("characters"), directory, file] {
            guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw NativeCompanionData.error("Invalid Persona path") }
        }
        guard try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max <= 65536 else { throw NativeCompanionData.error("Persona exceeds 64 KB") }
        return try String(contentsOf: file, encoding: .utf8)
    }
}

extension NativeCompanionStore {
    func monitorAffected(owner: String, id: String) throws -> [String] {
        var seen: Set<String> = [id], pending = [id]
        while !pending.isEmpty {
            let next = pending.removeFirst()
            let rows = try self.rows("SELECT m.id FROM memory_items m JOIN memory_dependencies d ON d.memory_id=m.id WHERE d.evidence_id=? AND m.owner_character_id=? UNION SELECT id FROM memory_items WHERE supersedes_id=? AND owner_character_id=? UNION SELECT supersedes_id AS id FROM memory_items WHERE id=? AND owner_character_id=?", [next, owner, next, owner, next, owner])
            for row in rows { if let value = row["id"] as? String, seen.insert(value).inserted { pending.append(value) } }
        }
        return seen.sorted()
    }
    private func monitorTarget(_ action: CompanionMonitorAction) throws -> CompanionObject {
        switch action.kind {
        case "memory": return try rows("SELECT * FROM memory_items WHERE id=? AND owner_character_id=?", [action.target, action.owner]).first ?? [:]
        case "reflection": return try rows("SELECT * FROM reflection_jobs WHERE id=? AND owner_character_id=?", [action.target, action.owner]).first ?? [:]
        case "growth": return try rows("SELECT * FROM growth_jobs WHERE id=? AND owner=?", [action.target, action.owner]).first ?? [:]
        case "persona": return try rows("SELECT * FROM persona_revisions WHERE id=? AND character_id=?", [action.target, action.owner]).first ?? [:]
        case "public": return try readRecord(action.target)
        default: return [:]
        }
    }
    private func monitorFingerprint(_ action: CompanionMonitorAction) throws -> String {
        let row = try monitorTarget(action)
        guard !row.isEmpty else { throw NativeCompanionData.error("Item is unavailable; refresh the page") }
        let dependencies = try rows("SELECT id,status,revision,updated_at FROM memory_items WHERE owner_character_id=? ORDER BY id", [action.owner])
        let fileHash = action.kind == "persona" ? NativeCompanionData.hash(try monitorPersonaFile(action.owner) ?? "") : ""
        return NativeCompanionData.hash(NativeCompanionData.string(["target": row, "dependencies": dependencies, "personaFile": fileHash, "latestPersona": try latestPersona(characterID: action.owner) ?? [:]]))
    }
    func monitorPreview(_ action: CompanionMonitorAction) throws -> CompanionMonitorPlan {
        try transaction {
            let row = try monitorTarget(action), status = row["status"] as? String ?? ""
            guard !row.isEmpty, status != "deleted" else { throw NativeCompanionData.error("Item was deleted or is unavailable") }
            if ["correct", "public_edit"].contains(action.operation) {
                guard !action.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, action.content.utf8.count <= 32768, !action.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw NativeCompanionData.error("Provide content and a correction reason (maximum 32 KB)") }
            }
            let allowed: [String: [String]] = ["memory": ["correct", "archive", "restore", "forget"], "reflection": ["approve", "cancel", "rollback"], "growth": ["approve", "cancel", "rollback"], "persona": ["persona_restore"], "public": ["public_edit"]]
            guard allowed[action.kind]?.contains(action.operation) == true else { throw NativeCompanionData.error("Unsupported management operation") }
            if ["correct", "archive"].contains(action.operation), status != "active" { throw NativeCompanionData.error("Only active memories support this operation") }
            if action.operation == "restore", status != "archived" { throw NativeCompanionData.error("Only archived memories can be restored") }
            if ["approve", "cancel"].contains(action.operation), status != "preview" { throw NativeCompanionData.error("Proposal has already changed") }
            if action.operation == "rollback", status != "committed" { throw NativeCompanionData.error("Only committed proposals can be rolled back") }
            if action.operation == "persona_restore", try monitorPersonaFile(action.owner) == row["markdown"] as? String {
                throw NativeCompanionData.error("This Persona is already current; there is no change to restore")
            }
            var ids: [String] = []
            if action.kind == "memory" { ids = try monitorAffected(owner: action.owner, id: action.target) }
            if action.kind == "reflection", action.operation == "rollback" {
                guard let output = try rows("SELECT memory_id FROM reflection_outputs WHERE job_id=?", [action.target]).first?["memory_id"] as? String else { throw NativeCompanionData.error("This legacy job has no recorded output link; inspect its memories instead") }
                ids = try monitorAffected(owner: action.owner, id: output)
            }
            var before = (action.kind == "persona" ? try monitorPersonaFile(action.owner) : nil) ?? row["content"] as? String ?? row["proposed_content"] as? String ?? row["reason"] as? String ?? row["markdown"] as? String ?? ""
            var after = action.operation == "persona_restore" ? row["markdown"] as? String ?? "" : action.content
            if action.kind == "growth", ["approve", "rollback"].contains(action.operation) {
                let previous = monitorText(row["field"]) + ": " + monitorText(row["old_value"])
                let proposed = monitorText(row["field"]) + ": " + monitorText(row["new_value"])
                before = action.operation == "rollback" ? proposed : previous
                after = action.operation == "rollback" ? previous : proposed
            }
            let plan = CompanionMonitorPlan(id: UUID().uuidString, action: action, before: before, after: after, affected: ids.map { .init(id: $0, kind: "memory") }, expiresAt: NativeCompanionData.iso(Date().addingTimeInterval(300)))
            try execute("INSERT INTO monitor_previews VALUES (?,?,?,?,?)", [plan.id, String(data: try JSONEncoder().encode(plan), encoding: .utf8)!, try monitorFingerprint(action), plan.expiresAt, "preview"])
            // Old previews may contain text; retain only current, bounded pending drafts.
            try execute("DELETE FROM monitor_previews WHERE expires_at<? OR status!='preview'", [NativeCompanionData.iso()])
            return plan
        }
    }
    private func monitorReviewDependents(owner: String, id: String) throws {
        for dependent in try monitorAffected(owner: owner, id: id) where dependent != id {
            try execute("UPDATE memory_items SET status='needs_review',revision=revision+1,updated_at=? WHERE id=? AND status='active'", [NativeCompanionData.iso(), dependent])
        }
        for job in try rows("SELECT * FROM reflection_jobs WHERE owner_character_id=? AND status IN ('preview','committed')", [owner]) where evidenceIDs(job).contains(id) {
            try execute("UPDATE reflection_jobs SET status='needs_review',updated_at=? WHERE id=?", [NativeCompanionData.iso(), job["id"]])
        }
        for job in try rows("SELECT * FROM growth_jobs WHERE owner=? AND status IN ('preview','committed')", [owner]) where evidenceIDs(job).contains(id) {
            if job["status"] as? String == "committed" {
                do { _ = try rollbackGrowth(owner: owner, jobID: job["id"] as? String ?? "") }
                catch { if let target = job["target"] as? String { try execute("UPDATE relations SET status='needs_review' WHERE observer_character_id=? AND target_character_id=?", [owner, target]) } }
            }
            try execute("UPDATE growth_jobs SET status='needs_review',updated_at=? WHERE id=?", [NativeCompanionData.iso(), job["id"]])
        }
    }
    func monitorCommit(_ planID: String) throws -> CompanionMonitorAction {
        var oldPersona: String?, writtenPersona: String?, personaFile: URL?
        do {
            return try transaction {
                guard let record = try rows("SELECT * FROM monitor_previews WHERE id=? AND status='preview' AND expires_at>?", [planID, NativeCompanionData.iso()]).first,
                      let encoded = record["payload"] as? String, let bytes = encoded.data(using: .utf8) else { throw NativeCompanionData.error("Preview expired or was already submitted; preview again") }
                let plan = try JSONDecoder().decode(CompanionMonitorPlan.self, from: bytes), a = plan.action
                guard try monitorFingerprint(a) == record["fingerprint"] as? String else { throw NativeCompanionData.error("The item or its evidence changed; refresh and merge before submitting") }
                let row = try monitorTarget(a)
                switch a.operation {
                case "correct":
                    let result = try memoryCorrect(a.target, owner: a.owner, content: a.content, expectedRevision: row["revision"] as? Int ?? 0, reason: a.reason)
                    guard result["conflict"] as? Bool != true else { throw NativeCompanionData.error("Memory version conflict") }
                case "forget":
                    _ = try forgetMemory(a.target, owner: a.owner)
                case "archive":
                    try monitorReviewDependents(owner: a.owner, id: a.target)
                    try execute("UPDATE memory_items SET status='archived',revision=revision+1,updated_at=? WHERE id=? AND owner_character_id=?", [NativeCompanionData.iso(), a.target, a.owner])
                case "restore":
                    for evidence in evidenceIDs(row) {
                        if let source = try rows("SELECT status FROM memory_items WHERE id=?", [evidence]).first { guard source["status"] as? String == "active" else { throw NativeCompanionData.error("A required source is no longer active") } }
                    }
                    guard !(try memoryDetails([row])).isEmpty else { throw NativeCompanionData.error("Memory is expired or not yet effective") }
                    try execute("UPDATE memory_items SET status='active',revision=revision+1,updated_at=? WHERE id=? AND owner_character_id=?", [NativeCompanionData.iso(), a.target, a.owner])
                case "approve":
                    if a.kind == "reflection" { _ = try commitReflection(owner: a.owner, jobID: a.target) }
                    else { _ = try commitGrowth(owner: a.owner, jobID: a.target) }
                case "cancel":
                    if a.kind == "reflection" { _ = try cancelReflection(owner: a.owner, jobID: a.target) }
                    else { try execute("UPDATE growth_jobs SET status='cancelled',updated_at=? WHERE id=? AND owner=?", [NativeCompanionData.iso(), a.target, a.owner]) }
                case "rollback":
                    if a.kind == "reflection" {
                        guard let output = try rows("SELECT memory_id FROM reflection_outputs WHERE job_id=?", [a.target]).first?["memory_id"] as? String else { throw NativeCompanionData.error("Reflection output is unavailable") }
                        try monitorReviewDependents(owner: a.owner, id: output)
                        try execute("UPDATE memory_items SET status='archived',revision=revision+1,updated_at=? WHERE id=?", [NativeCompanionData.iso(), output])
                        try execute("UPDATE reflection_jobs SET status='rolled_back',updated_at=? WHERE id=?", [NativeCompanionData.iso(), a.target])
                    } else { _ = try rollbackGrowth(owner: a.owner, jobID: a.target) }
                case "persona_restore":
                    oldPersona = try monitorPersonaFile(a.owner)
                    let markdown = row["markdown"] as? String ?? ""
                    guard !markdown.isEmpty else { throw NativeCompanionData.error("Persona revision has no source text") }
                    _ = try ingestPersona(characterID: a.owner, markdown: markdown)
                    let file = root.appendingPathComponent("characters/\(a.owner)/persona.md")
                    try markdown.write(to: file, atomically: true, encoding: .utf8)
                    personaFile = file; writtenPersona = markdown
                    try execute("DELETE FROM persona_views WHERE character_id=?", [a.owner])
                case "public_edit":
                    let result = try updateRecord(actor: "user", name: a.target, content: a.content, revision: row["revision"] as? String)
                    guard result["conflict"] as? Bool != true else { throw NativeCompanionData.error("Public record version conflict") }
                default: throw NativeCompanionData.error("Unknown management operation")
                }
                if !a.owner.isEmpty {
                    try dailyInvalidate(a.owner)
                    try set("sessionPolicy:\(a.owner)", "memory-invalidated")
                    try set("memoryCutoff:\(a.owner)", NativeCompanionData.iso())
                    try execute("DELETE FROM persona_views WHERE character_id=?", [a.owner])
                    try? FileManager.default.removeItem(at: root.appendingPathComponent("characters/\(a.owner)/persona.generated.md"))
                }
                try audit(owner: a.owner, operation: "user." + a.operation, target: a.target, actor: "user", result: "completed")
                try execute("UPDATE monitor_previews SET status='committed',payload='' WHERE id=?", [planID])
                // Any pending preview can contain now-forgotten text; discard drafts on mutation.
                try execute("DELETE FROM monitor_previews WHERE status='preview'")
                return a
            }
        } catch {
            if let file = personaFile, let old = oldPersona, (try? String(contentsOf: file, encoding: .utf8)) == writtenPersona { try? old.write(to: file, atomically: true, encoding: .utf8) }
            throw error
        }
    }
}
