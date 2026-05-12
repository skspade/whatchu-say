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
    private nonisolated let continuation: AsyncStream<SttEvent>.Continuation
    private let cannedFinal: String
    private var samplesReceived: Int = 0
    private var closed: Bool = false

    public init(cannedFinal: String) {
        let (stream, cont) = AsyncStream<SttEvent>.makeStream()
        self.events = stream
        self.continuation = cont
        self.cannedFinal = cannedFinal
        // Mirror the real provider: as soon as a session is open the server
        // emits at least one `partial_transcript`. Without this, the
        // orchestrator's silence fast-path would tear the session down
        // before EOS in test flows that don't explicitly push audio.
        cont.yield(.partial(text: "", stability: 0.0))
    }

    public func pushAudio(_ samples: [Int16]) async throws {
        samplesReceived += samples.count
    }

    public func endOfStream() async throws {
        continuation.yield(.final(text: cannedFinal, alternatives: []))
        // Mirror the real provider: server closes the WebSocket after the
        // EOS commit, which finishes the events stream.
        finishOnce()
    }

    public func close() async {
        finishOnce()
    }

    private func finishOnce() {
        guard !closed else { return }
        closed = true
        continuation.finish()
    }
}
