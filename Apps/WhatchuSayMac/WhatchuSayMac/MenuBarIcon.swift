import AppKit
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
    case .preparingProvider: return "arrow.triangle.2.circlepath"
    case .needsSetup:     return "key.fill"
    case .startupFailed:  return "exclamationmark.triangle.fill"
    case .idle:
        return state.lastError == nil ? "mic.slash" : "exclamationmark.triangle.fill"
    }
}

func iconTint(for state: AppState) -> Color {
    switch state.status {
    case .preparingProvider, .needsSetup, .startupFailed:
        return .yellow
    case .idle, .listening:
        return state.lastError == nil ? .primary : .yellow
    }
}

/// AppKit peer of `iconTint(for:)` for the `NSStatusBarButton.contentTintColor`
/// path. Returns `nil` for the default (template-image) appearance, or
/// `.systemYellow` for the attention state. Kept structurally parallel to
/// `iconTint(for:)` so the two cannot drift.
func iconTintColor(for state: AppState) -> NSColor? {
    switch state.status {
    case .preparingProvider, .needsSetup, .startupFailed:
        return .systemYellow
    case .idle, .listening:
        return state.lastError == nil ? nil : .systemYellow
    }
}

func statusLabel(for state: AppState) -> String {
    switch state.status {
    case .idle:                       return "Idle"
    case .listening:                  return "Listening…"
    case .preparingProvider:          return "Preparing provider…"
    case .needsSetup:                 return "Set your ElevenLabs API key to begin"
    case .startupFailed(let message): return "Startup failed: \(message)"
    }
}

func setKeyMenuTitle(for state: AppState) -> String {
    switch state.status {
    case .needsSetup: return "Set ElevenLabs API Key…"
    default:          return "Update ElevenLabs API Key…"
    }
}
