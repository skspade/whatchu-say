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
/// Only the right/left Option modifier-only activations are supported; the
/// recorder in the Shortcuts pane captures regular keys (with chords) and
/// mouse buttons, never modifier-only presses.
public enum HotkeyConfigTranslator {
    /// Translate a `HotkeyConfig` into the `(activation, cancel)` pair the
    /// platform source expects. Returns `nil` for `cancel` if the config's
    /// cancel slot is set to "no cancel key" (sentinel: keyCode == 0).
    public static func bindings(
        from config: HotkeyConfig
    ) -> (activation: HotkeyBinding, cancel: HotkeyBinding) {
        let activation = binding(keyCode: config.keyCode, modifiers: config.modifiers)
        let cancel = binding(keyCode: config.cancelKeyCode, modifiers: config.cancelModifiers)
        return (activation, cancel)
    }

    /// Build a `HotkeyBinding` from a raw key code, picking the right
    /// `pressFlag` for known modifier keys. `modifiers` only applies to
    /// regular keys.
    public static func binding(keyCode: UInt16, modifiers: ModifierSet = []) -> HotkeyBinding {
        switch keyCode {
        case 0x3D:  // right Option
            return .rightOption
        case 0x3A:  // left Option
            return .leftOption
        default:
            return HotkeyBinding(
                keyCode: CGKeyCode(keyCode),
                pressFlag: nil,
                modifiers: chordFlags(from: modifiers)
            )
        }
    }

    /// Map the persisted modifier set onto `CGEventFlags`. fn and Caps Lock
    /// are dropped (see `HotkeyBinding.chordMask`) — the recorder picks up fn
    /// on every F-key press and Caps Lock whenever it happens to be on.
    static func chordFlags(from modifiers: ModifierSet) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.option)  { flags.insert(.maskAlternate) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.shift)   { flags.insert(.maskShift) }
        return flags
    }
}
#endif
