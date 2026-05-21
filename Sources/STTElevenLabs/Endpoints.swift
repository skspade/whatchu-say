import Foundation
import STTCore

enum Endpoints {
    static let realtimeURL = URL(string: "wss://api.elevenlabs.io/v1/speech-to-text/realtime")!
    static let batchSpeechToText = URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!
    static let defaultModelId = "scribe_v2_realtime"

    /// ElevenLabs realtime keyterm caps: max 50 terms, 20 chars per term.
    /// https://elevenlabs.io/docs/eleven-api/guides/how-to/speech-to-text/batch/keyterm-prompting
    static let maxKeyterms = 50
    static let maxKeytermLength = 20

    /// Build the realtime STT WebSocket URL from a `SessionConfig`.
    ///
    /// - Audio is always sent as `pcm_<sampleRate>` (matches our 16 kHz Int16
    ///   capture pipeline).
    /// - `commit_strategy=manual` when the orchestrator controls utterance
    ///   boundaries (`.clientControlled`); `vad` otherwise. Per the PRD we
    ///   default to manual — pause-to-think is supported only this way.
    /// - `language_code` is omitted when nil so the provider auto-detects.
    /// - `keyterms` are appended one query item per term. Settings UI enforces
    ///   the limits; this layer drops over-limit entries defensively to avoid
    ///   a malformed config breaking the WebSocket handshake.
    static func realtime(
        config: SessionConfig,
        base: URL = realtimeURL
    ) -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "model_id", value: config.model ?? defaultModelId),
            URLQueryItem(name: "audio_format", value: "pcm_\(config.sampleRate)"),
            URLQueryItem(
                name: "commit_strategy",
                value: config.endpointDetection == .clientControlled ? "manual" : "vad"
            ),
        ]
        if let language = config.language {
            items.append(URLQueryItem(name: "language_code", value: language))
        }
        if config.noVerbatim {
            items.append(URLQueryItem(name: "no_verbatim", value: "true"))
        }
        for term in sanitizedKeyterms(config.hints) {
            items.append(URLQueryItem(name: "keyterms", value: term))
        }
        components.queryItems = items
        return components.url!
    }

    /// Trim, drop empty / over-length, cap to `maxKeyterms`. Keeps the wire
    /// contract honest even if older configs slipped through the UI.
    static func sanitizedKeyterms(_ raw: [String]) -> [String] {
        raw.lazy
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= maxKeytermLength }
            .prefix(maxKeyterms)
            .map { $0 }
    }
}
