#if os(macOS)
import Foundation
import CoreGraphics
import Hotkey

/// Pure translation from CGEvent fields to `HotkeyEvent`. Lives separately
/// from `HotkeySourceMac` so it can be unit-tested without a real event tap.
struct HotkeyEventTranslator: Sendable {
    let activation: HotkeyBinding
    let cancel: HotkeyBinding

    /// Map a single CGEvent (already decoded into its primitive fields) to
    /// a `HotkeyEvent`, or `nil` if the event isn't relevant.
    ///
    /// - Auto-repeat `.keyDown` events are silently dropped: macOS sends
    ///   synthetic repeats while a key is held, but the FSM only cares about
    ///   the original press.
    /// - Modifier-only bindings ignore `.keyDown`/`.keyUp` and use
    ///   `.flagsChanged` with the device-specific flag bit.
    /// - Regular-key bindings ignore `.flagsChanged` and use
    ///   `.keyDown`/`.keyUp` events with `pressFlag == nil`. A press only
    ///   counts if its chord matches (`HotkeyBinding.chordMatches`); releases
    ///   match on key code alone, since modifiers are often let go first.
    ///   `ActivationKeyGate` drops releases whose press didn't match.
    func translate(
        type: CGEventType,
        keyCode: CGKeyCode,
        flags: CGEventFlags,
        autoRepeat: Bool,
        now: Date
    ) -> HotkeyEvent? {
        switch type {
        case .keyDown:
            if autoRepeat { return nil }
            if activation.pressFlag == nil, keyCode == activation.keyCode,
               activation.chordMatches(flags) {
                return .keyDown(at: now)
            }
            if cancel.pressFlag == nil, keyCode == cancel.keyCode,
               cancel.modifiersHeld(in: flags) {
                return .cancelKey(at: now)
            }
            return nil

        case .keyUp:
            if activation.pressFlag == nil, keyCode == activation.keyCode {
                return .keyUp(at: now)
            }
            return nil

        case .otherMouseDown:
            // Mouse-button bindings encode the button number into `keyCode`
            // via `MouseButtonSentinel` (see HotkeySourceMac.handle). Since
            // sentinel codes (≥ 0xF000) can't collide with real keyboard
            // CGKeyCodes (≤ 0x7F), the same equality test is sufficient.
            if activation.pressFlag == nil, keyCode == activation.keyCode,
               activation.chordMatches(flags) {
                return .keyDown(at: now)
            }
            if cancel.pressFlag == nil, keyCode == cancel.keyCode,
               cancel.modifiersHeld(in: flags) {
                return .cancelKey(at: now)
            }
            return nil

        case .otherMouseUp:
            if activation.pressFlag == nil, keyCode == activation.keyCode {
                return .keyUp(at: now)
            }
            return nil

        case .flagsChanged:
            if let pressFlag = activation.pressFlag, keyCode == activation.keyCode {
                return flags.contains(pressFlag)
                    ? .keyDown(at: now)
                    : .keyUp(at: now)
            }
            if let pressFlag = cancel.pressFlag, keyCode == cancel.keyCode {
                // Only fire on press — releases of a modifier-only cancel key
                // shouldn't double-cancel.
                if flags.contains(pressFlag) {
                    return .cancelKey(at: now)
                }
            }
            return nil

        default:
            return nil
        }
    }
}

/// Pairs a regular-key / mouse-button activation's release with the press
/// that matched its chord, and decides which raw events to swallow so the
/// focused app never sees the hotkey: the matched press, its auto-repeats,
/// and its release. A press that didn't match (a bare 9 when the binding
/// is ⌘⇧9) passes through untouched, release included.
///
/// Modifier-only bindings (`.flagsChanged`) are never gated or swallowed:
/// eating a modifier event would desync the focused app's modifier state.
struct ActivationKeyGate: Sendable {
    struct Decision: Sendable, Equatable {
        /// Event to forward to the FSM, if any.
        let event: HotkeyEvent?
        /// Whether the C callback should swallow the raw CGEvent.
        let consume: Bool
    }

    /// True between a matched activation press and its release.
    private(set) var held = false

    mutating func filter(
        _ translated: HotkeyEvent?,
        type: CGEventType,
        keyCode: CGKeyCode,
        activation: HotkeyBinding
    ) -> Decision {
        guard activation.pressFlag == nil, keyCode == activation.keyCode else {
            return Decision(event: translated, consume: false)
        }
        switch type {
        case .keyDown, .otherMouseDown:
            if case .keyDown? = translated {
                held = true
                return Decision(event: translated, consume: true)
            }
            // Auto-repeat while held (the translator drops repeats), or a
            // press whose chord didn't match.
            return Decision(event: translated, consume: held)
        case .keyUp, .otherMouseUp:
            guard held else { return Decision(event: nil, consume: false) }
            held = false
            return Decision(event: translated, consume: true)
        default:
            return Decision(event: translated, consume: false)
        }
    }

    /// Forget a press whose release was lost (event tap disabled meanwhile).
    mutating func releaseLost() {
        held = false
    }
}
#endif
