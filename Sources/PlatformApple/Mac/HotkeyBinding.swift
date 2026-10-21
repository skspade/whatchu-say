#if os(macOS)
import CoreGraphics

/// Defines what physical key activates dictation.
///
/// We support two shapes:
/// 1. **Modifier-only** (e.g. right Option, fn) — delivered as
///    `.flagsChanged` events. Press/release is detected from the
///    *device-specific* flag bit (left vs right Option both toggle
///    `.maskAlternate`, so we use the side-specific bit to disambiguate).
/// 2. **Regular key** (e.g. Esc, F19, ⌘⇧9) — delivered as `.keyDown` /
///    `.keyUp`, `pressFlag` is `nil`, optionally with chord `modifiers`.
public struct HotkeyBinding: Sendable, Equatable {
    /// The modifiers that take part in chord matching. fn is excluded because
    /// macOS sets it on F-keys and arrows by itself, and Caps Lock because
    /// it's a toggle, not something the user holds.
    public static let chordMask: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]

    public let keyCode: CGKeyCode
    /// Device-specific CGEventFlags bit for modifier keys; `nil` for regular
    /// keys (use the event type to detect press vs release).
    public let pressFlag: CGEventFlags?
    /// Chord modifiers (a subset of `chordMask`) for regular-key bindings.
    /// Empty means "match the key regardless of held modifiers".
    public let modifiers: CGEventFlags

    public init(keyCode: CGKeyCode, pressFlag: CGEventFlags?, modifiers: CGEventFlags = []) {
        self.keyCode = keyCode
        self.pressFlag = pressFlag
        self.modifiers = modifiers.intersection(Self.chordMask)
    }

    /// Activation matching: the held chord must be exactly `modifiers`, so a
    /// ⌘⇧9 binding fires on neither a bare 9 nor ⌘⌥⇧9.
    func chordMatches(_ flags: CGEventFlags) -> Bool {
        modifiers.isEmpty || flags.intersection(Self.chordMask) == modifiers
    }

    /// Cancel matching: `modifiers` must be held, extras allowed — the
    /// activation key or chord is usually still held when cancel is pressed.
    func modifiersHeld(in flags: CGEventFlags) -> Bool {
        flags.isSuperset(of: modifiers)
    }

    /// Default activation: right Option. Side-specific flag bit `0x40` lets
    /// us tell right-Option apart from left-Option when both happen to be
    /// held — the device-independent `.maskAlternate` is shared.
    public static let rightOption = HotkeyBinding(
        keyCode: 0x3D,
        pressFlag: CGEventFlags(rawValue: 0x40)
    )

    public static let leftOption = HotkeyBinding(
        keyCode: 0x3A,
        pressFlag: CGEventFlags(rawValue: 0x20)
    )

    public static let escape = HotkeyBinding(keyCode: 0x35, pressFlag: nil)
}
#endif
