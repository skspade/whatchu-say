import Testing
import Foundation
@testable import Hotkey

// MARK: - Helpers

private let pressHoldMs: Duration = .milliseconds(250)
private let doubleTapMs: Duration = .milliseconds(300)
private let now = Date(timeIntervalSinceReferenceDate: 0)

extension ActivationStateMachine {
    /// Drives a sequence of events and returns all outputs concatenated.
    fileprivate func run(_ events: [HotkeyEvent]) -> [HotkeyOutput] {
        var outputs: [HotkeyOutput] = []
        for event in events {
            outputs.append(contentsOf: handle(event))
        }
        return outputs
    }
}

// MARK: - Idle state

@Suite("ActivationStateMachine: idle state")
struct IdleStateTests {
    @Test("keyDown starts press-hold dictation and schedules threshold timer")
    func idleKeyDown() async {
        let fsm = ActivationStateMachine()
        let outputs = await fsm.handle(.keyDown(at: now))
        #expect(outputs == [
            .startDictation(mode: .pressHold),
            .scheduleTimer(after: pressHoldMs),
        ])
    }

    @Test("keyUp in idle is a no-op")
    func idleKeyUp() async {
        let fsm = ActivationStateMachine()
        let outputs = await fsm.handle(.keyUp(at: now))
        #expect(outputs.isEmpty)
    }

    @Test("cancelKey in idle is a no-op")
    func idleCancelKey() async {
        let fsm = ActivationStateMachine()
        let outputs = await fsm.handle(.cancelKey(at: now))
        #expect(outputs.isEmpty)
    }

    @Test("timerExpired in idle is a no-op")
    func idleTimerExpired() async {
        let fsm = ActivationStateMachine()
        let outputs = await fsm.handle(.timerExpired)
        #expect(outputs.isEmpty)
    }
}

// MARK: - Pressed state

@Suite("ActivationStateMachine: pressed state")
struct PressedStateTests {
    @Test("repeat keyDown while pressed is a no-op")
    func pressedKeyDownNoop() async {
        let fsm = ActivationStateMachine()
        _ = await fsm.handle(.keyDown(at: now))
        let outputs = await fsm.handle(.keyDown(at: now))
        #expect(outputs.isEmpty)
    }

    @Test("keyUp before threshold transitions to tapPending and re-schedules timer")
    func pressedKeyUpBeforeThreshold() async {
        let fsm = ActivationStateMachine()
        _ = await fsm.handle(.keyDown(at: now))
        let outputs = await fsm.handle(.keyUp(at: now))
        #expect(outputs == [
            .cancelTimer,
            .scheduleTimer(after: doubleTapMs),
        ])
    }

    @Test("timerExpired transitions to pressHold (no output)")
    func pressedTimerExpired() async {
        let fsm = ActivationStateMachine()
        _ = await fsm.handle(.keyDown(at: now))
        let outputs = await fsm.handle(.timerExpired)
        #expect(outputs.isEmpty)
    }

    @Test("cancelKey aborts and waits for keyUp")
    func pressedCancelKey() async {
        let fsm = ActivationStateMachine()
        _ = await fsm.handle(.keyDown(at: now))
        let outputs = await fsm.handle(.cancelKey(at: now))
        #expect(outputs == [.cancelTimer, .cancelDictation])
    }
}

// MARK: - TapPending state

@Suite("ActivationStateMachine: tapPending state")
struct TapPendingStateTests {
    /// Helper to drive into tapPending state.
    private func intoTapPending(_ fsm: ActivationStateMachine) async {
        _ = await fsm.handle(.keyDown(at: now))
        _ = await fsm.handle(.keyUp(at: now))
    }

    @Test("second keyDown within window promotes to hands-free")
    func tapPendingKeyDown() async {
        let fsm = ActivationStateMachine()
        await intoTapPending(fsm)
        let outputs = await fsm.handle(.keyDown(at: now))
        #expect(outputs == [.cancelTimer, .promoteToHandsFree])
    }

    @Test("keyUp in tapPending is a no-op")
    func tapPendingKeyUp() async {
        let fsm = ActivationStateMachine()
        await intoTapPending(fsm)
        let outputs = await fsm.handle(.keyUp(at: now))
        #expect(outputs.isEmpty)
    }

