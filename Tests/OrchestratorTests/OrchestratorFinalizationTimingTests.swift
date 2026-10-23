import Testing
import Foundation
@testable import Audio
@testable import Hotkey
@testable import Injector
@testable import Orchestrator
@testable import STTCore
@testable import Usage

private let now = Date(timeIntervalSinceReferenceDate: 0)

/// One 20 ms frame of speech-level audio: a ±8000 square wave (~-12 dBFS).
private let loudFrameSamples: [Int16] = (0..<320).map { $0.isMultiple(of: 2) ? 8_000 : -8_000 }

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
        let collector = EventCollector()
        await collector.start(stream: rig.orchestrator.events)

        await rig.orchestrator.handle(hotkeyEvent: .keyDown(at: now))
        await rig.timer.fireAll()
        #expect(await rig.orchestrator.isCapturing())

        // Mark the session as "server heard speech" so finalize sends EOS
        // instead of taking the silence fast-path.
        await rig.provider.lastSession?.yieldPartial("heard speech")
        _ = await collector.waitForEvent(.partial(text: "heard speech"))
        await rig.orchestrator.handle(hotkeyEvent: .keyUp(at: now))

        let received = await rig.injector.received
        #expect(received == ["delayed close transcription"])
        #expect(await !rig.orchestrator.isCapturing())
        await collector.cancel()
    }

    @Test("text is injected exactly once, not duplicated",
          .timeLimit(.minutes(1)))
    func injectsExactlyOnce() async {
        let rig = makeRig()
        let collector = EventCollector()
        await collector.start(stream: rig.orchestrator.events)

        await rig.orchestrator.handle(hotkeyEvent: .keyDown(at: now))
        await rig.timer.fireAll()

        await rig.provider.lastSession?.yieldPartial("heard once")
        _ = await collector.waitForEvent(.partial(text: "heard once"))
        await rig.orchestrator.handle(hotkeyEvent: .keyUp(at: now))

        let received = await rig.injector.received
        #expect(received.count == 1)
        await collector.cancel()
    }

    @Test("orchestrator is reusable after delayed-close finalization",
          .timeLimit(.minutes(1)))
    func reusableAfterDelayedClose() async {
        let rig = makeRig()
        let collector = EventCollector()
        await collector.start(stream: rig.orchestrator.events)

        // First session
        await rig.orchestrator.handle(hotkeyEvent: .keyDown(at: now))
        await rig.timer.fireAll()
        await rig.provider.lastSession?.yieldPartial("first heard")
        _ = await collector.waitForEvent(.partial(text: "first heard"))
        await rig.orchestrator.handle(hotkeyEvent: .keyUp(at: now))

        // Second session
        await rig.orchestrator.handle(hotkeyEvent: .keyDown(at: now))
        await rig.timer.fireAll()
        #expect(await rig.orchestrator.isCapturing())
        await rig.provider.lastSession?.yieldPartial("second heard")
        _ = await collector.waitForEvent(.partial(text: "second heard"))
        await rig.orchestrator.handle(hotkeyEvent: .keyUp(at: now))

        let received = await rig.injector.received
        #expect(received == [
            "delayed close transcription",
            "delayed close transcription",
        ])
        await collector.cancel()
    }
}

/// Regression tests for the "Finalizing hangs ~10 s when no speech was
/// recognized" bug. ElevenLabs replies to an empty commit with
/// `insufficient_audio_activity` only after a long delay, leaving the HUD
/// stuck on "Finalizing" and the orchestrator unable to accept a fresh
/// hotkey press. Fix: when the server never sent any `partial_transcript`
/// (and nothing was accumulated), skip EOS and tear the session down
/// immediately. `SilentSession` models the buggy server by accepting EOS
/// without ever yielding `.final` or finishing the events stream.
@Suite("Orchestrator: finalization fast-path on silence")
struct OrchestratorSilenceFinalizationTests {

