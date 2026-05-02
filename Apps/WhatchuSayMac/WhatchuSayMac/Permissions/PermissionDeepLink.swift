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
    case screenAndSystemAudioRecording

    /// `x-apple.systempreferences:` URL for the relevant Privacy pane.
    /// Opened via `NSWorkspace.shared.open(_:)`.
    var settingsURL: URL {
        switch self {
        case .accessibility:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        case .microphone:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        case .screenAndSystemAudioRecording:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        }
    }

    /// Label for the menu fix-it button.
    var buttonLabel: String {
        switch self {
        case .accessibility:
            return "Open Privacy & Security → Accessibility…"
        case .microphone:
            return "Open Privacy & Security → Microphone…"
        case .screenAndSystemAudioRecording:
            return "Open Privacy & Security → Screen & System Audio Recording…"
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
        case .screenAndSystemAudioRecording:
            return "Screen & System Audio Recording access required to capture meeting audio"
        }
    }
}

@MainActor
enum PermissionLauncher {
    static func open(_ link: PermissionDeepLink) {
        NSWorkspace.shared.open(link.settingsURL)
    }
}
