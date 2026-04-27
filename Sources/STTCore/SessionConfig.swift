import Foundation

public struct SessionConfig: Sendable {
    public let sampleRate: UInt32
    public let language: String?
    public let model: String?
    public let interimResults: Bool
    public let punctuation: Bool
    public let hints: [String]
    public let endpointDetection: EndpointMode

    public init(
        sampleRate: UInt32 = 16_000,
        language: String? = nil,
        model: String? = nil,
        interimResults: Bool = true,
        punctuation: Bool = true,
        hints: [String] = [],
        endpointDetection: EndpointMode = .clientControlled
    ) {
        self.sampleRate = sampleRate
        self.language = language
        self.model = model
        self.interimResults = interimResults
        self.punctuation = punctuation
        self.hints = hints
        self.endpointDetection = endpointDetection
    }
}

public enum EndpointMode: Sendable {
    /// Provider auto-finalizes on detected speech end.
    case providerControlled
    /// Final only after explicit endOfStream() from us. Required for our use case.
    case clientControlled
}