    @Test("timerExpired finalizes as a short press")
    func tapPendingTimerExpired() async {
        let fsm = ActivationStateMachine()
        await intoTapPending(fsm)
        let outputs = await fsm.handle(.timerExpired)
        #expect(outputs == [.stopDictation])
    }

    @Test("cancelKey aborts and returns to idle")
    func tapPendingCancelKey() async {
        let fsm = ActivationStateMachine()
        await intoTapPending(fsm)
        let outputs = await fsm.handle(.cancelKey(at: now))
        #expect(outputs == [.cancelTimer, .cancelDictation])
    }
}

// MARK: - PressHold state

@Suite("ActivationStateMachine: pressHold state")
struct PressHoldStateTests {
    private func intoPressHold(_ fsm: ActivationStateMachine) async {
        _ = await fsm.handle(.keyDown(at: now))
        _ = await fsm.handle(.timerExpired)
    }

    @Test("keyDown is a no-op while holding")
    func pressHoldKeyDown() async {
        let fsm = ActivationStateMachine()
        await intoPressHold(fsm)
        let outputs = await fsm.handle(.keyDown(at: now))
        #expect(outputs.isEmpty)
    }

    @Test("keyUp finalizes the dictation")
    func pressHoldKeyUp() async {
        let fsm = ActivationStateMachine()
        await intoPressHold(fsm)
        let outputs = await fsm.handle(.keyUp(at: now))
        #expect(outputs == [.stopDictation])
    }

    @Test("stale timerExpired is a no-op")
    func pressHoldTimerExpired() async {
        let fsm = ActivationStateMachine()
        await intoPressHold(fsm)
        let outputs = await fsm.handle(.timerExpired)
        #expect(outputs.isEmpty)
    }

    @Test("cancelKey aborts and waits for keyUp")
    func pressHoldCancelKey() async {
        let fsm = ActivationStateMachine()
        await intoPressHold(fsm)
        let outputs = await fsm.handle(.cancelKey(at: now))
        #expect(outputs == [.cancelDictation])
    }
}

// MARK: - PressHoldCancelled state

@Suite("ActivationStateMachine: pressHoldCancelled state")
struct PressHoldCancelledStateTests {
    private func intoPressHoldCancelled(_ fsm: ActivationStateMachine) async {
        _ = await fsm.handle(.keyDown(at: now))
        _ = await fsm.handle(.timerExpired)
        _ = await fsm.handle(.cancelKey(at: now))
    }

    @Test("keyUp returns to idle silently (no further outputs)")
    func cancelledKeyUp() async {
        let fsm = ActivationStateMachine()
        await intoPressHoldCancelled(fsm)
        let outputs = await fsm.handle(.keyUp(at: now))
        #expect(outputs.isEmpty)

        // After return to idle, a fresh keyDown should fire startDictation again.
        let next = await fsm.handle(.keyDown(at: now))
        #expect(next == [
            .startDictation(mode: .pressHold),
            .scheduleTimer(after: pressHoldMs),
        ])
    }

    @Test("repeat cancelKey is a no-op")
    func cancelledRepeatCancel() async {
        let fsm = ActivationStateMachine()
        await intoPressHoldCancelled(fsm)
        let outputs = await fsm.handle(.cancelKey(at: now))
        #expect(outputs.isEmpty)
    }

    @Test("keyDown is a no-op while cancelled-but-still-held")
    func cancelledKeyDown() async {
        let fsm = ActivationStateMachine()
        await intoPressHoldCancelled(fsm)
        let outputs = await fsm.handle(.keyDown(at: now))
        #expect(outputs.isEmpty)
    }
}

// MARK: - HandsFree state

@Suite("ActivationStateMachine: handsFree state")
struct HandsFreeStateTests {
    private func intoHandsFree(_ fsm: ActivationStateMachine) async {
        _ = await fsm.handle(.keyDown(at: now))
        _ = await fsm.handle(.keyUp(at: now))
        _ = await fsm.handle(.keyDown(at: now))
    }

    @Test("keyDown begins exit and finalizes")
    func handsFreeKeyDown() async {
        let fsm = ActivationStateMachine()
        await intoHandsFree(fsm)
        let outputs = await fsm.handle(.keyDown(at: now))
        #expect(outputs == [.stopDictation])
    }

