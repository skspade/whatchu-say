import Testing
import Foundation
@testable import STTElevenLabs
@testable import STTCore

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

@Suite("ElevenLabs Endpoints")
struct ElevenLabsEndpointsTests {
    @Test("default config emits manual commit_strategy and pcm_16000")
    func defaultConfig() throws {
        let url = Endpoints.realtime(config: SessionConfig())
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "wss")
        #expect(components.host == "api.elevenlabs.io")
        #expect(components.path == "/v1/speech-to-text/realtime")
        let items = items(components)
        #expect(items["model_id"] == "scribe_v2_realtime")
        #expect(items["audio_format"] == "pcm_16000")
        #expect(items["commit_strategy"] == "manual")
        #expect(items["language_code"] == nil)
    }

    @Test("language_code is included when provided")
    func includesLanguage() throws {
        let url = Endpoints.realtime(config: SessionConfig(language: "en"))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(items(components)["language_code"] == "en")
    }

    @Test("providerControlled mode switches commit_strategy to vad")
    func providerControlled() throws {
        let url = Endpoints.realtime(
            config: SessionConfig(endpointDetection: .providerControlled)
        )
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(items(components)["commit_strategy"] == "vad")
    }

    @Test("model override is honored")
    func modelOverride() throws {
        let url = Endpoints.realtime(config: SessionConfig(model: "scribe_v2_alpha"))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(items(components)["model_id"] == "scribe_v2_alpha")
    }

    private func items(_ components: URLComponents) -> [String: String] {
        var result: [String: String] = [:]
        for item in components.queryItems ?? [] {
            result[item.name] = item.value
        }
        return result
    }
}

@Suite("ElevenLabs ServerMessage decoding")
struct ServerMessageDecodingTests {
    private let decoder = JSONDecoder()

    @Test("decodes session_started")
    func sessionStarted() throws {
        let json = """
        {"message_type":"session_started","session_id":"abc-123","config":{}}
        """.data(using: .utf8)!
        let message = try decoder.decode(ServerMessage.self, from: json)
        #expect(message == .sessionStarted(sessionId: "abc-123"))
    }

    @Test("decodes partial_transcript")
    func partial() throws {
        let json = #"{"message_type":"partial_transcript","text":"hello wor"}"#.data(using: .utf8)!
        let message = try decoder.decode(ServerMessage.self, from: json)
        #expect(message == .partialTranscript(text: "hello wor"))
    }

    @Test("decodes committed_transcript")
    func committed() throws {
        let json = #"{"message_type":"committed_transcript","text":"hello world"}"#.data(using: .utf8)!
        let message = try decoder.decode(ServerMessage.self, from: json)
        #expect(message == .committedTranscript(text: "hello world"))
    }

    @Test("treats committed_transcript_with_timestamps the same way")
    func committedWithTimestamps() throws {
        let json = """
        {"message_type":"committed_transcript_with_timestamps","text":"hi","words":[]}
        """.data(using: .utf8)!
        let message = try decoder.decode(ServerMessage.self, from: json)
        #expect(message == .committedTranscript(text: "hi"))
    }

    @Test("decodes auth_error")
    func authError() throws {
        let json = #"{"message_type":"auth_error","error":"bad key"}"#.data(using: .utf8)!
        let message = try decoder.decode(ServerMessage.self, from: json)
        #expect(message == .error(kind: "auth_error", message: "bad key"))
    }

    @Test("decodes generic error variants")
    func quotaExceeded() throws {
        let json = #"{"message_type":"quota_exceeded","error":"out of quota"}"#.data(using: .utf8)!
        let message = try decoder.decode(ServerMessage.self, from: json)
        #expect(message == .error(kind: "quota_exceeded", message: "out of quota"))
    }

    @Test("unknown message_type is preserved as .unknown")
    func unknownType() throws {
        let json = #"{"message_type":"future_event","other":1}"#.data(using: .utf8)!
        let message = try decoder.decode(ServerMessage.self, from: json)
        #expect(message == .unknown(messageType: "future_event"))
    }
}

@Suite("ElevenLabs InputAudioChunk encoding")
struct InputAudioChunkEncodingTests {
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    @Test("streaming chunk always emits commit:false and omits previous_text")
    func streamingChunk() throws {
        let chunk = InputAudioChunk(
            audioBase64: "AAEC",
            sampleRate: 16_000,
            commit: false,
            previousText: nil
        )
        let data = try encoder.encode(chunk)
        let object = try decode(data)
        #expect(object["message_type"] as? String == "input_audio_chunk")
        #expect(object["audio_base_64"] as? String == "AAEC")
        #expect(object["sample_rate"] as? Int == 16_000)
        #expect(object["commit"] as? Bool == false)
        #expect(object["previous_text"] == nil)
    }

    @Test("commit chunk sets commit:true with empty audio")
    func commitChunk() throws {
        let chunk = InputAudioChunk(
            audioBase64: "",
            sampleRate: 16_000,
            commit: true,
            previousText: nil
        )
        let data = try encoder.encode(chunk)
        let object = try decode(data)
        #expect(object["commit"] as? Bool == true)
        #expect(object["audio_base_64"] as? String == "")
    }

    private func decode(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

@Suite("ElevenLabs PCM packing")
struct ElevenLabsPCMPackingTests {
    @Test("empty samples → empty base64")
    func empty() {
        #expect(ElevenLabsSession.base64(samples: []) == "")
    }

    @Test("packs as little-endian Int16")
    func littleEndian() {
        // 0x0001 → 0x01 0x00 LE → bytes [0x01, 0x00] → base64 "AQA="
        let result = ElevenLabsSession.base64(samples: [1])
        #expect(result == "AQA=")
    }

    @Test("preserves sign for negative samples")
    func negative() {
        // -1 → 0xFFFF → bytes [0xFF, 0xFF] → "//8="
        let result = ElevenLabsSession.base64(samples: [-1])
        #expect(result == "//8=")
    }

    @Test("round-trip via base64 + LE bytes recovers samples")
    func roundTrip() throws {
        let samples: [Int16] = [0, 1, -1, Int16.max, Int16.min, 12345, -12345]
        let encoded = ElevenLabsSession.base64(samples: samples)
        let bytes = try #require(Data(base64Encoded: encoded))
        #expect(bytes.count == samples.count * 2)
        let recovered: [Int16] = bytes.withUnsafeBytes { raw in
            let buffer = raw.bindMemory(to: Int16.self)
            return (0..<samples.count).map { Int16(littleEndian: buffer[$0]) }
        }
        #expect(recovered == samples)
    }
}
