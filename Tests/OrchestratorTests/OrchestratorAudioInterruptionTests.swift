import Testing
import Foundation
@testable import Audio
@testable import Hotkey
@testable import Injector
@testable import Orchestrator
@testable import STTCore
@testable import Usage

private let now = Date(timeIntervalSinceReferenceDate: 0)

/// Mirrors the sleep-tests rig — provider, injector, audio fake, timer.
private struct InterruptionRig {
    let orchestrator: Orchestrator
    let provider: ScriptableProvider
    let injector: FakeInjector
    let audio: FakeAudioCapture
    let timer: ManualTimerScheduler
}

private func makeRig() -> InterruptionRig {
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
    return InterruptionRig(
        orchestrator: orchestrator,
        provider: provider,
        injector: injector,
        audio: audio,
        timer: timer
    )
}

@Suite("Orchestrator: handleAudioInterruption")
struct OrchestratorAudioInterruptionTests {

    @Test("active session: emits .error then .sessionEnded(nil), tears down, no inject")
    func activeSession() async {
        let rig = makeRig()
        let collector = EventCollector()
        await collector.start(stream: rig.orchestrator.events)

        await rig.orchestrator.handle(hotkeyEvent: .keyDown(at: now))
        await rig.timer.fireAll()
        #expect(await rig.orchestrator.isCapturing())

        await rig.orchestrator.handleAudioInterruption()
        // Several actor hops happen inside interruptAndReset (audioCapture.stop,
        // stateMachine.reset). Yield enough times for the collector to drain.
        for _ in 0..<16 { await Task.yield() }

        let events = await collector.snapshot()
        let errorIndex = events.firstIndex { event in
            if case .error = event { return true }
            return false
        }
        let endedIndex = events.firstIndex { event in
            if case .sessionEnded = event { return true }
            return false
        }
        // Both events must land, and .error must precede .sessionEnded so
        // the UI shows "audio device changed" before the indicator clears.
        #expect(errorIndex != nil)
        #expect(endedIndex != nil)
        if let errorIndex, let endedIndex {
            #expect(errorIndex < endedIndex)
        }
        #expect(events.contains(.sessionEnded(injectedText: nil)))
        #expect(await rig.injector.received.isEmpty)
        #expect(await !rig.orchestrator.isCapturing())
        #expect(await rig.audio.stopCount >= 1)

        await collector.cancel()
    }

    @Test("idle: no events emitted, no teardown work")
    func idleNoOp() async {
        let rig = makeRig()
        let collector = EventCollector()
        await collector.start(stream: rig.orchestrator.events)

        await rig.orchestrator.handleAudioInterruption()

        let events = await collector.snapshot()
        #expect(events.isEmpty)
        #expect(await !rig.orchestrator.isCapturing())
        #expect(await rig.injector.received.isEmpty)

        await collector.cancel()
    }

    @Test("post-interruption: a fresh dictation runs end-to-end successfully")
    func freshDictationAfterInterruption() async {
        let rig = makeRig()
        let collector = EventCollector()
        await collector.start(stream: rig.orchestrator.events)

        // Interrupt mid-session.
        await rig.orchestrator.handle(hotkeyEvent: .keyDown(at: now))
        await rig.timer.fireAll()
        await rig.orchestrator.handleAudioInterruption()

        // Now run a normal flow.
        await rig.orchestrator.handle(hotkeyEvent: .keyDown(at: now))
        await rig.timer.fireAll()
        await rig.provider.yieldFinal("hello after change")
        await rig.orchestrator.handle(hotkeyEvent: .keyUp(at: now))

        let events = await collector.snapshot()
        #expect(events.contains(.sessionEnded(injectedText: "hello after change")))
        #expect(await rig.injector.received == ["hello after change"])

        await collector.cancel()
    }
}
