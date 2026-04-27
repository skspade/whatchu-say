import Foundation
@testable import Audio
@testable import Injector
@testable import Orchestrator

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
