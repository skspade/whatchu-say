import Testing
import Foundation
@testable import Audio
@testable import Hotkey
@testable import Injector
@testable import Orchestrator
@testable import STTCore
@testable import Usage

private let now = Date(timeIntervalSinceReferenceDate: 0)

/// Regression tests for the "app stuck in listening mode after a WebSocket
/// send error during transcription" bug.
///
/// Root cause: when the WebSocket's send direction died mid-transcription,
/// `ElevenLabsSession.pushAudio` threw, but the orchestrator's audio
/// forwarder only logged the error and kept going. The session's receive
/// loop was stuck in `URLSessionWebSocketTask.receive()` (which doesn't
/// reliably fail when the send direction breaks), so the events stream
/// never finished, `handleSessionStreamEnded` never ran, and no
/// `.sessionEnded` was emitted — leaving the app wedged in listening mode
/// until restart.
///
/// Fix: treat a non-cancelled `pushAudio` failure as a dead session — tear
/// it down and reset listening state via the existing recovery path.
@Suite("Orchestrator: send-side WebSocket failure during active listening")
struct OrchestratorSendFailureTests {

    private func makeRig() -> (
        orchestrator: Orchestrator,
        provider: SendFailureProvider,
        injector: FakeInjector,
        audio: FakeAudioCapture,
        timer: ManualTimerScheduler
    ) {
        let provider = SendFailureProvider()
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

    @Test("send failure mid-listening tears down the session and resets to idle",
          .timeLimit(.minutes(1)))
    func sendFailureResetsToListeningIdle() async {
        let rig = makeRig()
        let collector = EventCollector()
        await collector.start(stream: rig.orchestrator.events)

        await rig.orchestrator.handle(hotkeyEvent: .keyDown(at: now))
        await rig.timer.fireAll()
        #expect(await rig.orchestrator.isCapturing())

        // Push real audio so the forwarder calls pushAudio, which throws.
        rig.audio.push(AudioFrame(samples: [1, 2, 3, 4], timestamp: .zero))

        // The send failure must surface as .sessionEnded(nil) so the UI
        // (HUD + hotkey gate) resets. Without the fix this never arrives.
        let events = await collector.waitForEvent(.sessionEnded(injectedText: nil))
        #expect(events.contains(.sessionEnded(injectedText: nil)))
        #expect(await !rig.orchestrator.isCapturing())
        #expect(await rig.injector.received.isEmpty)

        await collector.cancel()
    }

    @Test("orchestrator is reusable after a send-side failure",
          .timeLimit(.minutes(1)))
    func reusableAfterSendFailure() async {
        let rig = makeRig()
        let collector = EventCollector()
        await collector.start(stream: rig.orchestrator.events)

        // First session: wedged by send failure (pre-fix).
        await rig.orchestrator.handle(hotkeyEvent: .keyDown(at: now))
        await rig.timer.fireAll()
        rig.audio.push(AudioFrame(samples: [1], timestamp: .zero))
        _ = await collector.waitForEvent(.sessionEnded(injectedText: nil))
        #expect(await !rig.orchestrator.isCapturing())

        // Second session must open cleanly after recovery.
        await rig.orchestrator.handle(hotkeyEvent: .keyDown(at: now))
        await rig.timer.fireAll()
        #expect(await rig.orchestrator.isCapturing())
        #expect(await rig.provider.sessions.count == 2)

        await collector.cancel()
    }
}
