import Foundation

/// Messages received from the ElevenLabs realtime STT WebSocket.
///
/// The server discriminates by the top-level `message_type` string. Unknown
/// types are surfaced as `.unknown` so the session can warn rather than crash.
enum ServerMessage: Decodable, Sendable, Equatable {
    case sessionStarted(sessionId: String)
    case partialTranscript(text: String)
    case committedTranscript(text: String)
    case error(kind: String, message: String)
    case unknown(messageType: String)

    private enum CodingKeys: String, CodingKey {
        case messageType = "message_type"
        case text
        case error
        case sessionId = "session_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let messageType = try container.decode(String.self, forKey: .messageType)
        switch messageType {
        case "session_started":
            let sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId) ?? ""
            self = .sessionStarted(sessionId: sessionId)
        case "partial_transcript":
            let text = try container.decode(String.self, forKey: .text)
            self = .partialTranscript(text: text)
        case "committed_transcript", "committed_transcript_with_timestamps":
            let text = try container.decode(String.self, forKey: .text)
            self = .committedTranscript(text: text)
        case _ where Self.errorKinds.contains(messageType):
            let message = (try? container.decode(String.self, forKey: .error)) ?? messageType
            self = .error(kind: messageType, message: message)
        default:
            self = .unknown(messageType: messageType)
        }
    }

    private static let errorKinds: Set<String> = [
        "error",
        "auth_error",
        "quota_exceeded",
        "commit_throttled",
        "unaccepted_terms",
        "rate_limited",
        "queue_overflow",
        "resource_exhausted",
        "session_time_limit_exceeded",
        "input_error",
        "chunk_size_exceeded",
        "insufficient_audio_activity",
        "transcriber_error",
    ]
}
