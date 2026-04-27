import Foundation
import STTCore

/// One ElevenLabs realtime STT session backed by a single
/// `URLSessionWebSocketTask`. Lifecycle:
///
/// 1. `init` — builds the URL, creates the (paused) WebSocket task with the
///    `xi-api-key` header. No I/O yet.
/// 2. `start()` — resumes the task, awaits the synchronous `session_started`
///    handshake, then spins up a long-running receive loop that pumps server
///    messages into the `events` stream. Throws `SttError` on auth/network
///    failure so the orchestrator can surface it.
/// 3. `pushAudio(_:)` — encodes 16-bit LE PCM samples to base64 and sends an
///    `input_audio_chunk` JSON frame.
/// 4. `endOfStream()` — sends a final empty chunk with `commit: true`. The
///    server replies with a `committed_transcript` which the receive loop
///    turns into `.final`.
/// 5. `close()` — cancels the receive task, sends a normal-close frame,
///    finishes the events stream. Idempotent.
///
/// Concurrency: all state lives on this actor. `URLSessionWebSocketTask` is
/// itself thread-safe, so concurrent `send` (from `pushAudio`) and `receive`
/// (from the receive loop) are supported.
public actor ElevenLabsSession: SttSession {
    public nonisolated let events: AsyncStream<SttEvent>
    private nonisolated let eventsContinuation: AsyncStream<SttEvent>.Continuation

    private let task: URLSessionWebSocketTask
    private let sampleRate: Int
    private var receiveTask: Task<Void, Never>?
    private var closed = false

    init(
        apiKey: String,
        config: SessionConfig,
        urlSession: URLSession = .shared
    ) {
        let url = Endpoints.realtime(config: config)
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        self.task = urlSession.webSocketTask(with: request)
        self.sampleRate = Int(config.sampleRate)

        let (stream, continuation) = AsyncStream<SttEvent>.makeStream()
        self.events = stream
        self.eventsContinuation = continuation
    }

    /// Resume the WebSocket and wait for the server's `session_started`
    /// handshake before returning. Any failure here aborts session creation.
    func start() async throws {
        task.resume()

        let first: ServerMessage
        do {
            first = try await receiveOne()
        } catch let error as SttError {
            await tearDown()
            throw error
        } catch {
            await tearDown()
            throw Self.mapNetworkError(error)
        }

        switch first {
        case .sessionStarted:
            startReceiveLoop()
        case .error(let kind, let message):
            await tearDown()
            throw kind == "auth_error" ? SttError.authentication : SttError.fatal("\(kind): \(message)")
        case .partialTranscript, .committedTranscript, .unknown:
            await tearDown()
            throw SttError.fatal("unexpected first message from server")
        }
    }

    public func pushAudio(_ samples: [Int16]) async throws {
        guard !closed else { throw SttError.cancelled }
        let chunk = InputAudioChunk(
            audioBase64: Self.base64(samples: samples),
            sampleRate: sampleRate,
            commit: nil,
            previousText: nil
        )
        try await send(chunk)
    }

    public func endOfStream() async throws {
        guard !closed else { return }
        let chunk = InputAudioChunk(
            audioBase64: "",
            sampleRate: sampleRate,
            commit: true,
            previousText: nil
        )
        try await send(chunk)
    }

    public func close() async {
        await tearDown()
    }

    // MARK: - Send / receive plumbing

    private func send(_ chunk: InputAudioChunk) async throws {
        let data = try Self.encoder.encode(chunk)
        guard let text = String(data: data, encoding: .utf8) else {
            throw SttError.fatal("failed to serialize audio chunk")
        }
        do {
            try await task.send(.string(text))
        } catch {
            throw Self.mapNetworkError(error)
        }
    }

    private func receiveOne() async throws -> ServerMessage {
        let raw = try await task.receive()
        let data: Data
        switch raw {
        case .string(let s):
            data = Data(s.utf8)
        case .data(let d):
            data = d
        @unknown default:
            throw SttError.fatal("unsupported websocket frame")
        }
        do {
            return try Self.decoder.decode(ServerMessage.self, from: data)
        } catch {
            throw SttError.fatal("malformed server message: \(error.localizedDescription)")
        }
    }

    private func startReceiveLoop() {
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let stillRunning = await self?.pumpOnce(), stillRunning else { return }
            }
        }
    }

    /// Receive one message, dispatch it, and report whether the loop should
    /// continue. Returns `false` after fatal errors or graceful close.
    private func pumpOnce() async -> Bool {
        guard !closed else { return false }
        let message: ServerMessage
        do {
            message = try await receiveOne()
        } catch {
            eventsContinuation.yield(.warning("websocket error: \(error.localizedDescription)"))
            await tearDown()
            return false
        }
        switch message {
        case .sessionStarted:
            // Re-handshake mid-stream is unexpected but harmless; ignore.
            return true
        case .partialTranscript(let text):
            eventsContinuation.yield(.partial(text: text, stability: 0.8))
            return true
        case .committedTranscript(let text):
            eventsContinuation.yield(.final(text: text, alternatives: []))
            return true
        case .error(let kind, let message):
            eventsContinuation.yield(.warning("\(kind): \(message)"))
            await tearDown()
            return false
        case .unknown(let messageType):
            eventsContinuation.yield(.warning("unknown message_type: \(messageType)"))
            return true
        }
    }

    private func tearDown() async {
        if closed { return }
        closed = true
        receiveTask?.cancel()
        receiveTask = nil
        task.cancel(with: .normalClosure, reason: nil)
        eventsContinuation.finish()
    }

    // MARK: - Encoding helpers

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder = JSONDecoder()

    /// Pack a slice of `Int16` samples into little-endian bytes and base64.
    /// Per the ElevenLabs spec: `audio_format=pcm_16000` is signed 16-bit LE.
    static func base64(samples: [Int16]) -> String {
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

    private static func mapNetworkError(_ error: Error) -> SttError {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorCancelled:
                return .cancelled
            case NSURLErrorUserAuthenticationRequired:
                return .authentication
            case NSURLErrorTimedOut,
                 NSURLErrorNetworkConnectionLost,
                 NSURLErrorNotConnectedToInternet:
                return .transient(ns.localizedDescription)
            default:
                return .fatal(ns.localizedDescription)
            }
        }
        return .fatal(error.localizedDescription)
    }
}
