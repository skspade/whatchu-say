import Foundation

/// Platform-agnostic hotkey source. The orchestrator subscribes once via
/// `start(handler:)` and receives `HotkeyEvent`s asynchronously. Concrete
/// implementations (CGEventTap on Mac, gesture recognizer in iOS keyboard
/// extensions) hide the platform plumbing.
public protocol HotkeySource: Sendable {
    /// Begin listening. The handler is invoked for every translated event.
    /// Calling `start` while already running is a no-op.
    func start(
        handler: @Sendable @escaping (HotkeyEvent) async -> Void
    ) async throws
    /// Stop listening and release platform resources. Idempotent.
    func stop() async
}

public enum HotkeySourceError: Error, Sendable, Equatable {
    /// CGEventTap creation failed — almost always because the host app lacks
    /// the Accessibility (Input Monitoring) entitlement at the OS level.
    case accessibilityDenied
    /// CGEventTap was created but the run-loop source could not be derived.
    case tapInstallFailed
}
