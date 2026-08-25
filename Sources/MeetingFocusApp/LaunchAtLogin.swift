import ServiceManagement
import Foundation

/// Launch-at-login via `SMAppService.mainApp`.
///
/// This registers the application itself, rather than a separate helper. A background agent was
/// considered and rejected: a second binary needs its own Accessibility grant, doubling the
/// permission friction, and a headless agent cannot explain to the user why it is asking or show
/// that it has stopped working. One menu bar app that launches at login gives the same
/// persistence with half the moving parts.
@MainActor
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// `requiresApproval` is a normal outcome, not an error: macOS shows the item in
    /// Login Items and waits for the user. The caller should surface that rather than retry.
    static var needsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            guard SMAppService.mainApp.status != .enabled else { return }
            try SMAppService.mainApp.register()
        } else {
            guard SMAppService.mainApp.status == .enabled else { return }
            try SMAppService.mainApp.unregister()
        }
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
