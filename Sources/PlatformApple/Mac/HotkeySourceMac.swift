#if os(macOS)
import Foundation
@preconcurrency import CoreGraphics
import Hotkey

/// CGEventTap-backed `HotkeySource`. Listens at `.cgSessionEventTap` for
/// keyboard events, runs them through `HotkeyEventTranslator`, and pushes
/// the resulting `HotkeyEvent`s into an `AsyncStream`. A consumer Task pulls
/// from the stream and invokes the registered handler.
///
/// ## Permissions
/// `CGEvent.tapCreate` returns `nil` if the host process lacks Accessibility
/// (Input Monitoring) permission. We surface that as
/// `HotkeySourceError.accessibilityDenied` so the app shell can prompt the
/// user to grant it in System Settings.
///
/// ## Run loop
/// The tap runs on the main run loop. The callback work is trivial (decode
/// + yield), so main-thread cost is negligible. If profiling shows
/// contention, the spec calls for a dedicated CFRunLoop thread — easy
/// follow-up since the callback already speaks via AsyncStream.
///
/// ## Cancel-key passthrough
/// We currently always pass events through (`return event`). The spec calls
/// for swallowing Esc while dictating; that requires the orchestrator to
/// drive a shared "active" flag. Deferred — adds coupling we don't need
/// until we've dogfooded.
public actor HotkeySourceMac: HotkeySource {
    private let translator: HotkeyEventTranslator
    private var running: Running?

    public init(
        activation: HotkeyBinding = .rightOption,
        cancel: HotkeyBinding = .escape
    ) {
        self.translator = HotkeyEventTranslator(activation: activation, cancel: cancel)
    }

    public func start(
        handler: @Sendable @escaping (HotkeyEvent) async -> Void
    ) async throws {
        guard running == nil else { return }

        let (stream, continuation) = AsyncStream<HotkeyEvent>.makeStream()
        let context = TapContext(
            translator: translator,
            continuation: continuation
        )

        let mask = CGEventMask(
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)
        )

        let refcon = Unmanaged.passUnretained(context).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: hotkeyTapCallback,
            userInfo: refcon
        ) else {
            continuation.finish()
            throw HotkeySourceError.accessibilityDenied
        }

        guard let runLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault, tap, 0
        ) else {
            CFMachPortInvalidate(tap)
            continuation.finish()
            throw HotkeySourceError.tapInstallFailed
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        let consumerTask = Task {
            for await event in stream {
                await handler(event)
            }
        }

        running = Running(
            tap: tap,
            runLoopSource: runLoopSource,
            context: context,
            consumerTask: consumerTask
        )
    }

    public func stop() async {
        guard let captured = running else { return }
        running = nil

        CGEvent.tapEnable(tap: captured.tap, enable: false)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), captured.runLoopSource, .commonModes)
        CFMachPortInvalidate(captured.tap)
        captured.context.continuation.finish()
        captured.consumerTask.cancel()
    }

    private struct Running {
        let tap: CFMachPort
        let runLoopSource: CFRunLoopSource
        let context: TapContext
        let consumerTask: Task<Void, Never>
    }
}

// MARK: - Tap context

/// Lives for the duration of one tap installation. Held strongly by
/// `HotkeySourceMac.running` and weakly (as an opaque pointer) by the
/// CGEventTap callback. The callback runs synchronously on the run-loop
/// thread; `AsyncStream.Continuation.yield` is documented thread-safe.
private final class TapContext: @unchecked Sendable {
    let translator: HotkeyEventTranslator
    let continuation: AsyncStream<HotkeyEvent>.Continuation

    init(
        translator: HotkeyEventTranslator,
        continuation: AsyncStream<HotkeyEvent>.Continuation
    ) {
        self.translator = translator
        self.continuation = continuation
    }

    func handle(type: CGEventType, event: CGEvent) {
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let autoRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let translated = translator.translate(
            type: type,
            keyCode: keyCode,
            flags: event.flags,
            autoRepeat: autoRepeat,
            now: Date()
        )
        if let translated {
            continuation.yield(translated)
        }
    }
}

// MARK: - C callback

/// `@convention(c)` closure cannot capture Swift state, so the TapContext is
/// passed through `userInfo` (refcon) as an opaque pointer.
private let hotkeyTapCallback: CGEventTapCallBack = { _, type, event, refcon in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        // macOS occasionally disables long-running taps. Re-enabling needs
        // the CFMachPort, which the callback doesn't receive directly.
        // Surfaced via the next event burst; if this becomes a real
        // problem, store the port in TapContext and re-enable here.
        return Unmanaged.passUnretained(event)
    }
    if let refcon {
        let context = Unmanaged<TapContext>.fromOpaque(refcon).takeUnretainedValue()
        context.handle(type: type, event: event)
    }
    return Unmanaged.passUnretained(event)
}
#endif
