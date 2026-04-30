import Testing
import Foundation
@testable import Audio
@testable import Hotkey
@testable import Injector
@testable import Orchestrator
@testable import STTCore
@testable import Usage

private let now = Date(timeIntervalSinceReferenceDate: 0)

// Build a rig wired to a `ScriptableProvider` so tests control when partials,
// finals, and warnings are emitted.
private struct ScriptableRig {
    let orchestrator: Orchestrator
    let provider: ScriptableProvider
    let injector: FakeInjector
    let timer: ManualTimerScheduler
}

private func makeScriptableRig() -> ScriptableRig {
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
    return ScriptableRig(
        orchestrator: orchestrator,
        provider: provider,
        injector: injector,
        timer: timer
    )
}

@Suite("Orchestrator: event stream")
struct OrchestratorEventTests {

    @Test("session lifecycle: started → finalizing → ended(text)")
    func happyPath() async {
        let rig = makeScriptableRig()
        let collector = EventCollector()
        await collector.start(stream: rig.orchestrator.events)

        await rig.orchestrator.handle(hotkeyEvent: .keyDown(at: now))
        await rig.timer.fireAll()

        // Pre-yield the final so finalizeAndInject can complete on keyUp.
        await rig.provider.yieldFinal("hello world")

        await rig.orchestrator.handle(hotkeyEvent: .keyUp(at: now))

        let events = await collector.snapshot()
        #expect(events.contains(.sessionStarted(mode: .pressHold)))
        #expect(events.contains(.finalizing))
        #expect(events.contains(.sessionEnded(injectedText: "hello world")))
        #expect(await rig.injector.received == ["hello world"])

        await collector.cancel()
    }

    @Test("partial transcripts forward as .partial events")
    func partialsForward() async {
        let rig = makeScriptableRig()
        let collector = EventCollector()
        await collector.start(stream: rig.orchestrator.events)

        await rig.orchestrator.handle(hotkeyEvent: .keyDown(at: now))
        await rig.timer.fireAll()

        await rig.provider.yieldPartial("hi")
        await rig.provider.yieldPartial("hi th")
        await rig.provider.yieldPartial("hi there")
        await rig.provider.yieldFinal("hi there")

        await rig.orchestrator.handle(hotkeyEvent: .keyUp(at: now))

        let events = await collector.snapshot()
        let partials = events.compactMap { event -> String? in
            if case .partial(let text) = event { return text }
            return nil
        }
        #expect(partials == ["hi", "hi th", "hi there"])
        #expect(events.contains(.sessionEnded(injectedText: "hi there")))

        await collector.cancel()
    }

    @Test("cancel emits sessionEnded(nil) with no injection")
    func cancelEmitsEndedNil() async {
        let rig = makeScriptableRig()
        let collector = EventCollector()
        await collector.start(stream: rig.orchestrator.events)

        await rig.orchestrator.handle(hotkeyEvent: .keyDown(at: now))
        await rig.timer.fireAll()
        await rig.orchestrator.handle(hotkeyEvent: .cancelKey(at: now))

        let events = await collector.snapshot()
        #expect(events.contains(.sessionStarted(mode: .pressHold)))
        #expect(events.contains(.sessionEnded(injectedText: nil)))
        #expect(!events.contains(.finalizing))
        #expect(await rig.injector.received.isEmpty)

        await collector.cancel()
    }

    @Test("provider warning surfaces as .error event")
    func warningBecomesError() async {
        let rig = makeScriptableRig()
        let collector = EventCollector()
        await collector.start(stream: rig.orchestrator.events)

        await rig.orchestrator.handle(hotkeyEvent: .keyDown(at: now))
        await rig.timer.fireAll()

        await rig.provider.yieldWarning("transient hiccup")
        await rig.provider.yieldFinal("recovered text")

        await rig.orchestrator.handle(hotkeyEvent: .keyUp(at: now))

        let events = await collector.snapshot()
        #expect(events.contains(.error(text: "transient hiccup")))
        // Session still completes normally after a warning.
        #expect(events.contains(.sessionEnded(injectedText: "recovered text")))

        await collector.cancel()
    }

    @Test("empty final emits sessionEnded(nil), no injection")
    func emptyFinal() async {
        let rig = makeScriptableRig()
        let collector = EventCollector()
        await collector.start(stream: rig.orchestrator.events)

        await rig.orchestrator.handle(hotkeyEvent: .keyDown(at: now))
        await rig.timer.fireAll()
        await rig.provider.yieldFinal("")
        await rig.orchestrator.handle(hotkeyEvent: .keyUp(at: now))

        let events = await collector.snapshot()
        #expect(events.contains(.sessionEnded(injectedText: nil)))
        #expect(await rig.injector.received.isEmpty)

        await collector.cancel()
    }

