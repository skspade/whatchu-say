import Testing
import Foundation
@testable import Audio
@testable import Hotkey
@testable import Injector
@testable import Orchestrator
@testable import STTCore
@testable import Usage

private let now = Date(timeIntervalSinceReferenceDate: 0)

/// Regression tests for the "long-transcript-with-pauses gets truncated" bug.
///
/// ElevenLabs streaming commits a separate `committed_transcript` per
/// pause-segment, plus one final commit in response to `end_of_stream`. The
/// Orchestrator must accumulate ALL of them — overwriting the buffer per
/// segment loses sentences from the front (multiple pre-EOS commits collapse
/// to the last one) or the end (a pre-EOS commit gets returned by `awaitFinal`
/// before the post-EOS commit lands).
@Suite("Orchestrator: transcript accumulation across pause segments")
struct OrchestratorTranscriptAccumulationTests {

    private func makeRig() -> (
        orchestrator: Orchestrator,
        provider: MultiSegmentProvider,
        injector: FakeInjector,
        timer: ManualTimerScheduler
    ) {
        let provider = MultiSegmentProvider()
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
        return (orchestrator, provider, injector, timer)
    }

    /// "Front cut" reproduction: three pause-segments commit during the
    /// session and a fourth commits in response to `endOfStream`. With the
    /// buggy `pendingFinal = text` overwrite, only the last pre-EOS commit
    /// (or the EOS commit, depending on timing) survives. The fix accumulates
    /// every `.final` and returns the full concatenation.
    @Test("multiple pre-EOS commits + post-EOS commit: all four segments preserved")
    func accumulatesAllSegments() async {
        let rig = makeRig()
        await rig.orchestrator.handle(hotkeyEvent: .keyDown(at: now))
        await rig.timer.fireAll()

        let session = await rig.provider.lastSession
        #expect(session != nil)
        guard let session else { return }

        // Three pause-segments commit while the user is still talking.
        await session.yieldFinal("first segment")
        await session.yieldFinal("second segment")
        await session.yieldFinal("third segment")
        // Pre-load the post-EOS commit; emitted when finalize calls endOfStream.
        await session.setEndOfStreamFinal("fourth segment")

        // Let the events consumer handle the three pre-EOS finals before keyUp.
        await session.waitUntilHandled()

        await rig.orchestrator.handle(hotkeyEvent: .keyUp(at: now))

        let received = await rig.injector.received
        #expect(received == [
            "first segment second segment third segment fourth segment"
        ])
    }

    /// "End cut" reproduction: one pause-segment commits during the session,
    /// then a second commits in response to `endOfStream`. With the buggy
    /// `awaitFinal()` early-return on `pendingFinal != nil`, the orchestrator
    /// returns the pre-EOS commit and closes the session before the post-EOS
    /// commit lands. The fix waits for the events stream to end (the WS
    /// close that follows the post-EOS commit in real ElevenLabs) before
    /// returning the accumulated transcript.
    @Test("pre-EOS commit + post-EOS commit: post-EOS commit is not lost")
    func awaitsPostEOSCommit() async {
        let rig = makeRig()
        await rig.orchestrator.handle(hotkeyEvent: .keyDown(at: now))
        await rig.timer.fireAll()

        let session = await rig.provider.lastSession
        #expect(session != nil)
        guard let session else { return }

        await session.yieldFinal("during session")
        await session.setEndOfStreamFinal("after end of stream")

        await session.waitUntilHandled()

        await rig.orchestrator.handle(hotkeyEvent: .keyUp(at: now))

        let received = await rig.injector.received
        #expect(received == ["during session after end of stream"])
    }

    /// Sanity check: a session that produces no `.final` (server commits
    /// nothing, then closes after EOS) must still complete cleanly with no
    /// injection — not deadlock waiting for a final that never comes.
    @Test("no commits at all: closes cleanly with no injection")
    func emptySessionCompletes() async {
        let rig = makeRig()
        await rig.orchestrator.handle(hotkeyEvent: .keyDown(at: now))
        await rig.timer.fireAll()

        let session = await rig.provider.lastSession
        #expect(session != nil)
        guard let session else { return }

        await session.setEndOfStreamFinal(nil)

        await rig.orchestrator.handle(hotkeyEvent: .keyUp(at: now))

        let received = await rig.injector.received
        #expect(received.isEmpty)
        #expect(await !rig.orchestrator.isCapturing())
    }
}
