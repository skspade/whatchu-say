import Testing
@testable import STTElevenLabs

@Suite("ElevenLabs adapter smoke")
struct ElevenLabsSmokeTests {
    @Test("provider has expected name and capability flags")
    func metadata() {
        let provider = ElevenLabsProvider(apiKey: "test-key")
        #expect(provider.name == "elevenlabs")
        #expect(provider.capabilities.supportsClientEndpointing == true)
        #expect(provider.capabilities.sampleRates.contains(16_000))
    }
}
