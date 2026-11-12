import Foundation

enum CompanionCognitionTests {
    static func run(root: URL, check: (Bool, String) throws -> Void) throws {
        let owner = "11111111-1111-4111-8111-111111111111", other = "22222222-2222-4222-8222-222222222222"
        let config: CompanionObject = ["model": "fixture/default", "memoryModel": "fixture/archive", "characters": [["id": owner, "model": "fixture/role-a"], ["id": other, "model": ""]]]
        try check(CompanionModelRouting.role(owner, config: config) == "fixture/role-a" && CompanionModelRouting.role(other, config: config) == "fixture/default" && CompanionModelRouting.archive(config: config) == "fixture/archive", "Character and archive tasks route models independently without changing role identity")
        try check(CompanionModelRouting.resetToServiceDefault(requested: "", previous: "fixture/role-a") && !CompanionModelRouting.resetToServiceDefault(requested: "", previous: ""), "Returning to the service default cannot silently retain a previous explicit model")
        var invalid = false
        do { try CompanionModelRouting.validate("unqualified-model") } catch { invalid = true }
        try check(invalid, "Invalid model selectors fail explicitly rather than using an unintended model")
        let now = Date(timeIntervalSince1970: 1794448800)
        var state = CompanionCognitiveState(owner: owner, updatedAt: now)
        state.expression(output: "one", emotion: .happy, at: now)
        let spent = state.expressionEnergy
        state.expression(output: "one", emotion: .happy, at: now)
        try check(state.expressionEnergy == spent && state.affect == .happy, "Duplicate expression feedback cannot spend cognitive energy twice")
        state.advance(to: now.addingTimeInterval(60 * 86400))
        try check(abs(state.expressionEnergy - 0.45) < 0.01 && abs(state.socialInterest - 0.35) < 0.01 && state.affect == .neutral, "Long silence returns to bounded baseline instead of accumulating social debt")
        let stable = state
        state.advance(to: now.addingTimeInterval(-1))
        try check(state == stable, "Clock rollback cannot manufacture cognitive recovery or new emotion")
        let store = try NativeCompanionStore(root: root.appendingPathComponent("cognitive-state"))
        try store.execute("INSERT INTO traits VALUES (?,'curiosity',0.8,1)", [owner])
        let active = try store.maintainCognition(owner: owner, now: now)
        try check(active.curiosity == 0.8 && active.interestPriority > CompanionCognitiveState(owner: other, updatedAt: now).interestPriority, "Approved personality tendencies influence optional opportunity priority")
        try store.saveCognition(active)
        let reopened = try NativeCompanionStore(root: store.root)
        try check(try reopened.cognitiveState(owner: owner) == active && reopened.cognitiveState(owner: other) == nil, "Cognitive continuity survives restart and remains private to its character")
        let changes = try reopened.rows("SELECT total_changes() AS n").first?["n"] as? Int
        var query = CompanionMonitorQuery(); query.owner = owner; query.section = "cognition"
        let page = try reopened.monitorPage(query, requestID: "cognitive-read", owners: [owner, other])
        try check(page.total == 1 && changes == reopened.rows("SELECT total_changes() AS n").first?["n"] as? Int, "Viewing cognitive state neither advances it nor invokes a model")
        try reopened.forgetCharacter(owner)
        try check(try reopened.cognitiveState(owner: owner) == nil, "Clearing a character also removes its independent cognitive state")
    }
}
