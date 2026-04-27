import Foundation

/// Opaque handle returned by `TimerScheduler.schedule`. Used to cancel a timer.
public struct TimerToken: Sendable, Equatable, Hashable {
    public let id: UInt64
    public init(id: UInt64) { self.id = id }
}

/// Abstraction over single-shot timers. The real implementation uses
/// `Task.sleep`; tests use a manual scheduler that lets them advance time
/// deterministically.
public protocol TimerScheduler: Sendable {
    func schedule(after duration: Duration, action: @Sendable @escaping () async -> Void) async -> TimerToken
    func cancel(_ token: TimerToken) async
}

/// Production scheduler: uses `Task.sleep` for the wait.
public actor TaskTimerScheduler: TimerScheduler {
    private var nextID: UInt64 = 0
    private var tasks: [TimerToken: Task<Void, Never>] = [:]

    public init() {}

    public func schedule(
        after duration: Duration,
        action: @Sendable @escaping () async -> Void
    ) async -> TimerToken {
        nextID += 1
        let token = TimerToken(id: nextID)
        let task = Task {
            try? await Task.sleep(for: duration)
            if !Task.isCancelled {
                await action()
            }
        }
        tasks[token] = task
        return token
    }

    public func cancel(_ token: TimerToken) async {
        tasks[token]?.cancel()
        tasks.removeValue(forKey: token)
    }
}
