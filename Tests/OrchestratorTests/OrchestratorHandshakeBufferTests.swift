import Testing
import Foundation
@testable import Audio
@testable import Hotkey
@testable import Injector
@testable import Orchestrator
@testable import STTCore
@testable import Usage

private let now = Date(timeIntervalSinceReferenceDate: 0)

/// Regression tests for the "dictation cuts off the beginning of my
/// sentence" bug.
///
/// Root cause: on key-down the orchestrator starts the mic, then awaits
/// `provider.open` (WebSocket connect + `session_started` handshake, several
/// hundred ms). The audio forwarder dropped every frame that arrived while
/// `currentSession` was still nil, so whatever the user said during the
/// handshake never reached the server.
///
/// Fix: buffer frames while the session is opening and replay them into the
/// session before live frames.
@Suite("Orchestrator: audio captured during the session handshake")
struct OrchestratorHandshakeBufferTests {

    private func makeRig() -> (
        orchestrator: Orchestrator,
        provider: GatedOpenProvider,
        injector: FakeInjector,
        audio: FakeAudioCapture,
        timer: ManualTimerScheduler
    ) {
        let provider = GatedOpenProvider()
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

    /// Start a key-down in the background and return once it's suspended in
    /// `provider.open`.
    private func pressAndAwaitHandshake(
        _ orchestrator: Orchestrator,
        _ provider: GatedOpenProvider
    ) async -> Task<Void, Never> {
        let keyDown = Task { await orchestrator.handle(hotkeyEvent: .keyDown(at: now)) }
        while await !provider.isOpenPending { await Task.yield() }
        return keyDown
    }

    @Test("speech during the handshake is replayed, in order, ahead of live audio",
          .timeLimit(.minutes(1)))
    func handshakeAudioIsReplayed() async {
        let rig = makeRig()
        let keyDown = await pressAndAwaitHandshake(rig.orchestrator, rig.provider)

        // User starts talking on key-down, before the session is ready.
        for i in 1...5 {
            rig.audio.push(AudioFrame(samples: [Int16(i)], timestamp: .zero))
        }
        while await rig.orchestrator.preSessionBufferedSampleCount() < 5 {
            await Task.yield()
        }

        await rig.provider.releaseOpen()
        await keyDown.value

        for i in 6...8 {
            rig.audio.push(AudioFrame(samples: [Int16(i)], timestamp: .zero))
        }
        await rig.timer.fireAll()                                    // → pressHold
        await rig.orchestrator.handle(hotkeyEvent: .keyUp(at: now))  // → finalize

        let session = await rig.provider.lastSession
        let frames = await session?.framesBeforeEOS ?? []
        #expect(frames.flatMap { $0 } == (1...8).map { Int16($0) })
        #expect(await session?.framesAfterEOS.isEmpty == true)
        #expect(await rig.injector.received.count == 1)
    }

    @Test("handshake backlog is replayed in chunks of at most 1 s",
          .timeLimit(.minutes(1)))
    func handshakeBacklogIsChunked() async {
        let rig = makeRig()
        let keyDown = await pressAndAwaitHandshake(rig.orchestrator, rig.provider)

        // 2.5 s of audio at 16 kHz, each frame tagged with its index.
        let frameSamples = 10_000
        for i in 1...4 {
            rig.audio.push(AudioFrame(
                samples: Array(repeating: Int16(i), count: frameSamples),
                timestamp: .zero
            ))
        }
        while await rig.orchestrator.preSessionBufferedSampleCount() < 4 * frameSamples {
            await Task.yield()
        }

        await rig.provider.releaseOpen()
        await keyDown.value
        await rig.timer.fireAll()
        await rig.orchestrator.handle(hotkeyEvent: .keyUp(at: now))

        let frames = await rig.provider.lastSession?.framesBeforeEOS ?? []
        #expect(frames.map(\.count) == [16_000, 16_000, 8_000])
        let expected = (1...4).flatMap { Array(repeating: Int16($0), count: frameSamples) }
        #expect(frames.flatMap { $0 } == expected)
    }

    @Test("failed handshake releases the mic and resets the FSM",
          .timeLimit(.minutes(1)))
    func failedHandshakeStopsAudio() async {
        let rig = makeRig()
        let collector = EventCollector()
        await collector.start(stream: rig.orchestrator.events)

        let keyDown = await pressAndAwaitHandshake(rig.orchestrator, rig.provider)
        await rig.provider.failOpen()
        await keyDown.value

        #expect(await rig.audio.stopCount == 1)
        #expect(await !rig.orchestrator.isCapturing())
        let failure = OrchestratorEvent.error(
            text: "Failed to open session: Transient error: handshake failed"
        )
        let events = await collector.waitForEvent(failure)
        #expect(events.contains(failure))

        // FSM was reset: the next press starts a fresh dictation instead of
        // being swallowed by a stale `.pressed` state.
        let retry = await pressAndAwaitHandshake(rig.orchestrator, rig.provider)
        await rig.provider.releaseOpen()
        await retry.value
        #expect(await rig.audio.startCount == 2)
        #expect(await rig.orchestrator.isCapturing())

        await collector.cancel()
    }

    @Test("system sleep during the handshake discards the late session",
          .timeLimit(.minutes(1)))
    func sleepDuringHandshakeDiscardsSession() async {
        let rig = makeRig()
        let keyDown = await pressAndAwaitHandshake(rig.orchestrator, rig.provider)

        await rig.orchestrator.handleSystemSleep()
        await rig.provider.releaseOpen()
        await keyDown.value

        #expect(await !rig.orchestrator.isCapturing())
        #expect(await rig.audio.stopCount == 1)
    }
}
