import Foundation

/// Static metadata about a supported provider — display name, data-policy URL,
/// and any other code-owned facts that aren't user preferences.
///
/// Distinct from `ProviderConfig`, which holds the user's choices (which
/// provider, model, language, hints). The registry answers the question
/// "given a `providerName` string, what should the UI say about it?"
public struct ProviderInfo: Sendable, Equatable {
    /// Matches `ProviderConfig.providerName`. Lowercase, stable across releases.
    public let identifier: String
    public let displayName: String
    public let dataPolicyURL: URL

    public init(identifier: String, displayName: String, dataPolicyURL: URL) {
        self.identifier = identifier
        self.displayName = displayName
        self.dataPolicyURL = dataPolicyURL
    }
}

/// Lookup table of supported providers. Add an entry here when wiring a new
/// adapter; the Provider settings pane reads from this to populate its picker
/// and the Privacy pane reads it for the data-policy link.
public enum ProviderRegistry {
    public static let elevenlabs = ProviderInfo(
        identifier: "elevenlabs",
        displayName: "ElevenLabs",
        dataPolicyURL: URL(string: "https://elevenlabs.io/privacy")!
    )

    /// All providers this build knows about. Order is the picker order.
    public static let known: [ProviderInfo] = [elevenlabs]

    /// `nil` for unknown identifiers — caller decides whether to surface a
    /// "this build doesn't recognise provider X" message or silently fall
    /// back to the default.
    public static func info(for identifier: String) -> ProviderInfo? {
        known.first { $0.identifier == identifier }
    }
}
