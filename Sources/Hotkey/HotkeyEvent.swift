import Foundation

public enum HotkeyEvent: Sendable, Equatable {
    case keyDown(at: Date)
    case keyUp(at: Date)
    case cancelKey(at: Date)
    case timerExpired
}
