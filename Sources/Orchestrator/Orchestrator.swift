import Foundation
import Core
import Audio
import STTCore
import Hotkey
import Injector
import Usage

/// Top-level dictation orchestrator. Wires hotkey → audio → STT → injector + usage.
/// Stub: real wiring lands in the Milestone 1.1 follow-up commit.
public actor Orchestrator {
    private let provider: any SttProvider
    private let injector: any Injector
    private let stateMachine: ActivationStateMachine
    private let usage: UsageTracker
    private var state: DictationState = .idle

    public init(
        provider: any SttProvider,
        injector: any Injector,
        stateMachine: ActivationStateMachine,
        usage: UsageTracker
    ) {
        self.provider = provider
        self.injector = injector
        self.stateMachine = stateMachine
        self.usage = usage
    }

    public func handle(hotkeyEvent: HotkeyEvent) async {
        // TODO: dispatch to state machine, react to outputs in follow-up commit.
        _ = await stateMachine.handle(hotkeyEvent)
    }

    public func currentState() -> DictationState {
        state
    }
}
