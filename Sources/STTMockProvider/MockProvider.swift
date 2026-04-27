import Foundation
import STTCore

/// In-memory STT provider for tests and provider-abstraction validation.
/// Always emits a single canned final transcript on `endOfStream()`.
public struct MockProvider: SttProvider {
    public let name = "mock"
    public let capabilities = Capabilities(
        partials: true,
        punctuation: true,
        languages: .auto,
        sampleRates: [16_000],
        maxSessionSeconds: nil,
        supportsClientEndpointing: true
    )

    public let cannedFinal: String

    public init(cannedFinal: String = "mock transcription") {
        self.cannedFinal = cannedFinal
    }

    public func open(config: SessionConfig) async throws -> any SttSession {
        return MockSession(cannedFinal: cannedFinal)
    }
}

public actor MockSession: SttSession {
    public nonisolated let events: AsyncStream<SttEvent>
    private let continuation: AsyncStream<SttEvent>.Continuation
    private let cannedFinal: String
    private var samplesReceived: Int = 0

    public init(cannedFinal: String) {
        let (stream, cont) = AsyncStream<SttEvent>.makeStream()
        self.events = stream
        self.continuation = cont
        self.cannedFinal = cannedFinal
    }

    public func pushAudio(_ samples: [Int16]) async throws {
        samplesReceived += samples.count
    }

    public func endOfStream() async throws {
        continuation.yield(.final(text: cannedFinal, alternatives: []))
    }

    public func close() async {
        continuation.finish()
    }
}
