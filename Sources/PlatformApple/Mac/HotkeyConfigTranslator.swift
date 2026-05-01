#if os(macOS)
import CoreGraphics
import Core

/// Maps the platform-agnostic `Core.HotkeyConfig` (persisted user choice)
/// into the runtime-shaped `HotkeyBinding` pair that `HotkeySourceMac`
/// consumes.
///
/// The two representations differ in one important way: `HotkeyConfig`
/// stores a single `keyCode` plus a chord-modifier mask, while
/// `HotkeyBinding` distinguishes "modifier-only activation" (right Option,
/// left Option, fn) from "regular key" using a side-specific
/// `CGEventFlags` bit. We resolve that here by recognising known modifier
/// key codes and supplying their `pressFlag`; everything else is treated
/// as a regular key (`pressFlag: nil`), at which point the `modifiers`
/// mask is honoured via `HotkeyEventTranslator`'s chord matching.
///
/// Today the platform layer only fully supports the modifier-only activations
/// (right/left Option) and regular keys without modifier-mask matching; the
/// Shortcuts settings pane (planned for milestone 1.3) will surface that
/// limitation by constraining the picker. Expanding to arbitrary chords is
/// tracked as a follow-up.
public enum HotkeyConfigTranslator {
    /// Translate a `HotkeyConfig` into the `(activation, cancel)` pair the
    /// platform source expects. Returns `nil` for `cancel` if the config's
    /// cancel slot is set to "no cancel key" (sentinel: keyCode == 0).
    public static func bindings(
        from config: HotkeyConfig
    ) -> (activation: HotkeyBinding, cancel: HotkeyBinding) {
        let activation = binding(keyCode: config.keyCode)
        let cancel = binding(keyCode: config.cancelKeyCode)
        return (activation, cancel)
    }

    /// Build a `HotkeyBinding` from a raw key code, picking the right
    /// `pressFlag` for known modifier keys.
    public static func binding(keyCode: UInt16) -> HotkeyBinding {
        switch keyCode {
        case 0x3D:  // right Option
            return .rightOption
        case 0x3A:  // left Option
            return .leftOption
        case 0x35:  // Escape
            return .escape
        default:
            return HotkeyBinding(keyCode: CGKeyCode(keyCode), pressFlag: nil)
        }
    }
}
#endif