    @Test("rapid back-to-back sessions emit two complete lifecycles")
    func rapidBackToBack() async {
        let rig = makeScriptableRig()
        let collector = EventCollector()
        await collector.start(stream: rig.orchestrator.events)

        // First session
        await rig.orchestrator.handle(hotkeyEvent: .keyDown(at: now))
        await rig.timer.fireAll()
        await rig.provider.yieldFinal("first")
        await rig.orchestrator.handle(hotkeyEvent: .keyUp(at: now))

        // Second session
        await rig.orchestrator.handle(hotkeyEvent: .keyDown(at: now))
        await rig.timer.fireAll()
        await rig.provider.yieldFinal("second")
        await rig.orchestrator.handle(hotkeyEvent: .keyUp(at: now))

        let events = await collector.snapshot()
        let endedTexts = events.compactMap { event -> String?? in
            if case .sessionEnded(let text) = event { return text }
            return nil
        }
        #expect(endedTexts.count == 2)
        #expect(endedTexts[0] == "first")
        #expect(endedTexts[1] == "second")
        #expect(await rig.injector.received == ["first", "second"])

        await collector.cancel()
    }

    @Test("session events stream ends mid-press-hold: emits sessionEnded(nil), resets FSM")
    func sessionStreamEndsDuringPressHold() async {
        let rig = makeScriptableRig()
        let collector = EventCollector()
        await collector.start(stream: rig.orchestrator.events)

        await rig.orchestrator.handle(hotkeyEvent: .keyDown(at: now))
        await rig.timer.fireAll()
        #expect(await rig.orchestrator.isCapturing())

        // Server-side error path: warning surfaced, then events stream
        // finishes (mirrors ElevenLabsSession's tearDown after .error).
        await rig.provider.yieldWarning("service_busy")
        await rig.provider.lastSession?.close()
        for _ in 0..<8 { await Task.yield() }

        let events = await collector.snapshot()
        #expect(events.contains(.error(text: "service_busy")))
        #expect(events.contains(.sessionEnded(injectedText: nil)))
        #expect(!events.contains(.finalizing))
        #expect(await !rig.orchestrator.isCapturing())
        #expect(await rig.injector.received.isEmpty)

        // FSM is reset: a fresh keyDown opens a new session cleanly.
        await rig.orchestrator.handle(hotkeyEvent: .keyDown(at: now))
        await rig.timer.fireAll()
        #expect(await rig.orchestrator.isCapturing())

        await collector.cancel()
    }

    @Test("session dies, then user releases key: keyUp is a no-op (no deadlock, single ended)")
    func sessionStreamEndsThenKeyUp() async {
        let rig = makeScriptableRig()
        let collector = EventCollector()
        await collector.start(stream: rig.orchestrator.events)

        await rig.orchestrator.handle(hotkeyEvent: .keyDown(at: now))
        await rig.timer.fireAll()

        // Mid-press-hold the session dies. Without the fix, the trailing
        // keyUp deadlocks in awaitFinal forever.
        await rig.provider.lastSession?.close()
        for _ in 0..<8 { await Task.yield() }

        await rig.orchestrator.handle(hotkeyEvent: .keyUp(at: now))

        let events = await collector.snapshot()
        let endedCount = events.filter {
            if case .sessionEnded = $0 { return true }
            return false
        }.count
        #expect(endedCount == 1)
        #expect(await !rig.orchestrator.isCapturing())
        #expect(await rig.injector.received.isEmpty)

        await collector.cancel()
    }

    @Test("hands-free promotion: speculative session ends, hands-free starts")
    func handsFreePromotionEvents() async {
        let rig = makeScriptableRig()
        let collector = EventCollector()
        await collector.start(stream: rig.orchestrator.events)

        await rig.orchestrator.handle(hotkeyEvent: .keyDown(at: now))   // pressed
        await rig.orchestrator.handle(hotkeyEvent: .keyUp(at: now))     // tapPending
        await rig.orchestrator.handle(hotkeyEvent: .keyDown(at: now))   // promote → handsFree

        // Now the second session is open. Drive it to completion.
        await rig.provider.yieldFinal("hands-free output")
        await rig.orchestrator.handle(hotkeyEvent: .keyDown(at: now))   // exiting (stop)
        await rig.orchestrator.handle(hotkeyEvent: .keyUp(at: now))     // idle

        let events = await collector.snapshot()
        let starts = events.filter { event in
            if case .sessionStarted = event { return true }
            return false
        }
        // Two starts: the speculative pressHold + the hands-free session.
        #expect(starts.count == 2)
        // Final inject is the hands-free text.
        #expect(events.contains(.sessionEnded(injectedText: "hands-free output")))
        #expect(await rig.injector.received == ["hands-free output"])

        await collector.cancel()
    }
}
