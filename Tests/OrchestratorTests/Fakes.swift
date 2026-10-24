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

// MARK: - PermissionDeniedAudioCapture

/// `AudioCapturing` that always throws `AudioCaptureError.permissionDenied`
/// from `start()`. Lets tests exercise the orchestrator's permission-denial
/// path without standing up real `AVAudioCapture`.
actor PermissionDeniedAudioCapture: AudioCapturing {
    nonisolated let frames: AsyncStream<AudioFrame>
    nonisolated let rmsLevels: AsyncStream<Float>
    private nonisolated let framesContinuation: AsyncStream<AudioFrame>.Continuation
    private nonisolated let rmsContinuation: AsyncStream<Float>.Continuation
    private(set) var startCount: Int = 0

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
        throw AudioCaptureError.permissionDenied
    }

    func stop() async {}
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

    func yieldPartial(_ text: String, stability: Float = 0.5) async {
        await sessions.last?.yieldPartial(text, stability: stability)
    }

    func yieldFinal(_ text: String) async {
        await sessions.last?.yieldFinal(text)
    }

    func yieldWarning(_ message: String) async {
        await sessions.last?.yieldWarning(message)
    }

    /// Wait until the orchestrator has handled every event yielded so far on
    /// the most recent session. See `SessionEventQueue`.
    func waitUntilHandled() async {
        await sessions.last?.waitUntilHandled()
    }
}

/// Test-controlled STT session. The events stream is driven by the test via
/// `yield*` calls; `endOfStream()` does not auto-emit a `.final` but it does
/// finish the events stream — mirrors the real provider, which closes the
/// WebSocket after responding to EOS so the orchestrator's `awaitFinal()` knows
/// "no more commits are coming."
final class ScriptableSession: SttSession, @unchecked Sendable {
    nonisolated let events: AsyncStream<SttEvent>
    private let queue: SessionEventQueue

    init() {
        let queue = SessionEventQueue()
        self.queue = queue
        self.events = queue.makeStream()
    }

    func pushAudio(_ samples: [Int16]) async throws {}
    func endOfStream() async throws { await queue.finish() }
    func close() async { await queue.finish() }

    func yieldPartial(_ text: String, stability: Float = 0.5) async {
        await queue.yield(.partial(text: text, stability: stability))
    }

    func yieldFinal(_ text: String) async {
        await queue.yield(.final(text: text, alternatives: []))
    }

    func yieldWarning(_ message: String) async {
        await queue.yield(.warning(message))
    }

