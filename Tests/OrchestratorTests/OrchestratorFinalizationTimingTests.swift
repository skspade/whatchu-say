import Testing
import Foundation
@testable import Audio
@testable import Hotkey
@testable import Injector
@testable import Orchestrator
@testable import STTCore
@testable import Usage

private let now = Date(timeIntervalSinceReferenceDate: 0)

/// Regression tests for the "recording hangs for ~10 s after key release" bug.
///
/// Root cause: `awaitFinal()` blocked until the session's events stream
/// finished (WebSocket close), even though the committed transcript had
/// already arrived. With `commit_strategy=manual` the server sends exactly
/// one `committed_transcript` in response to the EOS commit; waiting for
/// the WebSocket close added an unnecessary and unpredictable delay.
///
/// These tests use `DelayedCloseSession`, which yields a `.final` on
/// `endOfStream()` but does NOT finish the events stream — simulating a
/// slow WebSocket close. Without the fix, `awaitFinal()` blocks
/// indefinitely and the test times out.
@Suite("Orchestrator: finalization timing (delayed stream close)")
struct OrchestratorFinalizationTimingTests {

    private func makeRig() -> (
        orchestrator: Orchestrator,
        provider: DelayedCloseProvider,
        injector: FakeInjector,
        audio: FakeAudioCapture,
        timer: ManualTimerScheduler
    ) {
        let provider = DelayedCloseProvider()
        let injector = FakeInjector()
        let audio = FakeAudioCapture()
        let timer = ManualTimerScheduler()
        let fsm = ActivationStateMachine()
        let usage = UsageTracker()
        let orchestrator = Orchestrator(
            provider: provider,
            injector: injector,
            stateMachine: fsm,
            usage: usage,
            audioCapture: audio,
            timerScheduler: timer
        )
        return (orchestrator, provider, injector, audio, timer)
    }

    @Test("finalization completes when committed transcript arrives, even if stream stays open",
          .timeLimit(.minutes(1)))
    func finalizesOnCommittedTranscript() async {
        let rig = makeRig()

        await rig.orchestrator.handle(hotkeyEvent: .keyDown(at: now))
        await rig.timer.fireAll()
        #expect(await rig.orchestrator.isCapturing())

        await rig.orchestrator.handle(hotkeyEvent: .keyUp(at: now))

        let received = await rig.injector.received
        #expect(received == ["delayed close transcription"])
        #expect(await !rig.orchestrator.isCapturing())
    }

    @Test("text is injected exactly once, not duplicated",
          .timeLimit(.minutes(1)))
    func injectsExactlyOnce() async {
        let rig = makeRig()

        await rig.orchestrator.handle(hotkeyEvent: .keyDown(at: now))
        await rig.timer.fireAll()

        await rig.orchestrator.handle(hotkeyEvent: .keyUp(at: now))

        let received = await rig.injector.received
        #expect(received.count == 1)
    }

    @Test("orchestrator is reusable after delayed-close finalization",
          .timeLimit(.minutes(1)))
    func reusableAfterDelayedClose() async {
        let rig = makeRig()

        // First session
        await rig.orchestrator.handle(hotkeyEvent: .keyDown(at: now))
        await rig.timer.fireAll()
        await rig.orchestrator.handle(hotkeyEvent: .keyUp(at: now))

        // Second session
        await rig.orchestrator.handle(hotkeyEvent: .keyDown(at: now))
        await rig.timer.fireAll()
        #expect(await rig.orchestrator.isCapturing())
        await rig.orchestrator.handle(hotkeyEvent: .keyUp(at: now))

        let received = await rig.injector.received
        #expect(received == [
            "delayed close transcription",
            "delayed close transcription",
        ])
    }
}
