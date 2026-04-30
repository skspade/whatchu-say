#if os(iOS)
import Foundation
@preconcurrency import AVFoundation

/// Configures `AVAudioSession` for record-only capture inside the iOS
/// keyboard extension. Mac `AVAudioCapture` doesn't need this — `AudioSession`
/// is iOS-only and the existing `Sources/Audio/AVAudioCapture.swift` should
/// call `activate()` before `engine.start()` and `deactivate()` after
/// `engine.stop()` on iOS only (gated `#if os(iOS)`).
///
/// Surfaces interruptions (calls, Siri, alarms) and route changes (BT
/// connect/disconnect, headphone unplug) via the `events` stream so the
/// orchestrator can decide whether to cancel the in-flight session. Per the
/// design doc's no-silent-recovery policy, the right reaction to an
/// interruption mid-utterance is to cancel and let the user retry — same as
/// a network drop. We don't try to resume.
public actor AudioSessioniOS {
    public enum Event: Sendable {
        /// `AVAudioSession.InterruptionType == .began` — call/Siri/alarm.
        /// Treat as cancellation; mic input is already gone.
        case interruptionBegan
        /// `AVAudioSession.InterruptionType == .ended`. We do not auto-resume;
        /// the user retries via a fresh hotkey press.
        case interruptionEnded
        /// Route change (headphones in/out, Bluetooth connect, etc.).
        /// Orchestrator decides whether to cancel — mid-utterance route
        /// swaps usually break the WebSocket framing anyway.
        case routeChanged(reason: AVAudioSession.RouteChangeReason)
    }

    public nonisolated let events: AsyncStream<Event>
    private nonisolated let eventsContinuation: AsyncStream<Event>.Continuation

    private var interruptionObserver: NSObjectProtocol?
    private var routeObserver: NSObjectProtocol?
    private var active = false

    public init() {
        let (stream, cont) = AsyncStream<Event>.makeStream()
        self.events = stream
        self.eventsContinuation = cont
    }

    /// Configure category/mode and activate the session. Idempotent — a
    /// second `activate()` while already active is a no-op.
    public func activate() async throws {
        guard !active else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .record,
            mode: .measurement,
            options: [.allowBluetoothHFP, .allowBluetoothA2DP]
        )
        try session.setPreferredSampleRate(16_000)
        try session.setPreferredIOBufferDuration(0.02) // 20 ms
        try session.setActive(true, options: [])
        installObservers()
        active = true
    }

    /// Deactivate. Idempotent. `notifyOthersOnDeactivation` lets background
    /// audio (music apps, etc.) resume on the host device.
    public func deactivate() async {
        guard active else { return }
        removeObservers()
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: [.notifyOthersOnDeactivation]
        )
        active = false
    }

    // MARK: - Observers

    private func installObservers() {
        let center = NotificationCenter.default
        let yieldEvent = { [eventsContinuation] (event: Event) in
            eventsContinuation.yield(event)
        }
        interruptionObserver = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: nil
        ) { note in
            guard let info = note.userInfo,
                  let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw)
            else { return }
            switch type {
            case .began: yieldEvent(.interruptionBegan)
            case .ended: yieldEvent(.interruptionEnded)
            @unknown default: break
            }
        }
        routeObserver = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: nil
        ) { note in
            guard let info = note.userInfo,
                  let raw = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw)
            else { return }
            yieldEvent(.routeChanged(reason: reason))
        }
    }

    private func removeObservers() {
        let center = NotificationCenter.default
        if let interruptionObserver { center.removeObserver(interruptionObserver) }
        if let routeObserver { center.removeObserver(routeObserver) }
        interruptionObserver = nil
        routeObserver = nil
    }
}
#endif
