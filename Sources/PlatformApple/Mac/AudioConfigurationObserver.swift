#if os(macOS)
@preconcurrency import AVFoundation
import Foundation

/// Subscribes to `AVAudioEngineConfigurationChange` and invokes the supplied
/// callback whenever the audio engine's I/O configuration changes — for
/// example, the default input device switching (headphones plugged in,
/// Bluetooth headset disconnected) or the user changing the input in
/// System Settings while a session is live.
///
/// Mirrors `SleepWakeObserver`'s shape so AppCoordinator wiring is symmetric.
/// The orchestrator's `handleAudioInterruption()` is the intended callback
/// target — it tears down the active session and surfaces a clear error.
@MainActor
public final class AudioConfigurationObserver {
    private let onChange: @Sendable () async -> Void
    private var token: NSObjectProtocol?

    public init(onChange: @Sendable @escaping () async -> Void) {
        self.onChange = onChange
    }

    /// Register for `AVAudioEngineConfigurationChange`. Idempotent —
    /// repeat calls without an intervening `stop()` are no-ops.
    public func start() {
        guard token == nil else { return }
        let onChange = onChange
        token = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: .main
        ) { _ in
            // Detach to avoid blocking the notification queue.
            Task { await onChange() }
        }
    }

    /// Unregister the observer. Safe to call when not started. Callers
    /// own teardown; there is no `deinit` cleanup because Swift 6's
    /// nonisolated `deinit` cannot reach the MainActor-isolated `token`.
    public func stop() {
        if let token {
            NotificationCenter.default.removeObserver(token)
        }
        token = nil
    }
}
#endif
