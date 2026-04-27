import Foundation
import STTCore

/// ElevenLabs realtime STT adapter. Stub: real WebSocket implementation in Milestone 1.2.
public struct ElevenLabsProvider: SttProvider {
    public let name = "elevenlabs"
    public let capabilities = Capabilities(
        partials: true,
        punctuation: true,
        languages: .auto,
        sampleRates: [16_000],
        maxSessionSeconds: nil,
        supportsClientEndpointing: true
    )

    private let apiKey: String

    public init(apiKey: String) {
        self.apiKey = apiKey
    }

    public func open(config: SessionConfig) async throws -> any SttSession {
        throw SttError.fatal("ElevenLabs adapter not yet implemented")
    }
}
