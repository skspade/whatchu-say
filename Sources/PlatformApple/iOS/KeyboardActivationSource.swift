#if os(iOS)
import Foundation
import Hotkey

/// `HotkeySource` driven by mic-button gestures inside the iOS keyboard
/// extension. The `UIInputViewController` subclass calls `pressBegan()`,
/// `pressEnded()`, and `cancelled()` from its gesture recognizer (or
/// SwiftUI gesture callbacks) and we route those into the FSM as the
/// equivalent of hotkey events.
///
/// PRD §6.7 disqualifies hands-free in keyboard extensions, so even though
/// the FSM is capable of double-tap → hands-free, in practice the gesture
/// only ever fires one keyDown per press. To be defensive about that, the
/// orchestrator on iOS should construct its `ActivationStateMachine` with
/// `HotkeyConfig(doubleTapWindow: .zero)` so a stray double-fire can't
/// elevate to a mode the extension can't actually support.
public actor KeyboardActivationSource: HotkeySource {
    private var handler: (@Sendable (HotkeyEvent) async -> Void)?

    public init() {}

    public func start(
        handler: @Sendable @escaping (HotkeyEvent) async -> Void
    ) async throws {
        self.handler = handler
    }

    public func stop() async {
        handler = nil
    }

    /// User pressed the mic button. Equivalent to a hotkey key-down.
    public func pressBegan(at date: Date = Date()) async {
        await handler?(.keyDown(at: date))
    }

    /// User released the mic button while still over it. Triggers
    /// finalization in press-hold mode.
    public func pressEnded(at date: Date = Date()) async {
        await handler?(.keyUp(at: date))
    }

    /// Touch-up-outside the button bounds. Routes through the FSM's cancel
    /// path so the in-flight session is closed without injecting.
    public func cancelled(at date: Date = Date()) async {
        await handler?(.cancelKey(at: date))
    }
}
#endif
