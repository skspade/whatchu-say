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
}
