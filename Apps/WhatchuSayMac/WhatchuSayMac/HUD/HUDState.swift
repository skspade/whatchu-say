import Foundation
import Observation

/// Observable state backing the dictation HUD. Mutated only by `HUDController`
/// on the main actor; consumed by SwiftUI views.
@MainActor
@Observable
final class HUDState {
    enum Status: Equatable {
        /// No session — panel hidden.
        case hidden
        /// Session opened, no transcript yet.
        case listening
        /// Active session with the latest interim transcript and current
        /// audio level (0..1, RMS-derived).
        case active(partial: String, level: Float)
        /// EOS sent, awaiting final. `lastPartial` is what we'll display
        /// dimmed while we wait.
        case finalizing(lastPartial: String)
        /// Transient error banner. Auto-dismissed by the controller.
        case error(text: String)
    }

    var status: Status = .hidden
}
