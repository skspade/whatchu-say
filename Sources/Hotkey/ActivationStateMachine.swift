import Foundation

public struct HotkeyConfig: Sendable {
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

/// State machine for activation logic. Pure logic, no platform deps.
/// Real transition logic lands in the Milestone 1.1 follow-up commit; this stub
/// gives downstream targets a stable type and method signature to wire against.
public actor ActivationStateMachine {
    private enum State: Sendable {
        case idle
        case pressed(downAt: Date)
        case tapPending(firstUpAt: Date)
        case pressHold
        case pressHoldCancelled
        case handsFree
    }

    private var state: State = .idle
    private let config: HotkeyConfig

    public init(config: HotkeyConfig = HotkeyConfig()) {
        self.config = config
    }

    public func handle(_ event: HotkeyEvent) async -> [HotkeyOutput] {
        // TODO: implement transitions per docs/PRD.md §6.4 in follow-up commit.
        return []
    }

    public func reset() async {
        state = .idle
    }
}
