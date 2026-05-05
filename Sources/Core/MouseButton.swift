import Foundation

/// Encodes "mouse button N" into the same `UInt16` slot used for keyboard
/// key codes, so `HotkeyConfig.keyCode` can represent either input source
/// without a schema change. Mac keyboard CGKeyCodes are ≤ `0x7F`, so the
/// `0xF000+` range is safe to use as a sentinel.
public enum MouseButtonSentinel {
    public static let base: UInt16 = 0xF000
    public static let maxButton: Int = 31

    public static func keyCode(forButton button: Int) -> UInt16 {
        base + UInt16(button)
    }

    public static func button(fromKeyCode code: UInt16) -> Int? {
        guard code >= base, code <= base + UInt16(maxButton) else { return nil }
        return Int(code - base)
    }

    public static func isMouseButton(_ code: UInt16) -> Bool {
        button(fromKeyCode: code) != nil
    }
}
