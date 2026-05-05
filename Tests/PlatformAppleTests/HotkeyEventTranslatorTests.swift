#if os(macOS)
import Testing
import Foundation
import CoreGraphics
@testable import PlatformApple
@testable import Hotkey
import Core

private let now = Date(timeIntervalSinceReferenceDate: 0)

@Suite("HotkeyEventTranslator: modifier-only activation (right Option)")
struct ModifierActivationTests {
    let translator = HotkeyEventTranslator(
        activation: .rightOption,
        cancel: .escape
    )

    @Test("right-Option press → keyDown")
    func pressFiresKeyDown() {
        let event = translator.translate(
            type: .flagsChanged,
            keyCode: 0x3D,
            flags: CGEventFlags(rawValue: 0x40 | 0x80000), // R-flag + maskAlternate
            autoRepeat: false,
            now: now
        )
        #expect(event == .keyDown(at: now))
    }

    @Test("right-Option release → keyUp")
    func releaseFiresKeyUp() {
        let event = translator.translate(
            type: .flagsChanged,
            keyCode: 0x3D,
            flags: [],
            autoRepeat: false,
            now: now
        )
        #expect(event == .keyUp(at: now))
    }

    @Test("left-Option flagsChanged with same maskAlternate is ignored")
    func leftOptionIgnored() {
        let event = translator.translate(
            type: .flagsChanged,
            keyCode: 0x3A, // left Option
            flags: CGEventFlags(rawValue: 0x20 | 0x80000),
            autoRepeat: false,
            now: now
        )
        #expect(event == nil)
    }

    @Test("right-Option still pressed (maskAlternate set without R-bit) → keyUp")
    func sharedMaskWithoutDeviceBitMeansReleased() {
        // Scenario: left-Option held (sets maskAlternate), then right-Option
        // released. CGEventFlags shows maskAlternate still set (from left)
        // but the right-side bit (0x40) is clear → translator should report
        // release of right-Option, not press.
        let event = translator.translate(
            type: .flagsChanged,
            keyCode: 0x3D,
            flags: CGEventFlags(rawValue: 0x80000), // maskAlternate, no 0x40
            autoRepeat: false,
            now: now
        )
        #expect(event == .keyUp(at: now))
    }

    @Test("regular keyDown for the modifier-only binding is not used")
    func ignoresKeyDownForModifierBinding() {
        let event = translator.translate(
            type: .keyDown,
            keyCode: 0x3D,
            flags: [],
            autoRepeat: false,
            now: now
        )
        #expect(event == nil)
    }
}

@Suite("HotkeyEventTranslator: cancel key (Escape)")
struct CancelKeyTests {
    let translator = HotkeyEventTranslator(
        activation: .rightOption,
        cancel: .escape
    )

    @Test("Escape keyDown → cancelKey")
    func escapeKeyDown() {
        let event = translator.translate(
            type: .keyDown,
            keyCode: 0x35,
            flags: [],
            autoRepeat: false,
            now: now
        )
        #expect(event == .cancelKey(at: now))
    }

    @Test("Escape keyUp is ignored")
    func escapeKeyUpIgnored() {
        let event = translator.translate(
            type: .keyUp,
            keyCode: 0x35,
            flags: [],
            autoRepeat: false,
            now: now
        )
        #expect(event == nil)
    }

    @Test("auto-repeat Escape keyDown is suppressed")
    func escapeAutoRepeatIgnored() {
        let event = translator.translate(
            type: .keyDown,
            keyCode: 0x35,
            flags: [],
            autoRepeat: true,
            now: now
        )
        #expect(event == nil)
    }
}

@Suite("HotkeyEventTranslator: misc")
struct MiscTranslatorTests {
    let translator = HotkeyEventTranslator(
        activation: .rightOption,
        cancel: .escape
    )

    @Test("unrelated key is ignored")
    func unrelatedKeyIgnored() {
        let event = translator.translate(
            type: .keyDown,
            keyCode: 0x00, // 'a'
            flags: [],
            autoRepeat: false,
            now: now
        )
        #expect(event == nil)
    }

