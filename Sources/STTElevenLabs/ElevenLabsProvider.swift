import Foundation
import STTCore

/// ElevenLabs realtime STT provider. `open(config:)` builds a session bound to
/// a single utterance — the orchestrator owns the lifecycle (one session per
/// dictation, fail-fast on errors).
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
    private let urlSession: URLSession
    private let noVerbatim: Bool

    public init(apiKey: String, urlSession: URLSession = .shared, noVerbatim: Bool = false) {
        self.apiKey = apiKey
        self.urlSession = urlSession
        self.noVerbatim = noVerbatim
    }

    public func open(config: SessionConfig) async throws -> any SttSession {
        let session = ElevenLabsSession(
            apiKey: apiKey,
            config: config,
            urlSession: urlSession
        )
        try await session.start()
        return session
    }

    public var batchTranscriber: (any BatchTranscriber)? {
        ElevenLabsBatchTranscriber(
            apiKey: apiKey,
            urlSession: urlSession,
            noVerbatim: noVerbatim
        )
    }
}
