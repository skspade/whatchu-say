import Foundation

public enum DictationState: Sendable, Equatable {
    case idle
    case capturing(started: Date, mode: CaptureMode)
    case finalizing
    case cancelled
    case errored(String)
}

public enum CaptureMode: Sendable, Equatable {
    case pressHold
    case handsFree
}