    @Test("keyUp during hands-free is a no-op (we never logically held it)")
    func handsFreeKeyUp() async {
        let fsm = ActivationStateMachine()
        await intoHandsFree(fsm)
        let outputs = await fsm.handle(.keyUp(at: now))
        #expect(outputs.isEmpty)
    }

    @Test("cancelKey aborts and returns to idle")
    func handsFreeCancelKey() async {
        let fsm = ActivationStateMachine()
        await intoHandsFree(fsm)
        let outputs = await fsm.handle(.cancelKey(at: now))
        #expect(outputs == [.cancelDictation])
    }

    @Test("timerExpired in hands-free is a no-op")
    func handsFreeTimerExpired() async {
        let fsm = ActivationStateMachine()
        await intoHandsFree(fsm)
        let outputs = await fsm.handle(.timerExpired)
        #expect(outputs.isEmpty)
    }
}

// MARK: - HandsFreeExiting state

@Suite("ActivationStateMachine: handsFreeExiting state")
struct HandsFreeExitingStateTests {
    private func intoHandsFreeExiting(_ fsm: ActivationStateMachine) async {
        _ = await fsm.handle(.keyDown(at: now))
        _ = await fsm.handle(.keyUp(at: now))
        _ = await fsm.handle(.keyDown(at: now))   // promoteToHandsFree
        _ = await fsm.handle(.keyDown(at: now))   // exit press
    }

    @Test("trailing keyUp returns to idle without re-arming dictation")
    func exitingKeyUp() async {
        let fsm = ActivationStateMachine()
        await intoHandsFreeExiting(fsm)
        let outputs = await fsm.handle(.keyUp(at: now))
        #expect(outputs.isEmpty)

        // Confirm we're in idle by sending a fresh keyDown.
        let next = await fsm.handle(.keyDown(at: now))
        #expect(next == [
            .startDictation(mode: .pressHold),
            .scheduleTimer(after: pressHoldMs),
        ])
    }

    @Test("repeat keyDown during exit is a no-op")
    func exitingKeyDown() async {
        let fsm = ActivationStateMachine()
        await intoHandsFreeExiting(fsm)
        let outputs = await fsm.handle(.keyDown(at: now))
        #expect(outputs.isEmpty)
    }
}

// MARK: - End-to-end sequences

