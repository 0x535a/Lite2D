import Foundation
import ServiceManagement

final class LaunchAtLogin {
    private let service = SMAppService.mainApp

    // ServiceManagement persists the setting. Read it afresh so changes in
    // System Settings are reflected instead of trusting a separate JSON flag.
    var status: SMAppService.Status { service.status }
    var isRegistered: Bool { status == .enabled || status == .requiresApproval }

    func setEnabled(_ enabled: Bool) async throws {
        if enabled {
            try service.register()
        } else {
            try await service.unregister()
        }
    }

    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }

    // Explicit diagnostic only: exercise the real signed bundle, leave an
    // existing user preference untouched, and remove a temporary registration.
    func checkRegistration() async throws -> [String: String] {
        let original = statusName
        if isRegistered { return ["before": original, "result": "existingPreferencePreserved"] }
        var registrationError: Error?
        do { try await setEnabled(true) } catch { registrationError = error }
        guard isRegistered else {
            throw registrationError ?? LocalizedFailure(message: .key("error.login_register", []))
        }
        let registered = statusName
        try await setEnabled(false)
        guard !isRegistered else {
            throw LocalizedFailure(message: .key("error.login_cleanup", []))
        }
        return ["before": original, "registered": registered, "after": statusName, "result": "registrationAndRemovalPassed"]
    }

    var statusName: String {
        switch status {
        case .notRegistered: return "notRegistered"
        case .enabled: return "enabled"
        case .requiresApproval: return "requiresApproval"
        case .notFound: return "notFound"
        @unknown default: return "unknown"
        }
    }
}