    private func makeRig() -> (
        orchestrator: Orchestrator,
        provider: SilentProvider,
        injector: FakeInjector,
        audio: FakeAudioCapture,
        timer: ManualTimerScheduler
    ) {
        let provider = SilentProvider()
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

    @Test("release without speech finalizes immediately and skips EOS",
          .timeLimit(.minutes(1)))
    func finalizesImmediatelyWithoutEOS() async {
        let rig = makeRig()

        await rig.orchestrator.handle(hotkeyEvent: .keyDown(at: now))
        await rig.timer.fireAll()
        #expect(await rig.orchestrator.isCapturing())

        await rig.orchestrator.handle(hotkeyEvent: .keyUp(at: now))

        #expect(await !rig.orchestrator.isCapturing())
        #expect(await rig.injector.received.isEmpty)

        // The critical assertion: we did NOT send EOS, so the test isn't
        // relying on the buggy server's eventual reply.
        let eosCount = await rig.provider.lastSession?.endOfStreamCount ?? -1
        #expect(eosCount == 0)
    }

    @Test("a click's worth of loud audio still takes the fast path",
          .timeLimit(.minutes(1)))
    func briefNoiseStillSkipsEOS() async {
        let rig = makeRig()

        await rig.orchestrator.handle(hotkeyEvent: .keyDown(at: now))
        await rig.timer.fireAll()
        // 40 ms of loud audio — a key click, not speech.
        for _ in 0..<2 {
            rig.audio.push(AudioFrame(samples: loudFrameSamples, timestamp: .zero))
        }
        await rig.orchestrator.handle(hotkeyEvent: .keyUp(at: now))

        #expect(await !rig.orchestrator.isCapturing())
        let eosCount = await rig.provider.lastSession?.endOfStreamCount ?? -1
        #expect(eosCount == 0)
    }

    @Test("orchestrator is reusable after a silent session",
          .timeLimit(.minutes(1)))
    func reusableAfterSilentSession() async {
        let rig = makeRig()

        // First session: no speech recognized, fast-finalize.
        await rig.orchestrator.handle(hotkeyEvent: .keyDown(at: now))
        await rig.timer.fireAll()
        await rig.orchestrator.handle(hotkeyEvent: .keyUp(at: now))

        // Second session must open cleanly even though the first was silent.
        await rig.orchestrator.handle(hotkeyEvent: .keyDown(at: now))
        await rig.timer.fireAll()
        #expect(await rig.orchestrator.isCapturing())
        await rig.orchestrator.handle(hotkeyEvent: .keyUp(at: now))

        #expect(await !rig.orchestrator.isCapturing())
        #expect(await rig.provider.sessions.count == 2)
    }
}

/// Regression tests for the "panel hangs ~15 s, then closes with a WebSocket
/// error" bug. When the ElevenLabs server stops responding mid-finalize
/// without sending a close frame, the OS TCP layer can take 10–15 s to
/// surface the failure on `URLSessionWebSocketTask.receive()`. During that
/// window `awaitFinal()` previously had no escape hatch — the user saw
/// their transcript on screen and lost it on close. Fix: cap the wait via
/// the `finalizeTimeout` parameter, and on timeout commit whatever text we
/// have (committed segments plus the last in-flight partial).
///
/// `SilentSession.yieldPartial(...)` simulates "server got speech and
/// emitted partials, then went quiet forever" — the buggy real-world path.
@Suite("Orchestrator: finalize timeout fallback")
struct OrchestratorFinalizeTimeoutTests {

    private func makeRig() -> (
        orchestrator: Orchestrator,
        provider: SilentProvider,
        injector: FakeInjector,
        audio: FakeAudioCapture,
        timer: ManualTimerScheduler
    ) {
        let provider = SilentProvider()
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
            timerScheduler: timer,
            // Duration is irrelevant under a manual scheduler — fireAll
            // drives the firing — but pass an explicit non-default so the
            // test communicates intent at the call site.
            finalizeTimeout: .milliseconds(10)
        )
        return (orchestrator, provider, injector, audio, timer)
    }

    /// Spin (yielding) until the manual timer scheduler has a pending
    /// action queued. Used by the timeout test to know "the orchestrator
    /// has reached the suspended-on-awaitFinal state and registered its
    /// timeout — safe to fireAll now." Bails after a generous spin cap so
    /// a regression that fails to schedule the timer surfaces as a test
    /// failure rather than a hang.
    private func waitForPending(_ timer: ManualTimerScheduler, atLeast count: Int) async {
        for _ in 0..<2000 {
            if await timer.pendingCount >= count { return }
            await Task.yield()
        }
    }

