import Foundation
import ServiceManagement
import os

/// Thin wrapper over `SMAppService.mainApp` for the General pane's
/// "Launch at Login" toggle. Owns no state — every call hits
/// `ServiceManagement` directly. Errors are logged and swallowed; the
/// caller does not need to handle them but the persisted config bit may
/// drift from the system state in the failure case.
///
/// Behaviour matches the modern Login Items API: registration causes the
/// system to launch the app at the next login (and immediately on first
/// register if the user hasn't approved Login Items). Unregistration
/// removes it.
enum LaunchAtLogin {
    private static let log = Logger(subsystem: "com.whatchu-say", category: "config")

    /// Toggle SMAppService registration. Logs and returns silently on error
    /// — surfacing in UI is a future polish.
    static func setEnabled(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            log.error("LaunchAtLogin.setEnabled(\(enabled)) failed: \(String(describing: error))")
        }
    }

    /// Read the current SMAppService registration status. Returns `false`
    /// for any non-`enabled` state (notFound, requiresApproval, notRegistered).
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }
}
