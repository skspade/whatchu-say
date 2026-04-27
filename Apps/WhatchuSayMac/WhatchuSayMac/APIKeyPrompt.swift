import AppKit

/// Modal `NSAlert` with an `NSSecureTextField` accessory. Returns the trimmed
/// key on OK, or `nil` on Cancel / empty input.
@MainActor
enum APIKeyPrompt {
    struct Configuration {
        let title: String
        let message: String
        let okButtonTitle: String
        let placeholder: String
    }

    static func setKey() -> Configuration {
        Configuration(
            title: "Set ElevenLabs API Key",
            message: "Whatchu-Say uses your ElevenLabs API key to transcribe speech. The key is stored securely in your Keychain and never leaves this Mac.",
            okButtonTitle: "Save",
            placeholder: "sk_…"
        )
    }

    static func updateKey(currentSuffix: String?) -> Configuration {
        let detail = currentSuffix.map { " (current: …\($0))" } ?? ""
        return Configuration(
            title: "Update ElevenLabs API Key",
            message: "Replace the stored key\(detail). The new key is saved to your Keychain.",
            okButtonTitle: "Update",
            placeholder: "sk_…"
        )
    }

    /// Show the prompt synchronously. Must be called on the main actor.
    static func show(_ config: Configuration) -> String? {
        let alert = NSAlert()
        alert.messageText = config.title
        alert.informativeText = config.message
        alert.alertStyle = .informational
        alert.addButton(withTitle: config.okButtonTitle)
        alert.addButton(withTitle: "Cancel")

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = config.placeholder
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }
        let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension APIKeyPrompt {
    /// Last 4 characters of `key`, for display in menu items. Returns nil for
    /// keys too short to redact.
    static func suffix(of key: String) -> String? {
        guard key.count >= 4 else { return nil }
        return String(key.suffix(4))
    }
}
