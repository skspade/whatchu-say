import SwiftUI

/// Pure presentation helpers for the menu-bar icon and menu strings.
///
/// Take `AppState` (not just `AppState.Status`) so they can also factor in
/// `lastError`: a runtime error during a successful `.listening` session
/// still flips the icon yellow until the next successful inject acknowledges
/// recovery, or the user manually dismisses.
///
/// Internal so unit tests can call them directly without instantiating
/// SwiftUI views.

func iconName(for state: AppState) -> String {
    switch state.status {
    case .listening:      return "mic.fill"
    case .needsSetup:     return "key.fill"
    case .startupFailed:  return "exclamationmark.triangle.fill"
    case .idle:
        return state.lastError == nil ? "mic.slash" : "exclamationmark.triangle.fill"
    }
}

func iconTint(for state: AppState) -> Color {
    switch state.status {
    case .needsSetup, .startupFailed:
        return .yellow
    case .idle, .listening:
        return state.lastError == nil ? .primary : .yellow
    }
}

func statusLabel(for state: AppState) -> String {
    switch state.status {
    case .idle:                       return "Idle"
    case .listening:                  return "Listening…"
    case .needsSetup:                 return "Set your ElevenLabs API key to begin"
    case .startupFailed(let message): return "Startup failed: \(message)"
    }
}

func setKeyMenuTitle(for state: AppState) -> String {
    switch state.status {
    case .needsSetup: return "Set ElevenLabs API Key…"
    default:          return "Update API Key…"
    }
}
