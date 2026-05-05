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
    ///   `.keyDown`/`.keyUp` events with `pressFlag == nil`.
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
            if activation.pressFlag == nil, keyCode == activation.keyCode {
                return .keyDown(at: now)
            }
            if cancel.pressFlag == nil, keyCode == cancel.keyCode {
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
            if activation.pressFlag == nil, keyCode == activation.keyCode {
                return .keyDown(at: now)
            }
            if cancel.pressFlag == nil, keyCode == cancel.keyCode {
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
#endif
