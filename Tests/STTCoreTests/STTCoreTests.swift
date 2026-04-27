import Testing
@testable import STTCore
@testable import STTMockProvider

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
