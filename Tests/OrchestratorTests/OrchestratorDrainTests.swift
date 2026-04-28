import Testing
import Foundation
@testable import Audio
@testable import Hotkey
@testable import Injector
@testable import Orchestrator
@testable import STTCore
@testable import Usage

private let now = Date(timeIntervalSinceReferenceDate: 0)

@Suite("Orchestrator: audio forwarder drain ordering")
struct OrchestratorDrainTests {

    /// Reproduces the "long transcript loses the last few seconds" bug.
    ///
    /// Frames are pushed into the audio capture stream just before hotkey
    /// release. Because `finalizeAndInject` calls `session.endOfStream()`
    /// without first draining the audio forwarder, some pushAudio calls
    /// arrive at the session AFTER endOfStream — and in real usage those
    /// frames do not land in the server's committed transcript. The recording
    /// session here mirrors that semantic: `framesAfterEOS` are dropped from
    /// the `.final`.
    @Test("frames buffered at release are forwarded before endOfStream")
    func drainsAudioBeforeEndOfStream() async {
        let provider = RecordingProvider()
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

        // Enter PRESS_HOLD: keyDown then fire the press-hold timer.
        await orchestrator.handle(hotkeyEvent: .keyDown(at: now))
        await timer.fireAll()

        // Push 10 distinguishable frames synchronously into the audio stream.
        // These sit in the AsyncStream waiting for the forwarder to consume.
        let totalFrames = 10
        for i in 1...totalFrames {
            audio.push(AudioFrame(samples: [Int16(i)], timestamp: .zero))
        }

        // Release: triggers .stopDictation → finalizeAndInject → endOfStream.
        await orchestrator.handle(hotkeyEvent: .keyUp(at: now))

        let session = await provider.lastSession
        #expect(session != nil)
        let beforeCount = await session?.framesBeforeEOS.count ?? -1
        let afterCount = await session?.framesAfterEOS.count ?? -1

        // Expectation: the orchestrator drains all queued frames before EOS,
        // so every frame is in the committed bucket and the injected text
        // contains all 10 sequence numbers.
        #expect(beforeCount == totalFrames)
        #expect(afterCount == 0)

        let expected = (1...totalFrames).map(String.init).joined(separator: ",")
        let received = await injector.received
        #expect(received == [expected])
    }
}
