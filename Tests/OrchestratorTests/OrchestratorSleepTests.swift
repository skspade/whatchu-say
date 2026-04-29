import Testing
import Foundation
@testable import Audio
@testable import Hotkey
@testable import Injector
@testable import Orchestrator
@testable import STTCore
@testable import Usage

private let now = Date(timeIntervalSinceReferenceDate: 0)

/// A rig that mirrors `OrchestratorEventTests`'s scriptable rig but also
/// exposes the audio fake (so tests can assert on stop counts) and the FSM
/// (not strictly needed yet, but cheap insurance).
private struct SleepRig {
    let orchestrator: Orchestrator
    let provider: ScriptableProvider
    let injector: FakeInjector
    let audio: FakeAudioCapture
    let timer: ManualTimerScheduler
}

private func makeSleepRig() -> SleepRig {
    let provider = ScriptableProvider()
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
    return SleepRig(
        orchestrator: orchestrator,
        provider: provider,
        injector: injector,
        audio: audio,
        timer: timer
    )
}

@Suite("Orchestrator: handleSystemSleep")
struct OrchestratorSleepTests {

    @Test("active press-hold session: emits sessionEnded(nil), stops audio, no inject, no finalize")
    func activeSession() async {
        let rig = makeSleepRig()
        let collector = EventCollector()
        await collector.start(stream: rig.orchestrator.events)

        await rig.orchestrator.handle(hotkeyEvent: .keyDown(at: now))
        await rig.timer.fireAll()
        // Session is now live; no final yielded, no keyUp — sleep happens here.
        #expect(await rig.orchestrator.isCapturing())

        await rig.orchestrator.handleSystemSleep()

        let events = await collector.snapshot()
        #expect(events.contains(.sessionStarted(mode: .pressHold)))
        #expect(events.contains(.sessionEnded(injectedText: nil)))
        #expect(!events.contains(.finalizing))
        #expect(await rig.injector.received.isEmpty)
        #expect(await !rig.orchestrator.isCapturing())
        #expect(await rig.audio.stopCount >= 1)

        await collector.cancel()
    }

    @Test("tapPending (post-tap, awaiting double-tap window): cancels session and pending timer")
    func tapPendingSleep() async {
        let rig = makeSleepRig()
        let collector = EventCollector()
        await collector.start(stream: rig.orchestrator.events)

        // keyDown opens a session; keyUp leaves FSM in tapPending with the
        // session still live (waiting to see if a double-tap promotes to
        // hands-free) and a doubleTapWindow timer scheduled.
        await rig.orchestrator.handle(hotkeyEvent: .keyDown(at: now))
        await rig.orchestrator.handle(hotkeyEvent: .keyUp(at: now))
        #expect(await rig.timer.pendingCount == 1)
        #expect(await rig.orchestrator.isCapturing())

        await rig.orchestrator.handleSystemSleep()

        let events = await collector.snapshot()
        #expect(events.contains(.sessionEnded(injectedText: nil)))
        #expect(await rig.injector.received.isEmpty)
        #expect(await rig.timer.pendingCount == 0)
        #expect(await !rig.orchestrator.isCapturing())

        await collector.cancel()
    }

    @Test("idle: pure no-op, emits nothing")
    func idleNoOp() async {
        let rig = makeSleepRig()
        let collector = EventCollector()
        await collector.start(stream: rig.orchestrator.events)

        await rig.orchestrator.handleSystemSleep()

        let events = await collector.snapshot()
        #expect(events.isEmpty)
        #expect(await !rig.orchestrator.isCapturing())
        #expect(await rig.injector.received.isEmpty)

        await collector.cancel()
    }

    @Test("post-sleep: a fresh dictation runs end-to-end successfully")
    func freshDictationAfterSleep() async {
        let rig = makeSleepRig()
        let collector = EventCollector()
        await collector.start(stream: rig.orchestrator.events)

        // Sleep mid-session.
        await rig.orchestrator.handle(hotkeyEvent: .keyDown(at: now))
        await rig.timer.fireAll()
        await rig.orchestrator.handleSystemSleep()

        // Now run a normal flow.
        await rig.orchestrator.handle(hotkeyEvent: .keyDown(at: now))
        await rig.timer.fireAll()
        await rig.provider.yieldFinal("hello after wake")
        await rig.orchestrator.handle(hotkeyEvent: .keyUp(at: now))

        let events = await collector.snapshot()
        #expect(events.contains(.sessionEnded(injectedText: "hello after wake")))
        #expect(await rig.injector.received == ["hello after wake"])

        await collector.cancel()
    }
}