    func waitUntilHandled() async {
        await queue.waitUntilHandled()
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
    ///
    /// Also yields a `.partial` event whenever pre-EOS audio is recorded,
    /// mirroring the real provider: ElevenLabs replies to streamed audio
    /// with `partial_transcript` messages. Without this, the orchestrator's
    /// silence fast-path would short-circuit finalize before EOS.
    func pushAudio(_ samples: [Int16]) async throws {
        for _ in 0..<4 { await Task.yield() }
        if endOfStreamSeen {
            framesAfterEOS.append(samples)
        } else {
            framesBeforeEOS.append(samples)
            continuation.yield(.partial(text: "stub", stability: 0.5))
        }
    }

    func endOfStream() async throws {
        endOfStreamSeen = true
        let text = framesBeforeEOS.map { String($0.first ?? 0) }.joined(separator: ",")
        continuation.yield(.final(text: text, alternatives: []))
        // Mirror real provider: WS closes after EOS commit, finishing the events stream.
        guard !closed else { return }
        closed = true
        continuation.finish()
    }

    func close() async {
        guard !closed else { return }
        closed = true
        continuation.finish()
    }
}

// MARK: - GatedOpenProvider

/// Provider whose `open()` suspends until the test calls `releaseOpen()` or
/// `failOpen()`, modelling the WebSocket connect + `session_started`
/// handshake. Sessions are `RecordingSession`s so tests can assert exactly
/// which samples reached the server, and in what order.
actor GatedOpenProvider: SttProvider {
    nonisolated let name = "gated-open"
    nonisolated let capabilities = Capabilities(
        partials: true,
        punctuation: true,
        languages: .auto,
        sampleRates: [16_000],
        maxSessionSeconds: nil,
        supportsClientEndpointing: true
    )

    private(set) var sessions: [RecordingSession] = []
    private var openContinuation: CheckedContinuation<Bool, Never>?

    func open(config: SessionConfig) async throws -> any SttSession {
        let succeed: Bool = await withCheckedContinuation { cont in
            openContinuation = cont
        }
        guard succeed else { throw SttError.transient("handshake failed") }
        let session = RecordingSession()
        sessions.append(session)
        return session
    }

    var lastSession: RecordingSession? { sessions.last }

    var isOpenPending: Bool { openContinuation != nil }

    func releaseOpen() { resumeOpen(succeed: true) }

    func failOpen() { resumeOpen(succeed: false) }

    private func resumeOpen(succeed: Bool) {
        guard let cont = openContinuation else { return }
        openContinuation = nil
        cont.resume(returning: succeed)
    }
}

// MARK: - MultiSegmentProvider / MultiSegmentSession

/// Provider whose sessions model ElevenLabs streaming with `commit_strategy=auto`:
/// the server commits a separate `committed_transcript` per pause-segment during
/// the session, plus one final commit in response to `end_of_stream`, then closes
/// the WebSocket. Tests pre-load the during-session segments via `yieldFinal`
/// and the post-EOS commit via `setEndOfStreamFinal`.
///
/// Mirrors the real provider's lifecycle in two key ways:
/// 1. Multiple `.final` events can arrive for a single session (one per segment).
/// 2. The events stream finishes after `endOfStream` (real WS closes after the
///    EOS commit). The orchestrator relies on this signal to know "no more
///    finals are coming" and return the accumulated transcript.
actor MultiSegmentProvider: SttProvider {
    nonisolated let name = "multi-segment"
    nonisolated let capabilities = Capabilities(
        partials: true,
        punctuation: true,
        languages: .auto,
        sampleRates: [16_000],
        maxSessionSeconds: nil,
        supportsClientEndpointing: true
    )

    private(set) var sessions: [MultiSegmentSession] = []

    func open(config: SessionConfig) async throws -> any SttSession {
        let session = MultiSegmentSession()
        sessions.append(session)
        return session
    }

    var lastSession: MultiSegmentSession? { sessions.last }
}

actor MultiSegmentSession: SttSession {
    nonisolated let events: AsyncStream<SttEvent>
    private let queue: SessionEventQueue

    private var endOfStreamFinal: String?

    init() {
        let queue = SessionEventQueue()
        self.queue = queue
        self.events = queue.makeStream()
    }

    /// Yield a pause-segment commit. Mirrors a `committed_transcript` arriving
    /// from the server while the user is still talking.
    func yieldFinal(_ text: String) async {
        await queue.yield(.final(text: text, alternatives: []))
    }

    /// Wait until the orchestrator has handled every event yielded so far.
    /// See `SessionEventQueue`.
    func waitUntilHandled() async {
        await queue.waitUntilHandled()
    }

    /// Pre-load the text the session will commit in response to `endOfStream`.
    /// Pass `nil` to commit nothing (just close the events stream).
    func setEndOfStreamFinal(_ text: String?) {
        endOfStreamFinal = text
    }

    func pushAudio(_ samples: [Int16]) async throws {}

    func endOfStream() async throws {
        if let text = endOfStreamFinal {
            await queue.yield(.final(text: text, alternatives: []))
        }
        // Mirror the real provider: server closes WS after the EOS commit.
        await queue.finish()
    }

    func close() async {
        await queue.finish()
    }
}

// MARK: - DelayedCloseProvider / DelayedCloseSession

/// Provider whose sessions yield a committed transcript in response to
/// `endOfStream()` but do NOT finish the events stream — simulating a slow
/// WebSocket close after the server has already sent the committed transcript.
actor DelayedCloseProvider: SttProvider {
    nonisolated let name = "delayed-close"
    nonisolated let capabilities = Capabilities(
        partials: true,
        punctuation: true,
        languages: .auto,
        sampleRates: [16_000],
        maxSessionSeconds: nil,
        supportsClientEndpointing: true
    )

    private(set) var sessions: [DelayedCloseSession] = []

    func open(config: SessionConfig) async throws -> any SttSession {
        let session = DelayedCloseSession()
        sessions.append(session)
        return session
    }

    var lastSession: DelayedCloseSession? { sessions.last }
}

/// Session that yields a `.final` on `endOfStream()` but keeps the events
/// stream open until `close()` or `finishStream()` is called. Models the
/// real-world case where ElevenLabs responds with a committed transcript
/// promptly but is slow to close the WebSocket.
actor DelayedCloseSession: SttSession {
    nonisolated let events: AsyncStream<SttEvent>
    private nonisolated let continuation: AsyncStream<SttEvent>.Continuation

    private var committedText: String = "delayed close transcription"
    private var closed = false

    init() {
        let (stream, cont) = AsyncStream<SttEvent>.makeStream()
        self.events = stream
        self.continuation = cont
    }

    func setCommittedText(_ text: String) {
        committedText = text
    }

    /// Yield a partial transcript. Tests use this to mark the session as
    /// "server heard speech," matching the real provider's behaviour: a
    /// session that produces a committed transcript always has at least one
    /// preceding `partial_transcript`. Without it, the orchestrator's
    /// silence fast-path would tear the session down before EOS.
    nonisolated func yieldPartial(_ text: String = "stub") {
        continuation.yield(.partial(text: text, stability: 0.5))
    }

    func pushAudio(_ samples: [Int16]) async throws {}

    func endOfStream() async throws {
        continuation.yield(.final(text: committedText, alternatives: []))
    }

    func close() async {
        guard !closed else { return }
        closed = true
        continuation.finish()
    }

    nonisolated func finishStream() {
        continuation.finish()
    }
}

// MARK: - SilentProvider / SilentSession

/// Provider whose sessions never emit any `.partial` or `.final`. `endOfStream`
/// is accepted (and recorded) but yields nothing; the events stream stays open
/// until `close()`. Models ElevenLabs' "no audio activity" path, where the
/// server eventually sends `insufficient_audio_activity` ~10 s after an empty
/// commit — long enough to wedge the orchestrator if it waits on EOS.
actor SilentProvider: SttProvider {
    nonisolated let name = "silent"
    nonisolated let capabilities = Capabilities(
        partials: true,
        punctuation: true,
        languages: .auto,
        sampleRates: [16_000],
        maxSessionSeconds: nil,
        supportsClientEndpointing: true
    )

    private(set) var sessions: [SilentSession] = []

    func open(config: SessionConfig) async throws -> any SttSession {
        let session = SilentSession()
        sessions.append(session)
        return session
    }

    var lastSession: SilentSession? { sessions.last }
}

actor SilentSession: SttSession {
    nonisolated let events: AsyncStream<SttEvent>
    private nonisolated let continuation: AsyncStream<SttEvent>.Continuation
    private(set) var endOfStreamCount: Int = 0
    private var closed = false

    init() {
        let (stream, cont) = AsyncStream<SttEvent>.makeStream()
        self.events = stream
        self.continuation = cont
    }

    func pushAudio(_ samples: [Int16]) async throws {}

    func endOfStream() async throws {
        endOfStreamCount += 1
    }

    func close() async {
        guard !closed else { return }
        closed = true
        continuation.finish()
    }

    /// Yield a partial transcript without yielding any final. Used by the
    /// finalize-timeout tests to model the "server got speech but never
    /// committed and the WebSocket is hanging" pathological path —
    /// distinct from the bare-silence fast-path the suite was built for.
    nonisolated func yieldPartial(_ text: String = "stub") {
        continuation.yield(.partial(text: text, stability: 0.5))
    }
}

// MARK: - BlockingPushProvider / BlockingPushSession

/// Provider whose session can suspend inside `pushAudio(_:)` until tests or
/// `close()` release it. This models a WebSocket send stuck behind a broken
/// connection while the receive side has already surfaced stream termination.
actor BlockingPushProvider: SttProvider {
    nonisolated let name = "blocking-push"
    nonisolated let capabilities = Capabilities(
        partials: true,
        punctuation: true,
        languages: .auto,
        sampleRates: [16_000],
        maxSessionSeconds: nil,
        supportsClientEndpointing: true
    )

    private(set) var sessions: [BlockingPushSession] = []

    func open(config: SessionConfig) async throws -> any SttSession {
        let session = BlockingPushSession()
        sessions.append(session)
        return session
    }

    var lastSession: BlockingPushSession? { sessions.last }
}

actor BlockingPushSession: SttSession {
    nonisolated let events: AsyncStream<SttEvent>
    private nonisolated let continuation: AsyncStream<SttEvent>.Continuation

    private var pushContinuation: CheckedContinuation<Void, Never>?
    private var pushStarted = false
    private var closed = false
    private(set) var endOfStreamCount = 0
    private(set) var closeCount = 0

    init() {
        let (stream, cont) = AsyncStream<SttEvent>.makeStream()
        self.events = stream
        self.continuation = cont
    }

    func pushAudio(_ samples: [Int16]) async throws {
        pushStarted = true
        await withCheckedContinuation { cont in
            pushContinuation = cont
        }
        if closed {
            throw SttError.cancelled
        }
    }

    func endOfStream() async throws {
        endOfStreamCount += 1
    }

    func close() async {
        closeCount += 1
        closed = true
        releasePush()
        continuation.finish()
    }

    var isPushBlocked: Bool {
        pushStarted && pushContinuation != nil
    }

    func releasePush() {
        guard let cont = pushContinuation else { return }
        pushContinuation = nil
        cont.resume()
    }

    nonisolated func yieldPartial(_ text: String) {
        continuation.yield(.partial(text: text, stability: 0.5))
    }

    nonisolated func finishStream() {
        continuation.finish()
    }
}

// MARK: - SendFailureProvider / SendFailureSession

/// Models the real-world failure mode where the WebSocket's **send**
/// direction dies mid-transcription but the receive side is stuck in
/// `receive()` and never surfaces the error. `pushAudio` throws a
/// non-cancelled error on every call; the events stream is NOT finished
/// (mirrors `ElevenLabsSession` when `URLSessionWebSocketTask.receive()`
/// never returns). Without orchestrator-level recovery, this wedges the
/// app in listening mode until restart.
actor SendFailureProvider: SttProvider {
    nonisolated let name = "send-failure"
    nonisolated let capabilities = Capabilities(
        partials: true,
        punctuation: true,
        languages: .auto,
        sampleRates: [16_000],
        maxSessionSeconds: nil,
        supportsClientEndpointing: true
    )

    private(set) var sessions: [SendFailureSession] = []

    func open(config: SessionConfig) async throws -> any SttSession {
        let session = SendFailureSession()
        sessions.append(session)
        return session
    }

    var lastSession: SendFailureSession? { sessions.last }
}

final class SendFailureSession: SttSession, @unchecked Sendable {
    nonisolated let events: AsyncStream<SttEvent>
    private nonisolated let continuation: AsyncStream<SttEvent>.Continuation
    private(set) var pushCount: Int = 0

