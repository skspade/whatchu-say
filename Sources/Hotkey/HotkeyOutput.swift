import Foundation

/// Outputs emitted by `ActivationStateMachine`. The orchestrator translates these
/// into concrete actions (open STT session, finalize, schedule a timer, etc.).
public enum HotkeyOutput: Sendable, Equatable {
    /// Begin a dictation session in the given mode (orchestrator should open STT
    /// session and start audio capture). Only emitted from the idle → pressed
    /// transition; never re-emitted while a session is already active.
    case startDictation(mode: ActivationMode)

    /// Send EOS, await the final transcript, inject text. Returns FSM to idle.
    case stopDictation

    /// Abort the current session — close STT, discard pending text, no inject.
    case cancelDictation

    /// Double-tap detected: keep the in-flight capture session running, but
    /// discard the speculative audio buffered during the first tap and switch
    /// the orchestrator's mode to hands-free.
    case promoteToHandsFree

    /// Schedule a single-shot timer. The caller is responsible for delivering a
    /// `timerExpired` event when it fires. Only one timer is in flight at a time;
    /// the FSM emits `cancelTimer` before scheduling a new one.
    case scheduleTimer(after: Duration)

    /// Cancel any in-flight timer.
    case cancelTimer
}

public enum ActivationMode: Sendable, Equatable {
    case pressHold
    case handsFree
}
