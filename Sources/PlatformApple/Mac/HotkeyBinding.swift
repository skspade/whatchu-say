#if os(macOS)
import CoreGraphics

/// Defines what physical key activates dictation.
///
/// We support two shapes:
/// 1. **Modifier-only** (e.g. right Option, fn) — delivered as
///    `.flagsChanged` events. Press/release is detected from the
///    *device-specific* flag bit (left vs right Option both toggle
///    `.maskAlternate`, so we use the side-specific bit to disambiguate).
/// 2. **Regular key** (e.g. Esc, F19) — delivered as `.keyDown` / `.keyUp`,
///    `pressFlag` is `nil`.
public struct HotkeyBinding: Sendable, Equatable {
    public let keyCode: CGKeyCode
    /// Device-specific CGEventFlags bit for modifier keys; `nil` for regular
    /// keys (use the event type to detect press vs release).
    public let pressFlag: CGEventFlags?

    public init(keyCode: CGKeyCode, pressFlag: CGEventFlags?) {
        self.keyCode = keyCode
        self.pressFlag = pressFlag
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
