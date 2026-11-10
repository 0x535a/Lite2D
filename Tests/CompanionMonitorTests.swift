import Foundation

enum CompanionMonitorTests {
    static func run(root: URL, check: (Bool, String) throws -> Void) throws {
        let a = "11111111-1111-4111-8111-111111111111", b = "22222222-2222-4222-8222-222222222222"
        let store = try NativeCompanionStore(root: root.appendingPathComponent("monitor"))
        var ids: [String] = []
        for index in 0..<125 { ids.append(try store.memoryWrite(owner: a, type: "fact", provenance: "inferred", content: "memory \(index)")["memoryId"] as! String) }
        _ = try store.memoryWrite(owner: b, type: "fact", content: "another owner's private text")
        var query = CompanionMonitorQuery(); query.owner = a; query.section = "L3"; query.pageSize = 20
        let changes = try store.rows("SELECT total_changes() AS n").first?["n"] as? Int
        let first = try store.monitorPage(query, requestID: "one", owners: [a, b])
        query.page = 1
        let second = try store.monitorPage(query, requestID: "two", owners: [a, b])
        try check(first.total == 125 && first.items.count == 20 && second.items.count == 20 && Set(first.items.map(\.id)).isDisjoint(with: second.items.map(\.id)), "Monitor pages beyond 100 records with complete counts and stable disjoint pages")
        try check(changes == store.rows("SELECT total_changes() AS n").first?["n"] as? Int, "Monitoring reads do not change SQLite state")
        try check(first.items.allSatisfy { $0.owner == a } && (try store.monitorReference(owner: a, id: store.memorySearch(owner: b, query: "")[0]["id"] as! String)).status == "unavailable", "Monitor evidence navigation preserves the selected actor's private scope")
        var action = CompanionMonitorAction(operation: "archive", owner: a, kind: "memory", target: ids[0])
        let archive = try store.monitorPreview(action)
        _ = try store.monitorCommit(archive.id)
        try check((try store.memoryRead(ids[0], owner: a)) == nil && (try store.monitorReference(owner: a, id: ids[0])).content == "memory 0", "Archive exits ordinary recall while preserving inspectable source text")
        action.operation = "restore"
        _ = try store.monitorCommit(store.monitorPreview(action).id)
        try check((try store.memoryRead(ids[0], owner: a)) != nil, "Explicit archive restoration returns valid memory to ordinary recall")
        action.operation = "correct"; action.content = "corrected monitor value"; action.reason = "verified correction"
        let stale = try store.monitorPreview(action)
        _ = try store.memoryCorrect(ids[0], owner: a, content: "concurrent correction", expectedRevision: 3, reason: "other writer")
        var conflict = false
        do { _ = try store.monitorCommit(stale.id) } catch { conflict = true }
        try check(conflict, "Management commit rejects a preview after a concurrent correction")
        let target = ids[1]
        action = .init(operation: "correct", owner: a, kind: "memory", target: target, content: "new corrected content", reason: "source checked")
        _ = try store.monitorCommit(store.monitorPreview(action).id)
        let next = try store.rows("SELECT id FROM memory_items WHERE supersedes_id=?", [target])[0]["id"] as! String
        try check((try store.monitorReference(owner: a, id: target)).status == "superseded" && (try store.monitorReference(owner: a, id: next)).links.contains { $0.id == target }, "Monitor corrections retain explicit navigable predecessor links")
        action = .init(operation: "forget", owner: a, kind: "memory", target: next)
        let forget = try store.monitorPreview(action)
        try check(forget.affected.contains { $0.id == target }, "Forgetting preview includes the correction chain")
        _ = try store.monitorCommit(forget.id)
        try check((try store.monitorReference(owner: a, id: target)).content.isEmpty && (try store.monitorReference(owner: a, id: next)).status == "deleted" && (try store.rows("SELECT * FROM monitor_previews WHERE status='preview'")).isEmpty, "Forgetting removes historical memory text and pending preview drafts")
        var replay = false; do { _ = try store.monitorCommit(forget.id) } catch { replay = true }
        try check(replay, "Management confirmation tokens cannot execute twice")
        let expired = try store.memoryWrite(owner: a, type: "fact", content: "expired but inspectable", validTo: "2020-01-01T00:00:00Z")["memoryId"] as! String
        query.page = 0; query.validity = "expired"
        let expiredPage = try store.monitorPage(query, requestID: "expired", owners: [a])
        try check(expiredPage.total == 1 && expiredPage.items[0].id == expired && (try store.memoryRead(expired, owner: a)) == nil, "Administrative time filtering inspects expired facts without changing ordinary recall")
        _ = try store.recordDirectMemory(owner: a, source: "experienced", eventID: "one", content: "real event one")
        _ = try store.recordDirectMemory(owner: a, source: "experienced", eventID: "two", content: "real event two")
        let job = try store.reflectionPreview(owner: a)[0]["id"] as! String
        let approved = try store.monitorPreview(.init(operation: "approve", owner: a, kind: "reflection", target: job))
        _ = try store.monitorCommit(approved.id)
        let output = try store.rows("SELECT memory_id FROM reflection_outputs WHERE job_id=?", [job])[0]["memory_id"] as! String
        _ = try store.monitorCommit(store.monitorPreview(.init(operation: "rollback", owner: a, kind: "reflection", target: job)).id)
        try check((try store.monitorReference(owner: a, id: output)).status == "archived" && (try store.rows("SELECT status FROM reflection_jobs WHERE id=?", [job])[0]["status"] as? String) == "rolled_back", "Reflection approval records its output and supports audited rollback")
        let directory = store.root.appendingPathComponent("characters/\(a)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let persona1 = "## 我是谁\nFirst identity", persona2 = "## 我是谁\nSecond identity"
        let revision = try store.ingestPersona(characterID: a, markdown: persona1)["revisionId"] as! String
        _ = try store.ingestPersona(characterID: a, markdown: persona2)
        try persona2.write(to: directory.appendingPathComponent("persona.md"), atomically: true, encoding: .utf8)
        let restore = try store.monitorPreview(.init(operation: "persona_restore", owner: a, kind: "persona", target: revision))
        try check(restore.before == persona2 && restore.after == persona1, "Persona restore preview compares current source against the selected historical revision")
        _ = try store.monitorCommit(restore.id)
        try check((try store.latestPersona(characterID: a))?["revision"] as? Int == 3 && (try store.monitorPersonaFile(a)) == persona1, "Persona restore commits a new revision and updates the user file explicitly")
        let currentRevision = try store.latestPersona(characterID: a)!["id"] as! String
        let currentItem = try store.monitorReference(owner: a, id: currentRevision, kind: "persona")
        var noOpRejected = false
        do { _ = try store.monitorPreview(.init(operation: "persona_restore", owner: a, kind: "persona", target: currentRevision)) } catch { noOpRejected = true }
        try check(currentItem.status == "current_revision" && currentItem.actions.isEmpty && noOpRejected, "Current Persona revisions cannot create no-op restoration plans")
        let record = try store.updateRecord(actor: a, name: "shared.md", content: "before")
        let publicPlan = try store.monitorPreview(.init(operation: "public_edit", owner: "", kind: "public", target: "shared.md", content: "after", reason: "approved edit"))
        _ = try store.monitorCommit(publicPlan.id)
        try check((try store.readRecord("shared.md"))["content"] as? String == "after" && record["revision"] as? String != (try store.readRecord("shared.md"))["revision"] as? String, "Public record management composes transactionally with versioned shared notes")
        var auditQuery = CompanionMonitorQuery(); auditQuery.section = "audit"
        try check((try store.monitorPage(auditQuery, requestID: "audit", owners: [a])).total > 125, "Monitor audit totals include actual writes and user management operations")
        for section in ["L0", "views", "relations", "traits", "reflections", "growth", "public", "audit", "conversation"] {
            var q = CompanionMonitorQuery(); q.section = section; q.owner = section == "public" || section == "audit" ? "" : a
            _ = try store.monitorPage(q, requestID: section, owners: [a, b])
        }
        try check(true, "All global and role monitoring query shapes execute against the real schema")
        let protectedPlan = try store.monitorPreview(.init(operation: "archive", owner: a, kind: "memory", target: ids[2]))
        _ = try store.forgetMemory(ids[2], owner: b)
        try check(!(try store.rows("SELECT id FROM monitor_previews WHERE id=?", [protectedPlan.id])).isEmpty, "An unauthorized forget request cannot invalidate another owner's management previews")
        let otherRevision = try store.rows("SELECT id FROM persona_revisions WHERE character_id=? AND revision=2", [a])[0]["id"] as! String
        let personaPlan = try store.monitorPreview(.init(operation: "persona_restore", owner: a, kind: "persona", target: otherRevision))
        try "External editor's draft".write(to: directory.appendingPathComponent("persona.md"), atomically: true, encoding: .utf8)
        var externalConflict = false
        do { _ = try store.monitorCommit(personaPlan.id) } catch { externalConflict = true }
        try check(externalConflict && (try store.monitorPersonaFile(a)) == "External editor's draft", "Persona restoration refuses to overwrite a concurrent external file edit")
        let coded = try CompanionMonitorCoding.object(first)
        try check(try CompanionMonitorCoding.decode(CompanionMonitorPage.self, coded).total == 125, "Typed monitor pages round-trip through the host protocol")
    }
}
