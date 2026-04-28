import Foundation
@testable import Audio
@testable import Injector
@testable import Orchestrator
@testable import STTCore

// MARK: - FakeInjector

/// Records every text passed to `inject(text:hint:)` so tests can assert on it.
actor FakeInjector: Injector {
    private(set) var received: [String] = []
    private(set) var hints: [InjectionHint] = []

    func inject(text: String, hint: InjectionHint) async throws {
        received.append(text)
        hints.append(hint)
    }
}

// MARK: - FakeAudioCapture

/// In-memory `AudioCapturing` that lets tests push frames and counts
/// `start()`/`stop()` invocations.
actor FakeAudioCapture: AudioCapturing {
    nonisolated let frames: AsyncStream<AudioFrame>
    nonisolated let rmsLevels: AsyncStream<Float>

    private nonisolated let framesContinuation: AsyncStream<AudioFrame>.Continuation
    private nonisolated let rmsContinuation: AsyncStream<Float>.Continuation
    private(set) var startCount: Int = 0
    private(set) var stopCount: Int = 0

    init() {
        let (fStream, fCont) = AsyncStream<AudioFrame>.makeStream()
        let (rStream, rCont) = AsyncStream<Float>.makeStream()
        self.frames = fStream
        self.rmsLevels = rStream
        self.framesContinuation = fCont
        self.rmsContinuation = rCont
    }

    func start() async throws {
        startCount += 1
    }

    func stop() async {
        stopCount += 1
        // Mirror AVAudioCapture: yield an end-of-session sentinel (empty
        // samples) so the orchestrator's drain waiter resumes.
        framesContinuation.yield(AudioFrame(samples: [], timestamp: .zero))
    }

    nonisolated func push(_ frame: AudioFrame) {
        framesContinuation.yield(frame)
    }
}

// MARK: - ManualTimerScheduler

/// Manual scheduler for deterministic tests. Stores actions until `fireAll()`
/// is called, then invokes them all sequentially.
actor ManualTimerScheduler: TimerScheduler {
    private var nextID: UInt64 = 0
    private var pending: [TimerToken: @Sendable () async -> Void] = [:]

    func schedule(
        after duration: Duration,
        action: @Sendable @escaping () async -> Void
    ) async -> TimerToken {
        nextID += 1
        let token = TimerToken(id: nextID)
        pending[token] = action
        return token
    }

    func cancel(_ token: TimerToken) async {
        pending.removeValue(forKey: token)
    }

    /// Fire every pending timer action sequentially. Returns when all
    /// fired actions have completed.
    func fireAll() async {
        let actions = Array(pending.values)
        pending.removeAll()
        for action in actions {
            await action()
        }
    }

    var pendingCount: Int {
        pending.count
    }
}

// MARK: - ScriptableProvider / ScriptableSession

/// Provider whose sessions stay open until tests explicitly yield events.
/// Unlike `MockProvider`, `endOfStream()` is a no-op — tests must call
/// `yieldFinal(_:)` themselves to drive the orchestrator's awaitFinal path.
actor ScriptableProvider: SttProvider {
    nonisolated let name = "scriptable"
    nonisolated let capabilities = Capabilities(
        partials: true,
        punctuation: true,
        languages: .auto,
        sampleRates: [16_000],
        maxSessionSeconds: nil,
        supportsClientEndpointing: true
    )

    private(set) var sessions: [ScriptableSession] = []

    func open(config: SessionConfig) async throws -> any SttSession {
        let session = ScriptableSession()
        sessions.append(session)
        return session
    }

    /// The most recently opened session, or nil if none.
    var lastSession: ScriptableSession? { sessions.last }

    func yieldPartial(_ text: String, stability: Float = 0.5) {
        sessions.last?.yieldPartial(text, stability: stability)
    }

    func yieldFinal(_ text: String) {
        sessions.last?.yieldFinal(text)
    }

    func yieldWarning(_ message: String) {
        sessions.last?.yieldWarning(message)
    }
}

/// Test-controlled STT session. The events stream is driven by the test via
/// `yield*` calls; `endOfStream()` does not auto-emit a `.final`.
final class ScriptableSession: SttSession, @unchecked Sendable {
    nonisolated let events: AsyncStream<SttEvent>
    private let continuation: AsyncStream<SttEvent>.Continuation

