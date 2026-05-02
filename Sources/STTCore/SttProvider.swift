import Foundation

public protocol SttProvider: Sendable {
    var name: String { get }
    var capabilities: Capabilities { get }
    func open(config: SessionConfig) async throws -> any SttSession
}

public struct Capabilities: Sendable {
    public let partials: Bool
    public let punctuation: Bool
    public let languages: LanguageSupport
    public let sampleRates: [UInt32]
    public let maxSessionSeconds: UInt32?
    public let supportsClientEndpointing: Bool

    public init(
        partials: Bool,
        punctuation: Bool,
        languages: LanguageSupport,
        sampleRates: [UInt32],
        maxSessionSeconds: UInt32?,
        supportsClientEndpointing: Bool
    ) {
        self.partials = partials
        self.punctuation = punctuation
        self.languages = languages
        self.sampleRates = sampleRates
        self.maxSessionSeconds = maxSessionSeconds
        self.supportsClientEndpointing = supportsClientEndpointing
    }
}

public enum LanguageSupport: Sendable {
    case specific([String])
    case auto
    case multi
}

public extension SttProvider {
    /// Providers that don't support batch transcription return `nil`. To
    /// support it, override and return your `BatchTranscriber` instance.
    var batchTranscriber: (any BatchTranscriber)? { nil }
}
