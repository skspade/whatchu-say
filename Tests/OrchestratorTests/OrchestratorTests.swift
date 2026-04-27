import Testing
import Foundation
@testable import Audio
@testable import Hotkey
@testable import Injector
@testable import Orchestrator
@testable import STTCore
@testable import STTMockProvider
@testable import Usage

// MARK: - Helpers

private let now = Date(timeIntervalSinceReferenceDate: 0)

private struct TestRig {
    let orchestrator: Orchestrator
    let injector: FakeInjector
    let audio: FakeAudioCapture
    let timer: ManualTimerScheduler
}

private func makeRig(
    cannedFinal: String = "mock transcription"
) -> TestRig {
    let provider = MockProvider(cannedFinal: cannedFinal)
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
    return TestRig(
        orchestrator: orchestrator,
        injector: injector,
        audio: audio,
        timer: timer
    )
}

// MARK: - End-to-end flows

@Suite("Orchestrator: end-to-end flows")
struct OrchestratorE2ETests {

    @Test("press-and-hold injects the final transcript and stops audio")
    func pressAndHold() async {
        let rig = makeRig()

        await rig.orchestrator.handle(hotkeyEvent: .keyDown(at: now))
        #expect(await rig.orchestrator.isCapturing())
        #expect(await rig.audio.startCount == 1)
        #expect(await rig.audio.stopCount == 0)

        await rig.timer.fireAll()  // press-hold timer → PRESS_HOLD (no output)
        #expect(await rig.orchestrator.activeMode() == .pressHold)
        #expect(await rig.orchestrator.isCapturing())

        await rig.orchestrator.handle(hotkeyEvent: .keyUp(at: now))

        #expect(await !rig.orchestrator.isCapturing())
        #expect(await rig.injector.received == ["mock transcription"])
        #expect(await rig.audio.stopCount == 1)
    }

    @Test("short press: timer-expiry path also injects the final transcript")
    func shortPress() async {
        let rig = makeRig()

        await rig.orchestrator.handle(hotkeyEvent: .keyDown(at: now))
        await rig.orchestrator.handle(hotkeyEvent: .keyUp(at: now))
        // Now in TAP_PENDING; timer firing finalizes as a short press.
        await rig.timer.fireAll()

        #expect(await !rig.orchestrator.isCapturing())
        #expect(await rig.injector.received == ["mock transcription"])
        #expect(await rig.audio.stopCount == 1)
    }

    @Test("cancellation during press-hold: no injection, audio stops once")
    func cancelDuringPressHold() async {
        let rig = makeRig()

        await rig.orchestrator.handle(hotkeyEvent: .keyDown(at: now))
        await rig.timer.fireAll()
        await rig.orchestrator.handle(hotkeyEvent: .cancelKey(at: now))
        #expect(await !rig.orchestrator.isCapturing())

        await rig.orchestrator.handle(hotkeyEvent: .keyUp(at: now))

        #expect(await rig.injector.received.isEmpty)
        #expect(await rig.audio.startCount == 1)
        #expect(await rig.audio.stopCount == 1)
    }

    @Test("cancellation during early press (before timer): no injection")
    func cancelDuringEarlyPress() async {
        let rig = makeRig()

        await rig.orchestrator.handle(hotkeyEvent: .keyDown(at: now))
        await rig.orchestrator.handle(hotkeyEvent: .cancelKey(at: now))
        await rig.orchestrator.handle(hotkeyEvent: .keyUp(at: now))

        #expect(await rig.injector.received.isEmpty)
        #expect(await !rig.orchestrator.isCapturing())
    }

    @Test("double-tap → exit injects the hands-free final, not the speculative one")
    func doubleTapEnterAndExit() async {
        let rig = makeRig()

        await rig.orchestrator.handle(hotkeyEvent: .keyDown(at: now))   // → pressed
        await rig.orchestrator.handle(hotkeyEvent: .keyUp(at: now))     // → tapPending
        await rig.orchestrator.handle(hotkeyEvent: .keyDown(at: now))   // → handsFree (promote)
        #expect(await rig.orchestrator.activeMode() == .handsFree)

        await rig.orchestrator.handle(hotkeyEvent: .keyDown(at: now))   // → exiting (stop)
        await rig.orchestrator.handle(hotkeyEvent: .keyUp(at: now))     // → idle

        // Exactly one inject — the hands-free session's final.
        // (The speculative pressHold session was discarded on promote.)
        #expect(await rig.injector.received == ["mock transcription"])

        // Audio: started once at initial keyDown, stopped once at exit.
        // Promote does NOT cycle audio.
        #expect(await rig.audio.startCount == 1)
        #expect(await rig.audio.stopCount == 1)
    }

    @Test("cancel during hands-free: no injection, audio stops once")
    func cancelDuringHandsFree() async {
        let rig = makeRig()

        await rig.orchestrator.handle(hotkeyEvent: .keyDown(at: now))
        await rig.orchestrator.handle(hotkeyEvent: .keyUp(at: now))
        await rig.orchestrator.handle(hotkeyEvent: .keyDown(at: now))   // → handsFree
        await rig.orchestrator.handle(hotkeyEvent: .cancelKey(at: now)) // → idle

        #expect(await rig.injector.received.isEmpty)
        #expect(await !rig.orchestrator.isCapturing())
        #expect(await rig.audio.stopCount == 1)
    }

    @Test("FSM remains usable after a flow completes")
    func reusableAfterFlow() async {
        let rig = makeRig()

        // First press-and-hold
        await rig.orchestrator.handle(hotkeyEvent: .keyDown(at: now))
        await rig.timer.fireAll()
        await rig.orchestrator.handle(hotkeyEvent: .keyUp(at: now))

        // Second press-and-hold — orchestrator should be idle and ready.
        await rig.orchestrator.handle(hotkeyEvent: .keyDown(at: now))
        #expect(await rig.orchestrator.isCapturing())
        await rig.timer.fireAll()
        await rig.orchestrator.handle(hotkeyEvent: .keyUp(at: now))

        #expect(await rig.injector.received == [
            "mock transcription",
            "mock transcription",
        ])
        #expect(await rig.audio.startCount == 2)
        #expect(await rig.audio.stopCount == 2)
    }

    @Test("empty final from provider produces no injection")
    func emptyFinalSilent() async {
        let rig = makeRig(cannedFinal: "")

        await rig.orchestrator.handle(hotkeyEvent: .keyDown(at: now))
        await rig.timer.fireAll()
        await rig.orchestrator.handle(hotkeyEvent: .keyUp(at: now))

        #expect(await rig.injector.received.isEmpty)
        #expect(await !rig.orchestrator.isCapturing())
        // Audio still starts and stops normally.
        #expect(await rig.audio.startCount == 1)
        #expect(await rig.audio.stopCount == 1)
    }
}
