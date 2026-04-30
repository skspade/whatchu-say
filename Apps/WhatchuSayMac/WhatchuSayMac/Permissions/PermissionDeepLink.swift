import AppKit
import Foundation

/// macOS Privacy & Security pane deep-links. Used to give the user a
/// one-click "Fix in System Settings…" affordance when whatchu-say can't
/// proceed because of a denied OS permission.
///
/// `accessibility` is detected at app startup when `CGEvent.tapCreate`
/// returns nil (`HotkeySourceError.accessibilityDenied`). `microphone`
/// is detected at first dictation when `AVCaptureDevice.requestAccess`
/// returns false and `AVAudioCapture` throws
/// `AudioCaptureError.permissionDenied`, which the orchestrator turns
/// into `OrchestratorEvent.permissionDenied(kind: .microphone)`.
enum PermissionDeepLink: Sendable, Equatable {
    case accessibility
    case microphone

    /// `x-apple.systempreferences:` URL for the relevant Privacy pane.
    /// Opened via `NSWorkspace.shared.open(_:)`. The two pane anchors
    /// (`Privacy_Accessibility`, `Privacy_Microphone`) are stable across
    /// macOS versions back to 10.14.
    var settingsURL: URL {
        switch self {
        case .accessibility:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        case .microphone:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        }
    }

    /// Label for the menu fix-it button.
    var buttonLabel: String {
        switch self {
        case .accessibility:
            return "Open Privacy & Security → Accessibility…"
        case .microphone:
            return "Open Privacy & Security → Microphone…"
        }
    }

    /// One-line message paired with `lastError` so the user knows what's
    /// being asked of them before they click through.
    var errorMessage: String {
        switch self {
        case .accessibility:
            return "Accessibility access required for the dictation hotkey"
        case .microphone:
            return "Microphone access required to capture your voice"
        }
    }
}

@MainActor
enum PermissionLauncher {
    static func open(_ link: PermissionDeepLink) {
        NSWorkspace.shared.open(link.settingsURL)
    }
}