@Suite("ActivationStateMachine: full sequences")
struct SequenceTests {
    @Test("press-and-hold: down → timer → up emits start, schedule, stop")
    func pressAndHold() async {
        let fsm = ActivationStateMachine()
        let outputs = await fsm.run([
            .keyDown(at: now),
            .timerExpired,
            .keyUp(at: now),
        ])
        #expect(outputs == [
            .startDictation(mode: .pressHold),
            .scheduleTimer(after: pressHoldMs),
            .stopDictation,
        ])
    }

    @Test("short press: down → up → timer emits start, schedule, cancel+reschedule, stop")
    func shortPress() async {
        let fsm = ActivationStateMachine()
        let outputs = await fsm.run([
            .keyDown(at: now),
            .keyUp(at: now),
            .timerExpired,
        ])
        #expect(outputs == [
            .startDictation(mode: .pressHold),
            .scheduleTimer(after: pressHoldMs),
            .cancelTimer,
            .scheduleTimer(after: doubleTapMs),
            .stopDictation,
        ])
    }

    @Test("double-tap → exit: enters hands-free, exits cleanly on next press")
    func doubleTapEnterAndExit() async {
        let fsm = ActivationStateMachine()
        let outputs = await fsm.run([
            .keyDown(at: now),    // → pressed
            .keyUp(at: now),      // → tapPending
            .keyDown(at: now),    // → handsFree (promote)
            .keyDown(at: now),    // → handsFreeExiting (stop)
            .keyUp(at: now),      // → idle
        ])
        #expect(outputs == [
            .startDictation(mode: .pressHold),
            .scheduleTimer(after: pressHoldMs),
            .cancelTimer,
            .scheduleTimer(after: doubleTapMs),
            .cancelTimer,
            .promoteToHandsFree,
            .stopDictation,
        ])
    }

    @Test("cancel during press-hold: aborts and absorbs trailing keyUp")
    func cancelDuringPressHold() async {
        let fsm = ActivationStateMachine()
        let outputs = await fsm.run([
            .keyDown(at: now),
            .timerExpired,
            .cancelKey(at: now),
            .keyUp(at: now),
        ])
        #expect(outputs == [
            .startDictation(mode: .pressHold),
            .scheduleTimer(after: pressHoldMs),
            .cancelDictation,
        ])
    }

    @Test("cancel during hands-free: aborts immediately, no exit dance needed")
    func cancelDuringHandsFree() async {
        let fsm = ActivationStateMachine()
        let outputs = await fsm.run([
            .keyDown(at: now),
            .keyUp(at: now),
            .keyDown(at: now),       // → handsFree
            .cancelKey(at: now),     // → idle (cancel)
        ])
        #expect(outputs == [
            .startDictation(mode: .pressHold),
            .scheduleTimer(after: pressHoldMs),
            .cancelTimer,
            .scheduleTimer(after: doubleTapMs),
            .cancelTimer,
            .promoteToHandsFree,
            .cancelDictation,
        ])

        // After cancel, FSM is idle; next keyDown starts fresh.
        let next = await fsm.handle(.keyDown(at: now))
        #expect(next == [
            .startDictation(mode: .pressHold),
            .scheduleTimer(after: pressHoldMs),
        ])
    }

    @Test("cancel during early press: aborts before press-hold timer fires")
    func cancelDuringEarlyPress() async {
        let fsm = ActivationStateMachine()
        let outputs = await fsm.run([
            .keyDown(at: now),
            .cancelKey(at: now),   // before threshold
            .keyUp(at: now),       // absorbed by pressHoldCancelled
        ])
        #expect(outputs == [
            .startDictation(mode: .pressHold),
            .scheduleTimer(after: pressHoldMs),
            .cancelTimer,
            .cancelDictation,
        ])
    }
}

// MARK: - Reset

@Suite("ActivationStateMachine: reset")
struct ResetTests {
    @Test("reset from pressHold returns to idle")
    func resetFromPressHold() async {
        let fsm = ActivationStateMachine()
        _ = await fsm.handle(.keyDown(at: now))
        _ = await fsm.handle(.timerExpired)   // → pressHold
        await fsm.reset()

        let outputs = await fsm.handle(.keyDown(at: now))
        #expect(outputs == [
            .startDictation(mode: .pressHold),
            .scheduleTimer(after: pressHoldMs),
        ])
    }

    @Test("reset from handsFree returns to idle")
    func resetFromHandsFree() async {
        let fsm = ActivationStateMachine()
        _ = await fsm.handle(.keyDown(at: now))
        _ = await fsm.handle(.keyUp(at: now))
        _ = await fsm.handle(.keyDown(at: now))   // → handsFree
        await fsm.reset()

        let outputs = await fsm.handle(.keyDown(at: now))
        #expect(outputs == [
            .startDictation(mode: .pressHold),
            .scheduleTimer(after: pressHoldMs),
        ])
    }

    @Test("reset from idle is a no-op")
    func resetFromIdle() async {
        let fsm = ActivationStateMachine()
        await fsm.reset()
        let outputs = await fsm.handle(.keyDown(at: now))
        #expect(outputs == [
            .startDictation(mode: .pressHold),
            .scheduleTimer(after: pressHoldMs),
        ])
    }
}

// MARK: - Custom config

@Suite("ActivationStateMachine: custom config")
struct CustomConfigTests {
    @Test("threshold values from HotkeyConfig are propagated to scheduleTimer outputs")
    func customThresholds() async {
        let custom = HotkeyConfig(
            pressHoldThreshold: .milliseconds(400),
            doubleTapWindow: .milliseconds(500)
        )
        let fsm = ActivationStateMachine(config: custom)
        let down = await fsm.handle(.keyDown(at: now))
        #expect(down == [
            .startDictation(mode: .pressHold),
            .scheduleTimer(after: .milliseconds(400)),
        ])

        let up = await fsm.handle(.keyUp(at: now))
        #expect(up == [
            .cancelTimer,
            .scheduleTimer(after: .milliseconds(500)),
        ])
    }
}
