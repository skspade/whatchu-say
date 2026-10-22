import Testing
import Foundation
@testable import Audio
@testable import Hotkey
@testable import Injector
@testable import Orchestrator
@testable import STTCore
@testable import Usage

private let now = Date(timeIntervalSinceReferenceDate: 0)

/// Regression tests for hotkey and timer events interleaving.
///
/// Timer expirations reach the orchestrator from their own Task, not the
/// hotkey consumer. Because applying an event suspends (draining audio,
/// waiting for the committed transcript), actor reentrancy let a key press
/// start a new session in the middle of a timer-driven finalize, which then
/// closed the session the user had just started.
@Suite("Orchestrator: hotkey and timer events run one at a time")
struct OrchestratorCommandOrderingTests {

    @Test("a key press during finalize waits instead of hijacking the finishing session",
          .timeLimit(.minutes(1)))
    func keyDownDuringFinalizeWaitsForIt() async {
        let provider = SilentProvider()
        let injector = FakeInjector()
        let timer = ManualTimerScheduler()
        let orchestrator = Orchestrator(
            provider: provider,
            injector: injector,
            stateMachine: ActivationStateMachine(),
            usage: UsageTracker(),
            audioCapture: FakeAudioCapture(),
            timerScheduler: timer
        )
        let collector = EventCollector()
        await collector.start(stream: orchestrator.events)

        // Single tap: dictation starts, then waits for a possible second tap.
        await orchestrator.handle(hotkeyEvent: .keyDown(at: now))
        await orchestrator.handle(hotkeyEvent: .keyUp(at: now))
        await provider.lastSession?.yieldPartial("first")
        _ = await collector.waitForEvent(.partial(text: "first"))

        // The double-tap window lapses: the timer stops the tap's dictation,
        // which sends EOS and waits on the committed transcript.
        let tapWindowExpired = Task { await timer.fireAll() }
        _ = await collector.waitForEvent(.finalizing)
        while await timer.pendingCount == 0 { await Task.yield() }

        // The user presses again while that dictation is still finalizing.
        let press = Task { await orchestrator.handle(hotkeyEvent: .keyDown(at: now)) }
        for _ in 0..<200 { await Task.yield() }

        // The server never commits; the finalize timeout injects the partial.
        await timer.fireAll()
        await tapWindowExpired.value
        await press.value

        #expect(await injector.received == ["first"])
        #expect(await provider.sessions.count == 2)
        #expect(await orchestrator.isCapturing())
        await collector.cancel()
    }

    @Test("a timer that fires after being cancelled is ignored",
          .timeLimit(.minutes(1)))
    func staleTimerExpiryIsDropped() async {
        let timer = ManualTimerScheduler()
        let orchestrator = Orchestrator(
            provider: ScriptableProvider(),
            injector: FakeInjector(),
            stateMachine: ActivationStateMachine(),
            usage: UsageTracker(),
            audioCapture: FakeAudioCapture(),
            timerScheduler: timer
        )

        await orchestrator.handle(hotkeyEvent: .keyDown(at: now))
        // The press-hold timer's sleep has already elapsed…
        let lateTimers = await timer.takeAll()
        // …but the release cancels it and opens the double-tap window.
        await orchestrator.handle(hotkeyEvent: .keyUp(at: now))
        for action in lateTimers { await action() }

        // Still waiting for a possible second tap: the stale expiry must not
        // have stopped dictation.
        #expect(await orchestrator.isCapturing())
        #expect(await timer.pendingCount == 1)
    }
}
