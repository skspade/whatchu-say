#if os(macOS)
@preconcurrency import AppKit
import Foundation

/// Subscribes to `NSWorkspace.willSleepNotification` and invokes the
/// supplied callback whenever the system is about to sleep.
///
/// Wake is intentionally not observed: `AVAudioCapture` rebuilds its engine
/// on the next `start()` and the orchestrator opens a fresh STT session for
/// every dictation, so once the active session is torn down on sleep there
/// is no cached state left to clear at wake time.
@MainActor
public final class SleepWakeObserver {
    private let onSleep: @Sendable () async -> Void
    private var token: NSObjectProtocol?

    public init(onSleep: @Sendable @escaping () async -> Void) {
        self.onSleep = onSleep
    }

    /// Register for `willSleepNotification`. Idempotent — repeat calls
    /// without an intervening `stop()` are no-ops.
    public func start() {
        guard token == nil else { return }
        let center = NSWorkspace.shared.notificationCenter
        let onSleep = onSleep
        token = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { _ in
            // Detach to avoid blocking the notification queue.
            Task { await onSleep() }
        }
    }

    /// Unregister the observer. Safe to call when not started. Callers
    /// (e.g. `AppCoordinator.shutdown()`) own teardown — there is no
    /// `deinit` cleanup because Swift 6's nonisolated `deinit` cannot reach
    /// the MainActor-isolated `token`. Forgetting to call `stop()` leaks
    /// the observer for the rest of the process lifetime.
    public func stop() {
        if let token {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        token = nil
    }
}
#endif
