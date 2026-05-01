import AppKit
import Core

/// Renders a `(keyCode, ModifierSet)` pair into a human-readable string
/// using standard macOS modifier glyphs (⌃ ⌥ ⇧ ⌘ fn) and a hand-curated
/// keyCode → label table.
///
/// Falls back to "Key 0xXX" for unknown key codes — the table covers the
/// keys most users will pick (alphanumerics, F1–F19, navigation, common
/// punctuation, modifier-only codes).
enum KeyCombo {
    static func displayString(keyCode: UInt16, modifiers: ModifierSet) -> String {
        modifierGlyphs(modifiers) + keyLabel(for: keyCode)
    }

    static func displayString(keyCode: UInt16) -> String {
        keyLabel(for: keyCode)
    }

    /// Bridge `NSEvent.ModifierFlags` (device-independent bits) into our
    /// platform-agnostic `ModifierSet`. Used by the recorder to translate
    /// captured events.
    static func modifierSet(from flags: NSEvent.ModifierFlags) -> ModifierSet {
        var result: ModifierSet = []
        if flags.contains(.shift)    { result.insert(.shift) }
        if flags.contains(.control)  { result.insert(.control) }
        if flags.contains(.option)   { result.insert(.option) }
        if flags.contains(.command)  { result.insert(.command) }
        if flags.contains(.function) { result.insert(.function) }
        if flags.contains(.capsLock) { result.insert(.capsLock) }
        return result
    }

    // MARK: - Internals

    private static func modifierGlyphs(_ mods: ModifierSet) -> String {
        var s = ""
        if mods.contains(.control)  { s += "⌃" }
        if mods.contains(.option)   { s += "⌥" }
        if mods.contains(.shift)    { s += "⇧" }
        if mods.contains(.command)  { s += "⌘" }
        if mods.contains(.function) { s += "fn " }
        if mods.contains(.capsLock) { s += "⇪" }
        return s
    }

    private static func keyLabel(for keyCode: UInt16) -> String {
        if let label = labelTable[keyCode] {
            return label
        }
        return String(format: "Key 0x%02X", keyCode)
    }

    /// Curated keyCode → label table. macOS keyCodes are stable across
    /// keyboards (the keyboard layout maps codes to characters, but the
    /// codes themselves are the same hardware positions).
    private static let labelTable: [UInt16: String] = [
        // Letters
        0x00: "A", 0x0B: "B", 0x08: "C", 0x02: "D", 0x0E: "E", 0x03: "F",
        0x05: "G", 0x04: "H", 0x22: "I", 0x26: "J", 0x28: "K", 0x25: "L",
        0x2E: "M", 0x2D: "N", 0x1F: "O", 0x23: "P", 0x0C: "Q", 0x0F: "R",
        0x01: "S", 0x11: "T", 0x20: "U", 0x09: "V", 0x0D: "W", 0x07: "X",
        0x10: "Y", 0x06: "Z",
        // Digits (top row)
        0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x17: "5",
        0x16: "6", 0x1A: "7", 0x1C: "8", 0x19: "9", 0x1D: "0",
        // Common punctuation
        0x18: "=", 0x1B: "-", 0x21: "[", 0x1E: "]", 0x29: ";",
        0x27: "'", 0x2A: "\\", 0x2B: ",", 0x2F: ".", 0x2C: "/",
        0x32: "`",
        // Whitespace / editing
        0x24: "↩",      // Return
        0x30: "⇥",      // Tab
        0x31: "Space",
        0x33: "⌫",      // Delete (backspace)
        0x35: "⎋",      // Escape
        0x75: "⌦",      // Forward Delete
        // Navigation
        0x73: "↖",      // Home
        0x77: "↘",      // End
        0x74: "⇞",      // Page Up
        0x79: "⇟",      // Page Down
        0x7B: "←", 0x7C: "→", 0x7D: "↓", 0x7E: "↑",
        // Function keys
        0x7A: "F1",  0x78: "F2",  0x63: "F3",  0x76: "F4",
        0x60: "F5",  0x61: "F6",  0x62: "F7",  0x64: "F8",
        0x65: "F9",  0x6D: "F10", 0x67: "F11", 0x6F: "F12",
        0x69: "F13", 0x6B: "F14", 0x71: "F15", 0x6A: "F16",
        0x40: "F17", 0x4F: "F18", 0x50: "F19",
        // Modifier-only key codes (when used as the activation key itself)
        0x37: "⌘ Command",
        0x38: "⇧ Left Shift",
        0x3C: "⇧ Right Shift",
        0x39: "⇪ Caps Lock",
        0x3A: "⌥ Left Option",
        0x3D: "⌥ Right Option",
        0x3B: "⌃ Left Control",
        0x3E: "⌃ Right Control",
        0x36: "⌘ Right Command",
        0x3F: "fn",
    ]
}