    @Test("timeout commits the last in-flight partial when no .final ever arrives",
          .timeLimit(.minutes(1)))
    func timeoutCommitsLastPartial() async {
        let rig = makeRig()
        let collector = EventCollector()
        await collector.start(stream: rig.orchestrator.events)

        await rig.orchestrator.handle(hotkeyEvent: .keyDown(at: now))
        await rig.timer.fireAll()
        #expect(await rig.orchestrator.isCapturing())

        // Server sees speech and emits a partial, then goes quiet forever.
        await rig.provider.lastSession?.yieldPartial("hello world")
        // Wait until the orchestrator has pulled the partial into state
        // (partialsReceived + currentPartial).
        _ = await collector.waitForEvent(.partial(text: "hello world"))

        // Drive keyUp in a Task so the test can step the timer while
        // finalizeAndInject is suspended inside awaitFinal.
        let handleTask = Task {
            await rig.orchestrator.handle(hotkeyEvent: .keyUp(at: now))
        }
        // Wait until the orchestrator has scheduled the finalize timeout.
        await waitForPending(rig.timer, atLeast: 1)
        await rig.timer.fireAll()
        await handleTask.value

        let received = await rig.injector.received
        #expect(received == ["hello world"])
        #expect(await !rig.orchestrator.isCapturing())
        // The session DID get an EOS — this is the not-fast-path branch.
        let eosCount = await rig.provider.lastSession?.endOfStreamCount ?? -1
        #expect(eosCount == 1)
        await collector.cancel()
    }

    @Test("short utterance released before any partial still sends EOS",
          .timeLimit(.minutes(1)))
    func loudAudioWithoutPartialSendsEOS() async {
        let rig = makeRig()

        await rig.orchestrator.handle(hotkeyEvent: .keyDown(at: now))
        await rig.timer.fireAll()
        // 200 ms of speech-level audio; the server hasn't sent a partial yet.
        for _ in 0..<10 {
            rig.audio.push(AudioFrame(samples: loudFrameSamples, timestamp: .zero))
        }

        let handleTask = Task {
            await rig.orchestrator.handle(hotkeyEvent: .keyUp(at: now))
        }
        // EOS was sent and finalize is waiting on the commit; let the
        // timeout release it (the silent server never answers).
        await waitForPending(rig.timer, atLeast: 1)
        await rig.timer.fireAll()
        await handleTask.value

        let eosCount = await rig.provider.lastSession?.endOfStreamCount ?? -1
        #expect(eosCount == 1)
        #expect(await !rig.orchestrator.isCapturing())
    }

    @Test("orchestrator is reusable after a timeout-fallback session",
          .timeLimit(.minutes(1)))
    func reusableAfterTimeout() async {
        let rig = makeRig()
        let collector = EventCollector()
        await collector.start(stream: rig.orchestrator.events)

        // First session: partial arrives, then timeout commits it.
        await rig.orchestrator.handle(hotkeyEvent: .keyDown(at: now))
        await rig.timer.fireAll()
        await rig.provider.lastSession?.yieldPartial("first")
        _ = await collector.waitForEvent(.partial(text: "first"))
        let firstHandle = Task {
            await rig.orchestrator.handle(hotkeyEvent: .keyUp(at: now))
        }
        await waitForPending(rig.timer, atLeast: 1)
        await rig.timer.fireAll()
        await firstHandle.value

        // Second session must open cleanly even though the first ended
        // via the timeout fallback path.
        await rig.orchestrator.handle(hotkeyEvent: .keyDown(at: now))
        await rig.timer.fireAll()
        #expect(await rig.orchestrator.isCapturing())
        await rig.provider.lastSession?.yieldPartial("second")
        _ = await collector.waitForEvent(.partial(text: "second"))
        let secondHandle = Task {
            await rig.orchestrator.handle(hotkeyEvent: .keyUp(at: now))
        }
        await waitForPending(rig.timer, atLeast: 1)
        await rig.timer.fireAll()
        await secondHandle.value

        let received = await rig.injector.received
        #expect(received == ["first", "second"])
        #expect(await rig.provider.sessions.count == 2)
        await collector.cancel()
    }
}

/// Regression tests for the show-stopper path where releasing the hotkey
/// blocks in `stopAndDrainAudio()` before the existing finalize timeout is
/// installed. The user saw partial text in the HUD, but a WebSocket receive
/// error finished the session stream while an audio send was still stuck.
/// Without explicit drain-waiter recovery, release never emits
/// `.sessionEnded`, leaving the app in a permanent listening state.
@Suite("Orchestrator: stream-ended recovery during audio drain")
struct OrchestratorDrainStreamEndedRecoveryTests {

