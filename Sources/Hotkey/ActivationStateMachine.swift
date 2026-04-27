import Foundation

public struct HotkeyConfig: Sendable, Equatable {
    public let pressHoldThreshold: Duration
    public let doubleTapWindow: Duration

    public init(
        pressHoldThreshold: Duration = .milliseconds(250),
        doubleTapWindow: Duration = .milliseconds(300)
    ) {
        self.pressHoldThreshold = pressHoldThreshold
        self.doubleTapWindow = doubleTapWindow
    }
}

/// Activation state machine for the dictation hotkey.
///
/// Pure logic; no platform deps. Drives transitions among press-and-hold,
/// double-tap-toggle hands-free, and cancellation flows defined in
/// `docs/PRD.md` §6.4.
///
/// **Timer contract**: the FSM assumes single-active-timer semantics. The caller
/// schedules a timer when it sees `.scheduleTimer`, cancels it when it sees
/// `.cancelTimer`, and never delivers a stale `timerExpired` event for a
/// cancelled timer. The platform layer must enforce this (typically via
/// `Task` cancellation per scheduled timer).
public actor ActivationStateMachine {
    private enum State: Sendable, Equatable {
        case idle
        /// Key is held; press-hold-vs-tap not yet decided.
        case pressed
        /// First tap completed; waiting for a second key-down within
        /// `doubleTapWindow` to elevate to hands-free.
        case tapPending
        /// Held past the press-hold threshold; dictating until release or cancel.
        case pressHold
        /// Cancelled while still holding; absorbs the eventual `keyUp`.
        case pressHoldCancelled
        /// Hands-free mode active.
        case handsFree
        /// Hands-free exit pressed; absorbs the trailing `keyUp` so it doesn't
        /// re-trigger a new dictation.
        case handsFreeExiting
    }

    private var state: State = .idle
    private let config: HotkeyConfig

    public init(config: HotkeyConfig = HotkeyConfig()) {
        self.config = config
    }

    public func handle(_ event: HotkeyEvent) -> [HotkeyOutput] {
        switch (state, event) {

        // MARK: idle
        case (.idle, .keyDown):
            state = .pressed
            return [
                .startDictation(mode: .pressHold),
                .scheduleTimer(after: config.pressHoldThreshold),
            ]
        case (.idle, .keyUp), (.idle, .cancelKey), (.idle, .timerExpired):
            return []

        // MARK: pressed
        case (.pressed, .keyDown):
            return []
        case (.pressed, .keyUp):
            state = .tapPending
            return [
                .cancelTimer,
                .scheduleTimer(after: config.doubleTapWindow),
            ]
        case (.pressed, .timerExpired):
            state = .pressHold
            return []
        case (.pressed, .cancelKey):
            state = .pressHoldCancelled
            return [.cancelTimer, .cancelDictation]

        // MARK: tapPending
        case (.tapPending, .keyDown):
            state = .handsFree
            return [.cancelTimer, .promoteToHandsFree]
        case (.tapPending, .keyUp):
            return []
        case (.tapPending, .timerExpired):
            state = .idle
            return [.stopDictation]
        case (.tapPending, .cancelKey):
            state = .idle
            return [.cancelTimer, .cancelDictation]

        // MARK: pressHold
        case (.pressHold, .keyDown), (.pressHold, .timerExpired):
            return []
        case (.pressHold, .keyUp):
            state = .idle
            return [.stopDictation]
        case (.pressHold, .cancelKey):
            state = .pressHoldCancelled
            return [.cancelDictation]

        // MARK: pressHoldCancelled
        case (.pressHoldCancelled, .keyUp):
            state = .idle
            return []
        case (.pressHoldCancelled, .keyDown),
             (.pressHoldCancelled, .cancelKey),
             (.pressHoldCancelled, .timerExpired):
            return []

        // MARK: handsFree
        case (.handsFree, .keyDown):
            state = .handsFreeExiting
            return [.stopDictation]
        case (.handsFree, .keyUp), (.handsFree, .timerExpired):
            return []
        case (.handsFree, .cancelKey):
            state = .idle
            return [.cancelDictation]

        // MARK: handsFreeExiting
        case (.handsFreeExiting, .keyUp):
            state = .idle
            return []
        case (.handsFreeExiting, .keyDown),
             (.handsFreeExiting, .cancelKey),
             (.handsFreeExiting, .timerExpired):
            return []
        }
    }

    public func reset() {
        state = .idle
    }
}
