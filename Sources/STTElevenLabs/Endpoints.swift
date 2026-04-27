import Foundation
import STTCore

enum Endpoints {
    static let realtimeURL = URL(string: "wss://api.elevenlabs.io/v1/speech-to-text/realtime")!
    static let defaultModelId = "scribe_v1"

    /// Build the realtime STT WebSocket URL from a `SessionConfig`.
    ///
    /// - Audio is always sent as `pcm_<sampleRate>` (matches our 16 kHz Int16
    ///   capture pipeline).
    /// - `commit_strategy=manual` when the orchestrator controls utterance
    ///   boundaries (`.clientControlled`); `vad` otherwise. Per the PRD we
    ///   default to manual — pause-to-think is supported only this way.
    /// - `language_code` is omitted when nil so the provider auto-detects.
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
        components.queryItems = items
        return components.url!
    }
}
