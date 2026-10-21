#if os(macOS)
import Testing
import Foundation
import CoreGraphics
@testable import PlatformApple
@testable import Hotkey

private let now = Date(timeIntervalSinceReferenceDate: 0)

@Suite("HotkeySourceMac: cancel-key consumption gate")
struct HotkeyTapConsumeTests {
    @Test("idle: cancelKey is not consumed (Esc still reaches the focused app)")
    func idleDoesNotConsumeCancel() {
        #expect(shouldConsume(translated: .cancelKey(at: now), isDictating: false) == false)
    }

    @Test("dictating: cancelKey is consumed")
    func dictatingConsumesCancel() {
        #expect(shouldConsume(translated: .cancelKey(at: now), isDictating: true) == true)
    }

    @Test("dictating: keyDown is not consumed (activation key passthrough preserved)")
    func dictatingDoesNotConsumeKeyDown() {
        #expect(shouldConsume(translated: .keyDown(at: now), isDictating: true) == false)
    }

    @Test("dictating: keyUp is not consumed")
    func dictatingDoesNotConsumeKeyUp() {
        #expect(shouldConsume(translated: .keyUp(at: now), isDictating: true) == false)
    }

    @Test("dictating: timerExpired is not consumed (synthetic, not from a real event)")
    func dictatingDoesNotConsumeTimer() {
        #expect(shouldConsume(translated: .timerExpired, isDictating: true) == false)
    }

    @Test("nil translation: never consumed regardless of state")
    func nilTranslationNeverConsumed() {
        #expect(shouldConsume(translated: nil, isDictating: false) == false)
        #expect(shouldConsume(translated: nil, isDictating: true) == false)
    }
}

@Suite("ActivationKeyGate: activation-key pairing and consumption")
struct ActivationKeyGateTests {
    private let chord = HotkeyBinding(keyCode: 0x19, pressFlag: nil, modifiers: [.maskCommand, .maskShift])
    private let mouse4 = HotkeyBinding(keyCode: 0xF003, pressFlag: nil)

    @Test("matched press, auto-repeats and release are all swallowed")
    func matchedPressSwallowed() {
        var gate = ActivationKeyGate()
        let down = gate.filter(.keyDown(at: now), type: .keyDown, keyCode: 0x19, activation: chord)
        #expect(down == ActivationKeyGate.Decision(event: .keyDown(at: now), consume: true))
        #expect(gate.held)

        // Auto-repeat: the translator returns nil, but the key is held.
        let repeatDown = gate.filter(nil, type: .keyDown, keyCode: 0x19, activation: chord)
        #expect(repeatDown == ActivationKeyGate.Decision(event: nil, consume: true))

        let up = gate.filter(.keyUp(at: now), type: .keyUp, keyCode: 0x19, activation: chord)
        #expect(up == ActivationKeyGate.Decision(event: .keyUp(at: now), consume: true))
        #expect(!gate.held)
    }

    @Test("unmatched press passes through, and so does its release")
    func unmatchedPressPassesThrough() {
        var gate = ActivationKeyGate()
        // Bare "9": translator returned nil because the chord didn't match.
        let down = gate.filter(nil, type: .keyDown, keyCode: 0x19, activation: chord)
        #expect(down == ActivationKeyGate.Decision(event: nil, consume: false))

        // Its release still translates to .keyUp (key code match), but the
        // gate drops it so the FSM never sees an unpaired release.
        let up = gate.filter(.keyUp(at: now), type: .keyUp, keyCode: 0x19, activation: chord)
        #expect(up == ActivationKeyGate.Decision(event: nil, consume: false))
    }

    @Test("mouse-button activation is swallowed (no browser Back/Forward)")
    func mouseButtonSwallowed() {
        var gate = ActivationKeyGate()
        let down = gate.filter(.keyDown(at: now), type: .otherMouseDown, keyCode: 0xF003, activation: mouse4)
        #expect(down.consume)
        let up = gate.filter(.keyUp(at: now), type: .otherMouseUp, keyCode: 0xF003, activation: mouse4)
        #expect(up == ActivationKeyGate.Decision(event: .keyUp(at: now), consume: true))
    }

    @Test("modifier-only activation is never swallowed")
    func modifierOnlyPassesThrough() {
        var gate = ActivationKeyGate()
        let down = gate.filter(.keyDown(at: now), type: .flagsChanged, keyCode: 0x3D, activation: .rightOption)
        #expect(down == ActivationKeyGate.Decision(event: .keyDown(at: now), consume: false))
        #expect(!gate.held)
    }

    @Test("other keys pass through untouched")
    func unrelatedKeyPassesThrough() {
        var gate = ActivationKeyGate()
        let cancel = gate.filter(.cancelKey(at: now), type: .keyDown, keyCode: 0x35, activation: chord)
        #expect(cancel == ActivationKeyGate.Decision(event: .cancelKey(at: now), consume: false))
    }

    @Test("releaseLost clears a held press")
    func releaseLostClearsHeld() {
        var gate = ActivationKeyGate()
        _ = gate.filter(.keyDown(at: now), type: .keyDown, keyCode: 0x19, activation: chord)
        gate.releaseLost()
        #expect(!gate.held)
    }
}
#endif