    init() {
        let (stream, cont) = AsyncStream<SttEvent>.makeStream()
        self.events = stream
        self.continuation = cont
    }

    func pushAudio(_ samples: [Int16]) async throws {
        pushCount += 1
        // Simulate a dead send direction. Non-cancelled: this is a genuine
        // transport failure, not normal teardown.
        throw SttError.transient("websocket send failed")
    }

    func endOfStream() async throws {}

    /// Only finishes the events stream on explicit close — i.e. the receive
    /// side is stuck and never finishes it on its own.
    func close() async { continuation.finish() }
}

// MARK: - SessionEventQueue

/// Backs a fake session's `events` stream and lets a test wait until the
/// orchestrator has handled every event yielded so far. The orchestrator's
/// session consumer asks for the next event only after `handleSessionEvent`
/// returns for the previous one, so once it asks with nothing buffered,
/// everything yielded has been handled.
///
/// Tests need this before releasing the hotkey: finalize's "no speech heard"
/// fast path reads state that the consumer Task sets, and `.final` emits no
/// `OrchestratorEvent` for an `EventCollector` to wait on.
actor SessionEventQueue {
    private var buffered: [SttEvent] = []
    private var finished = false
    private var consumer: CheckedContinuation<SttEvent?, Never>?
    private var handledWaiters: [CheckedContinuation<Void, Never>] = []

    nonisolated func makeStream() -> AsyncStream<SttEvent> {
        AsyncStream(unfolding: { await self.next() })
    }

    func yield(_ event: SttEvent) {
        guard !finished else { return }
        if let consumer {
            self.consumer = nil
            consumer.resume(returning: event)
        } else {
            buffered.append(event)
        }
    }

    /// Like `AsyncStream.Continuation.finish()`: buffered events are still
    /// delivered, then the stream ends.
    func finish() {
        finished = true
        consumer?.resume(returning: nil)
        consumer = nil
    }

    func waitUntilHandled() async {
        guard consumer == nil, !finished else { return }
        await withCheckedContinuation { handledWaiters.append($0) }
    }

    private func next() async -> SttEvent? {
        if !buffered.isEmpty { return buffered.removeFirst() }
        for waiter in handledWaiters { waiter.resume() }
        handledWaiters = []
        if finished { return nil }
        return await withCheckedContinuation { consumer = $0 }
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
    private var waiter: (expected: OrchestratorEvent, continuation: CheckedContinuation<Void, Never>)?

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
        if let waiter, waiter.expected == event {
            self.waiter = nil
            waiter.continuation.resume()
        }
    }

    /// Yield a few times to give the consumer Task a chance to process any
    /// recently-yielded events still in flight, then return what's been
    /// collected so far.
    func snapshot() async -> [OrchestratorEvent] {
        for _ in 0..<8 { await Task.yield() }
        return collected
    }

    /// Wait until a specific event has been collected, then return the full
    /// buffer. This avoids sampling the stream before the consumer Task has
    /// processed an async event. Gives up after 10 s so a regression fails
    /// its expectations instead of hanging the run.
    func waitForEvent(_ expected: OrchestratorEvent) async -> [OrchestratorEvent] {
        if collected.contains(expected) { return collected }
        let timeoutTask = Task {
            try await Task.sleep(for: .seconds(10))
            self.stopWaiting()
        }
        await withCheckedContinuation { waiter = (expected, $0) }
        timeoutTask.cancel()
        return collected
    }

    private func stopWaiting() {
        waiter?.continuation.resume()
        waiter = nil
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
