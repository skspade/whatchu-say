import Testing
@testable import STTCore
@testable import STTMockProvider

@Suite("BatchTranscriber")
struct BatchTranscriberTests {
    @Test("default provider exposes nil batchTranscriber")
    func defaultNil() {
        let provider = MockProvider()
        #expect(provider.batchTranscriber == nil)
    }

    @Test("BatchTranscriptionResult preserves segments")
    func resultStruct() {
        let result = BatchTranscriptionResult(segments: [
            .init(start: 0, end: 1, speakerId: nil, text: "a"),
            .init(start: 1, end: 2, speakerId: 0, text: "b"),
        ])
        #expect(result.segments.count == 2)
        #expect(result.segments[1].speakerId == 0)
    }
}

@Suite("MockProvider smoke")
struct MockProviderSmokeTests {
    @Test("opens session and accepts audio + EOS")
    func sessionLifecycle() async throws {
        let provider = MockProvider()
        let session = try await provider.open(config: SessionConfig())
        try await session.pushAudio([0, 1, 2, 3])
        try await session.endOfStream()
        await session.close()
    }

    @Test("provider advertises client endpointing support")
    func capabilities() {
        let provider = MockProvider()
        #expect(provider.capabilities.supportsClientEndpointing == true)
    }
}