    @Test("flagsChanged for an unrelated modifier is ignored")
    func unrelatedFlagsChanged() {
        let event = translator.translate(
            type: .flagsChanged,
            keyCode: 0x37, // left Cmd
            flags: CGEventFlags(rawValue: 0x100000),
            autoRepeat: false,
            now: now
        )
        #expect(event == nil)
    }
}

@Suite("HotkeyEventTranslator: mouse-button activation")
struct MouseButtonActivationTests {
    /// Bind activation to Mouse 4 (NSEvent.buttonNumber == 3).
    let translator = HotkeyEventTranslator(
        activation: HotkeyBinding(
            keyCode: CGKeyCode(MouseButtonSentinel.keyCode(forButton: 3)),
            pressFlag: nil
        ),
        cancel: .escape
    )

    @Test("otherMouseDown for Mouse4 → keyDown")
    func mouse4Down() {
        let event = translator.translate(
            type: .otherMouseDown,
            keyCode: CGKeyCode(MouseButtonSentinel.keyCode(forButton: 3)),
            flags: [],
            autoRepeat: false,
            now: now
        )
        #expect(event == .keyDown(at: now))
    }

    @Test("otherMouseUp for Mouse4 → keyUp")
    func mouse4Up() {
        let event = translator.translate(
            type: .otherMouseUp,
            keyCode: CGKeyCode(MouseButtonSentinel.keyCode(forButton: 3)),
            flags: [],
            autoRepeat: false,
            now: now
        )
        #expect(event == .keyUp(at: now))
    }

    @Test("otherMouseDown for a different button is ignored")
    func differentButtonIgnored() {
        let event = translator.translate(
            type: .otherMouseDown,
            keyCode: CGKeyCode(MouseButtonSentinel.keyCode(forButton: 4)), // Mouse5
            flags: [],
            autoRepeat: false,
            now: now
        )
        #expect(event == nil)
    }

    @Test("regular keyDown does not match the mouse-sentinel binding")
    func keyDownDoesNotMatchSentinel() {
        // A keyboard event surfaced with a sentinel-shaped keyCode should not
        // arrive in practice (mac CGKeyCodes are ≤ 0x7F), but verify the
        // translator's keyDown branch doesn't accidentally fire on a real
        // keyboard press.
        let event = translator.translate(
            type: .keyDown,
            keyCode: 0x00, // 'a'
            flags: [],
            autoRepeat: false,
            now: now
        )
        #expect(event == nil)
    }
}

@Suite("HotkeyEventTranslator: regular-key activation (Escape)")
struct RegularKeyActivationTests {
    /// Demonstrates that bindings configured as regular keys (no pressFlag)
    /// fire on .keyDown / .keyUp rather than .flagsChanged.
    let translator = HotkeyEventTranslator(
        activation: .escape, // unusual choice, but valid — used to test the path
        cancel: HotkeyBinding(keyCode: 0x32, pressFlag: nil) // grave/backtick
    )

    @Test("Escape keyDown → keyDown for activation binding")
    func keyDown() {
        let event = translator.translate(
            type: .keyDown,
            keyCode: 0x35,
            flags: [],
            autoRepeat: false,
            now: now
        )
        #expect(event == .keyDown(at: now))
    }

    @Test("Escape keyUp → keyUp for activation binding")
    func keyUp() {
        let event = translator.translate(
            type: .keyUp,
            keyCode: 0x35,
            flags: [],
            autoRepeat: false,
            now: now
        )
        #expect(event == .keyUp(at: now))
    }

    @Test("auto-repeat keyDown is suppressed for activation binding")
    func autoRepeatSuppressed() {
        let event = translator.translate(
            type: .keyDown,
            keyCode: 0x35,
            flags: [],
            autoRepeat: true,
            now: now
        )
        #expect(event == nil)
    }
}
#endif
