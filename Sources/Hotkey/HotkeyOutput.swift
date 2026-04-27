import Foundation

public enum HotkeyOutput: Sendable, Equatable {
    case startDictation(mode: ActivationMode)
    case stopDictation
    case toggleHandsFree
    case cancelDictation
    case discardSpeculativeBuffer
    case scheduleTimer(after: Duration)
    case cancelTimer
}

public enum ActivationMode: Sendable, Equatable {
    case pressHold
    case handsFree
}
