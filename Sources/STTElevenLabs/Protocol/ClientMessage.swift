import Foundation

/// Outgoing audio chunk for the ElevenLabs realtime STT WebSocket.
///
/// Audio bytes (16-bit signed PCM, little-endian) are base64-encoded into
/// `audio_base_64`. `commit` is required by the protocol — `false` for
/// streaming chunks, `true` on a final empty-audio chunk to finalize the
/// utterance. (The doc-listed standalone `{"message_type":"commit"}`
/// envelope is rejected by the server in our `commit_strategy=manual`
/// configuration.)
struct InputAudioChunk: Encodable, Sendable, Equatable {
    let audioBase64: String
    let sampleRate: Int
    let commit: Bool
    let previousText: String?

    private enum CodingKeys: String, CodingKey {
        case messageType = "message_type"
        case audioBase64 = "audio_base_64"
        case sampleRate = "sample_rate"
        case commit
        case previousText = "previous_text"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("input_audio_chunk", forKey: .messageType)
        try container.encode(audioBase64, forKey: .audioBase64)
        try container.encode(sampleRate, forKey: .sampleRate)
        try container.encode(commit, forKey: .commit)
        try container.encodeIfPresent(previousText, forKey: .previousText)
    }
}