    init() {
        let (stream, cont) = AsyncStream<SttEvent>.makeStream()
        self.events = stream
        self.continuation = cont
    }

    func pushAudio(_ samples: [Int16]) async throws {}
    func endOfStream() async throws {}
    func close() async { continuation.finish() }

    func yieldPartial(_ text: String, stability: Float = 0.5) {
        continuation.yield(.partial(text: text, stability: stability))
    }

    func yieldFinal(_ text: String) {
        continuation.yield(.final(text: text, alternatives: []))
    }

    func yieldWarning(_ message: String) {
        continuation.yield(.warning(message))
    }
}

// MARK: - RecordingProvider / RecordingSession

/// Provider whose sessions model ElevenLabs `commit_strategy=manual` semantics:
/// every `pushAudio` is recorded; on `endOfStream`, the session snapshots how
/// many frames have been received and yields a `.final` whose text encodes
/// just those frames. Frames pushed AFTER `endOfStream` go into a separate
/// bucket and are NOT in the final — mirroring how the real server commits
/// only audio it received before the commit signal.
actor RecordingProvider: SttProvider {
    nonisolated let name = "recording"
    nonisolated let capabilities = Capabilities(
        partials: true,
        punctuation: true,
        languages: .auto,
        sampleRates: [16_000],
        maxSessionSeconds: nil,
        supportsClientEndpointing: true
    )

    private(set) var sessions: [RecordingSession] = []

    func open(config: SessionConfig) async throws -> any SttSession {
        let session = RecordingSession()
        sessions.append(session)
        return session
    }

    var lastSession: RecordingSession? { sessions.last }
}

actor RecordingSession: SttSession {
    nonisolated let events: AsyncStream<SttEvent>
    private nonisolated let continuation: AsyncStream<SttEvent>.Continuation

    private(set) var framesBeforeEOS: [[Int16]] = []
    private(set) var framesAfterEOS: [[Int16]] = []
    private(set) var endOfStreamSeen = false
    private var closed = false

    init() {
        let (stream, cont) = AsyncStream<SttEvent>.makeStream()
        self.events = stream
        self.continuation = cont
    }

    /// Yields a few times before recording. Models WebSocket-send latency:
    /// the bug we exercise depends on `endOfStream` being eligible to
    /// arrive on this actor while earlier pushAudio invocations are still
    /// mid-flight. With the fix in place the orchestrator drains first, so
    /// the yields no longer lose frames — but they keep the test honest by
    /// preventing a spuriously-fast pushAudio path from hiding regressions.
    func pushAudio(_ samples: [Int16]) async throws {
        for _ in 0..<4 { await Task.yield() }
        if endOfStreamSeen {
            framesAfterEOS.append(samples)
        } else {
            framesBeforeEOS.append(samples)
        }
    }

    func endOfStream() async throws {
        endOfStreamSeen = true
        let text = framesBeforeEOS.map { String($0.first ?? 0) }.joined(separator: ",")
        continuation.yield(.final(text: text, alternatives: []))
    }

    func close() async {
        guard !closed else { return }
        closed = true
        continuation.finish()
    }
}

// MARK: - EventCollector

/// Drains an `AsyncStream<OrchestratorEvent>` into an array so tests can
/// assert on lifecycle events. Call `snapshot()` after the work under test
/// completes — it briefly yields to allow any in-flight forwarding tasks to
/// drain into the buffer.
actor EventCollector {
    private(set) var collected: [OrchestratorEvent] = []
    private var task: Task<Void, Never>?

    func start(stream: AsyncStream<OrchestratorEvent>) {
        let captured = self
        task = Task {
            for await event in stream {
                await captured.append(event)
            }
        }
    }

    private func append(_ event: OrchestratorEvent) {
        collected.append(event)
    }

    /// Yield a few times to give the consumer Task a chance to process any
    /// recently-yielded events still in flight, then return what's been
    /// collected so far.
    func snapshot() async -> [OrchestratorEvent] {
        for _ in 0..<8 { await Task.yield() }
        return collected
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
