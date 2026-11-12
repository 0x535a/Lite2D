import Foundation
import AppIntents

// Standalone declarations so the CMake metadata pass can extract only these public actions.
struct CompanionQuietFocusFilter: SetFocusFilterIntent {
    static var title: LocalizedStringResource = "focus.intent.title"
    @Parameter(title: "focus.intent.quiet", default: true) var quiet: Bool
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "focus.intent.display") }
    func perform() async throws -> some IntentResult {
        // A notification requests a scoped query of our current filter. It never changes manual pause.
        NotificationCenter.default.post(name: Notification.Name("Lite2D.CompanionFocusChanged"), object: nil)
        DistributedNotificationCenter.default().postNotificationName(Notification.Name("Lite2D.CompanionFocusChanged"), object: nil, userInfo: nil, deliverImmediately: true)
        return .result()
    }
}

enum CompanionExplicitActivity: String, AppEnum {
    case browsing, programming, writing, research, experiment, media, communication, idle, unknown
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "activity.intent.type" }
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .browsing: "activity.browsing", .programming: "activity.programming", .writing: "activity.writing",
        .research: "activity.research", .experiment: "activity.experiment", .media: "activity.media",
        .communication: "activity.communication", .idle: "activity.idle", .unknown: "activity.unknown"]
}
struct CompanionActivityIntent: AppIntent {
    static var title: LocalizedStringResource = "activity.intent.title"
    static var description = IntentDescription("activity.intent.description")
    static var openAppWhenRun = false
    @Parameter(title: "activity.intent.type") var activity: CompanionExplicitActivity
    static func purgeExpiredInput(defaults: UserDefaults? = UserDefaults(suiteName: "local.lite2d.player"), now: Date = Date()) {
        guard let value = defaults?.dictionary(forKey: "CompanionExplicitActivity") else { return }
        guard let id = value["id"] as? String, UUID(uuidString: id) != nil,
              let raw = value["category"] as? String, CompanionExplicitActivity(rawValue: raw) != nil,
              let at = value["at"] as? Double, at.isFinite, at <= now.timeIntervalSince1970 + 30,
              now.timeIntervalSince1970 - at <= 300 else { defaults?.removeObject(forKey: "CompanionExplicitActivity"); return }
    }
    func perform() async throws -> some IntentResult {
        // Only a user-chosen enum and time cross this bridge, never an arbitrary prompt or task.
        UserDefaults(suiteName: "local.lite2d.player")?.set(["id": UUID().uuidString, "category": activity.rawValue, "at": Date().timeIntervalSince1970], forKey: "CompanionExplicitActivity")
        NotificationCenter.default.post(name: Notification.Name("Lite2D.CompanionActivityChanged"), object: nil)
        DistributedNotificationCenter.default().postNotificationName(Notification.Name("Lite2D.CompanionActivityChanged"), object: nil, userInfo: nil, deliverImmediately: true)
        return .result()
    }
}
