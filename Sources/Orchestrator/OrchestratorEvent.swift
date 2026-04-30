import Foundation
import Hotkey

/// Lifecycle events emitted by `Orchestrator` for UI consumers (HUD, menu
/// bar, future analytics). Independent of the lower-level `SttEvent`: the
/// orchestrator filters and reshapes provider events here so consumers don't
/// have to know about retries, EOS handshakes, or session swaps on
/// hands-free promotion.
public enum OrchestratorEvent: Sendable, Equatable {
    /// A new dictation session has opened in the given mode. Emitted after
    /// the provider's session is ready, before any audio flows.
    case sessionStarted(mode: ActivationMode)

    /// Latest interim transcript from the provider. May fire many times per
    /// session, including with the same text on consecutive ticks.
    case partial(text: String)

    /// EOS has been sent and the orchestrator is awaiting the final
    /// transcript. The HUD should switch to a "wrapping up" state.
    case finalizing

    /// Session is closed. `injectedText` is the text passed to the injector,
    /// or `nil` if the session was cancelled / produced an empty final.
    case sessionEnded(injectedText: String?)

    /// Non-fatal warning surfaced from the provider (e.g. transient network
    /// hiccup, server-side error message). The session may or may not still
    /// be alive — UIs should treat this as informational unless followed by
    /// a `.sessionEnded`.
    case error(text: String)

    /// A required platform permission was denied at the OS level. Emitted
    /// when audio capture refuses to start because the user said no to the
    /// mic prompt (or the host is missing the entitlement). UI consumers
    /// should surface a one-click fix-it affordance pointing at the
    /// platform's settings UI.
    case permissionDenied(kind: PermissionKind)
}

/// Cross-platform identifier for runtime-detectable permission denials.
/// Currently only `microphone` — `accessibility` is a Mac-specific
/// hotkey-tap concern detected at startup outside the orchestrator.
public enum PermissionKind: Sendable, Equatable {
    case microphone
}