    private func makeRig() async -> (
        orchestrator: Orchestrator,
        provider: BlockingPushProvider,
        injector: FakeInjector,
        audio: FakeAudioCapture,
        timer: ManualTimerScheduler,
        events: EventCollector
    ) {
        let provider = BlockingPushProvider()
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
        let events = EventCollector()
        await events.start(stream: orchestrator.events)
        return (orchestrator, provider, injector, audio, timer, events)
    }

    private func waitForPushBlocked(_ session: BlockingPushSession) async {
        for _ in 0..<2_000 {
            if await session.isPushBlocked { return }
            await Task.yield()
        }
    }

    private func waitForStopCount(_ audio: FakeAudioCapture, atLeast count: Int) async {
        for _ in 0..<2_000 {
            if await audio.stopCount >= count { return }
            await Task.yield()
        }
    }

    private func completes(_ task: Task<Void, Never>, within timeout: Duration) async -> Bool {
        let flag = CompletionFlag()
        let observer = Task {
            await task.value
            await flag.markDone()
        }
        try? await Task.sleep(for: timeout)
        if await flag.isDone {
            await observer.value
            return true
        }
        observer.cancel()
        return false
    }

    @Test("release pastes visible partial and resets when stream ends during audio drain",
          .timeLimit(.minutes(1)))
    func streamEndDuringDrainPastesPartialAndResets() async {
        let rig = await makeRig()

        await rig.orchestrator.handle(hotkeyEvent: .keyDown(at: now))
        await rig.timer.fireAll()
        #expect(await rig.orchestrator.isCapturing())

        guard let session = await rig.provider.lastSession else {
            Issue.record("expected provider to create a session")
            return
        }

        session.yieldPartial("visible transcript")
        _ = await rig.events.waitForEvent(.partial(text: "visible transcript"))

        rig.audio.push(AudioFrame(samples: [1], timestamp: .zero))
        await waitForPushBlocked(session)
        #expect(await session.isPushBlocked)

        let releaseTask = Task {
            await rig.orchestrator.handle(hotkeyEvent: .keyUp(at: now))
        }
        await waitForStopCount(rig.audio, atLeast: 1)

        session.finishStream()
        let completedWithoutManualPushRelease = await completes(
            releaseTask,
            within: .milliseconds(250)
        )
        if !completedWithoutManualPushRelease {
            await session.releasePush()
            await releaseTask.value
        }

        #expect(completedWithoutManualPushRelease)
        #expect(await rig.injector.received == ["visible transcript"])
        #expect(await !rig.orchestrator.isCapturing())

        let events = await rig.events.snapshot()
        #expect(events.contains(.sessionEnded(injectedText: "visible transcript")))
    }

    @Test("orchestrator is reusable after stream-ended drain recovery",
          .timeLimit(.minutes(1)))
    func reusableAfterStreamEndDuringDrain() async {
        let rig = await makeRig()

        await rig.orchestrator.handle(hotkeyEvent: .keyDown(at: now))
        await rig.timer.fireAll()
        guard let firstSession = await rig.provider.lastSession else {
            Issue.record("expected first session")
            return
        }
        firstSession.yieldPartial("first visible")
        _ = await rig.events.waitForEvent(.partial(text: "first visible"))
        rig.audio.push(AudioFrame(samples: [1], timestamp: .zero))
        await waitForPushBlocked(firstSession)
        let firstRelease = Task {
            await rig.orchestrator.handle(hotkeyEvent: .keyUp(at: now))
        }
        await waitForStopCount(rig.audio, atLeast: 1)
        firstSession.finishStream()
        let firstCompleted = await completes(firstRelease, within: .milliseconds(250))
        if !firstCompleted {
            await firstSession.releasePush()
            await firstRelease.value
        }
        #expect(firstCompleted)

        await rig.orchestrator.handle(hotkeyEvent: .keyDown(at: now))
        await rig.timer.fireAll()
        #expect(await rig.orchestrator.isCapturing())

        let received = await rig.injector.received
        #expect(received == ["first visible"])
        #expect(await rig.provider.sessions.count == 2)
    }
}

private actor CompletionFlag {
    private var done = false

    func markDone() {
        done = true
    }

    var isDone: Bool {
        done
    }
}
