import AVFoundation
import Testing
@testable import STTApple
import STTCore

@Suite("Apple Speech provider")
struct AppleSpeechProviderTests {
    @Test("advertises the app's capture format and client endpointing")
    func capabilities() {
        guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) else { return }
        let provider = AppleSpeechProvider()

        #expect(provider.name == "apple")
        #expect(provider.capabilities.sampleRates == [16_000])
        #expect(provider.capabilities.supportsClientEndpointing)
        #expect(provider.capabilities.partials)
    }

    @Test("copies Int16 audio into an analyzer-compatible PCM buffer")
    func bufferConstruction() throws {
        guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) else { return }
        let format = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 16_000,
                channels: 1,
                interleaved: true
            )
        )
        let samples: [Int16] = [-1, 0, 42]

        let buffer = try AppleSpeechSession.makeBuffer(samples: samples, format: format)

        #expect(buffer.frameLength == 3)
        #expect(buffer.format.sampleRate == 16_000)
        #expect(buffer.int16ChannelData?[0][0] == -1)
        #expect(buffer.int16ChannelData?[0][1] == 0)
        #expect(buffer.int16ChannelData?[0][2] == 42)
    }

    @Test("availability errors provide actionable messages")
    func errorDescription() {
        guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) else { return }
        let error = AppleSpeechError.unsupportedLanguage("xx-YY")

        #expect(error.localizedDescription.contains("xx-YY"))
    }
}
