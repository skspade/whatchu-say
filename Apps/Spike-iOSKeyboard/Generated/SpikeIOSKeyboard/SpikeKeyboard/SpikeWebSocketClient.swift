import Foundation

/// Spike-grade ElevenLabs realtime STT client. Mirrors the protocol used by
/// `Sources/STTElevenLabs/` so the network exchange is realistic, but
/// without `STTCore` types or the orchestrator wiring.
///
/// Lifecycle:
/// - `open()` — opens the WebSocket and awaits `session_started`.
/// - `sendAudioChunk(samples:commit:)` — base64-encodes Int16 LE PCM and
///   sends an `input_audio_chunk` JSON frame.
/// - `commit()` — empty chunk with `commit: true` to finalize.
/// - `partials` / `finals` — async streams of server-side text events.
/// - `close()` — graceful shutdown. Idempotent.
actor SpikeWebSocketClient {
    let partials: AsyncStream<String>
    let finals: AsyncStream<String>

    private let partialsContinuation: AsyncStream<String>.Continuation
    private let finalsContinuation: AsyncStream<String>.Continuation
    private let task: URLSessionWebSocketTask
    private var receiveTask: Task<Void, Never>?
    private var closed = false

    init(apiKey: String, sampleRate: Int = 16_000) {
        var components = URLComponents(
            string: "wss://api.elevenlabs.io/v1/speech-to-text/realtime"
        )!
        components.queryItems = [
            URLQueryItem(name: "model_id", value: "scribe_v2_realtime"),
            URLQueryItem(name: "audio_format", value: "pcm_\(sampleRate)"),
            URLQueryItem(name: "commit_strategy", value: "manual"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        self.task = URLSession.shared.webSocketTask(with: request)

        (self.partials, self.partialsContinuation) = AsyncStream<String>.makeStream()
        (self.finals, self.finalsContinuation) = AsyncStream<String>.makeStream()
    }

    func open() async throws {
        task.resume()
        let first = try await receiveOne()
        switch first {
        case .sessionStarted:
            startReceiveLoop()
        case .error(let kind, let message):
            await tearDown()
            throw SpikeWSError.serverError(kind: kind, message: message)
        default:
            await tearDown()
            throw SpikeWSError.unexpectedFirstMessage(first)
        }
    }

    func sendAudioChunk(samples: [Int16], commit: Bool) async throws {
        guard !closed else { return }
        let base64 = Self.base64(samples: samples)
        let payload: [String: Any] = [
            "message_type": "input_audio_chunk",
            "audio_base_64": base64,
            "sample_rate": 16_000,
            "commit": commit,
        ]
        let json = try JSONSerialization.data(withJSONObject: payload)
        guard let text = String(data: json, encoding: .utf8) else {
            throw SpikeWSError.encodingFailed
        }
        try await task.send(.string(text))
    }

    func commit() async throws {
        try await sendAudioChunk(samples: [], commit: true)
    }

    func close() async {
        await tearDown()
    }

    // MARK: - Receive

    private func startReceiveLoop() {
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let alive = await self?.pumpOnce(), alive else { return }
            }
        }
    }

    private func pumpOnce() async -> Bool {
        guard !closed else { return false }
        let message: ParsedMessage
        do {
            message = try await receiveOne()
        } catch {
            await tearDown()
            return false
        }
        switch message {
        case .partial(let text):
            partialsContinuation.yield(text)
        case .final(let text):
            finalsContinuation.yield(text)
        case .error:
            await tearDown()
            return false
        case .sessionStarted, .other:
            break
        }
        return true
    }

    private func receiveOne() async throws -> ParsedMessage {
        let raw = try await task.receive()
        let data: Data
        switch raw {
        case .string(let s): data = Data(s.utf8)
        case .data(let d): data = d
        @unknown default: throw SpikeWSError.unsupportedFrame
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["message_type"] as? String
        else { throw SpikeWSError.malformed }

        switch type {
        case "session_started":
            return .sessionStarted
        case "partial_transcript":
            return .partial((obj["text"] as? String) ?? "")
        case "committed_transcript", "committed_transcript_with_timestamps":
            return .final((obj["text"] as? String) ?? "")
        case let t where Self.errorKinds.contains(t):
            return .error(kind: t, message: (obj["error"] as? String) ?? t)
        default:
            return .other
        }
    }

    private func tearDown() async {
        if closed { return }
        closed = true
        receiveTask?.cancel()
        task.cancel(with: .normalClosure, reason: nil)
        partialsContinuation.finish()
        finalsContinuation.finish()
    }

    // MARK: - Helpers

    private static func base64(samples: [Int16]) -> String {
        if samples.isEmpty { return "" }
        var bytes = Data(count: samples.count * 2)
        bytes.withUnsafeMutableBytes { rawBuffer in
            let int16Buffer = rawBuffer.bindMemory(to: Int16.self)
            for (i, sample) in samples.enumerated() {
                int16Buffer[i] = sample.littleEndian
            }
        }
        return bytes.base64EncodedString()
    }

    private static let errorKinds: Set<String> = [
        "error", "auth_error", "quota_exceeded", "commit_throttled",
        "rate_limited", "input_error", "transcriber_error",
    ]

    private enum ParsedMessage {
        case sessionStarted
        case partial(String)
        case final(String)
        case error(kind: String, message: String)
        case other
    }
}

enum SpikeWSError: Error {
    case encodingFailed
    case malformed
    case unsupportedFrame
    case unexpectedFirstMessage(Any)
    case serverError(kind: String, message: String)
}
