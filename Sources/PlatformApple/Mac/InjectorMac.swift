#if os(macOS)
import Foundation
import AppKit
@preconcurrency import CoreGraphics
import Injector

public enum InjectorMacError: Error, Sendable, Equatable {
    case eventSourceUnavailable
    case eventCreationFailed
}

/// macOS text injector. Two strategies, picked by `StrategySelector`:
///
/// - **type** — synthesise per-character keyboard events with
///   `CGEventKeyboardSetUnicodeString`. Used for short ASCII text where
///   clipboard pollution is undesirable (≤ 8 chars, no newlines/tabs,
///   non-Terminal app).
/// - **paste** — set `NSPasteboard.general` and post `Cmd+V`. The
///   previous clipboard contents are captured and restored after
///   `restoreDelay`. Concurrent injects cancel any pending restore so
///   user state doesn't get clobbered out of order.
///
/// All AppKit work happens on the main actor; CoreGraphics calls (which
/// are thread-safe) run on this actor.
public actor InjectorMac: Injector {
    private let selector: StrategySelector
    private let restoreClipboard: Bool
    private let restoreDelay: Duration
    private let typeInterval: Duration
    private var pendingRestore: Task<Void, Never>?

    public init(
        selector: StrategySelector = StrategySelector(),
        restoreClipboard: Bool = true,
        restoreDelay: Duration = .milliseconds(100),
        typeInterval: Duration = .milliseconds(1)
    ) {
        self.selector = selector
        self.restoreClipboard = restoreClipboard
        self.restoreDelay = restoreDelay
        self.typeInterval = typeInterval
    }

    public func inject(text: String, hint: InjectionHint) async throws {
        if text.isEmpty { return }

        let bundleID = await Self.frontmostBundleID()
        let strategy = resolveStrategy(text: text, hint: hint, bundleID: bundleID)

        switch strategy {
        case .type:
            try await typeText(text)
        case .paste, .auto:
            try await pasteText(text)
        }
    }

    private func resolveStrategy(
        text: String,
        hint: InjectionHint,
        bundleID: String?
    ) -> InjectionStrategy {
        switch hint {
        case .forceType:
            return .type
        case .forcePaste:
            return .paste
        case .auto:
            let resolved = selector.resolve(text: text, frontmostBundleID: bundleID)
            // Selector can theoretically return .auto via a per-app override;
            // treat as paste rather than recursing.
            return resolved == .auto ? .paste : resolved
        }
    }

    @MainActor
    private static func frontmostBundleID() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    // MARK: - Type strategy

    private func typeText(_ text: String) async throws {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw InjectorMacError.eventSourceUnavailable
        }
        for character in text {
            try Self.typeCharacter(character, source: source)
            try? await Task.sleep(for: typeInterval)
        }
    }

    private static func typeCharacter(
        _ character: Character,
        source: CGEventSource
    ) throws {
        let utf16: [UniChar] = Array(String(character).utf16)
        guard
            let downEvent = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
            let upEvent = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        else {
            throw InjectorMacError.eventCreationFailed
        }
        utf16.withUnsafeBufferPointer { buffer in
            downEvent.keyboardSetUnicodeString(
                stringLength: utf16.count,
                unicodeString: buffer.baseAddress
            )
            upEvent.keyboardSetUnicodeString(
                stringLength: utf16.count,
                unicodeString: buffer.baseAddress
            )
        }
        downEvent.post(tap: .cghidEventTap)
        upEvent.post(tap: .cghidEventTap)
    }

    // MARK: - Paste strategy

    private func pasteText(_ text: String) async throws {
        pendingRestore?.cancel()
        pendingRestore = nil

        let snapshot = await ClipboardSnapshot.replace(with: text)
        try sendCmdV()

        guard restoreClipboard else { return }
        let delay = restoreDelay
        pendingRestore = Task {
            try? await Task.sleep(for: delay)
            if Task.isCancelled { return }
            await snapshot.restoreToGeneralPasteboard()
        }
    }

    private func sendCmdV() throws {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw InjectorMacError.eventSourceUnavailable
        }
        let vKey: CGKeyCode = 9 // 'V'
        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        else {
            throw InjectorMacError.eventCreationFailed
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}

// MARK: - ClipboardSnapshot

/// Best-effort snapshot of `NSPasteboard.general`. Captures every type
/// currently advertised on the pasteboard along with its raw `Data`. Multi-
/// item structure is collapsed into a single restored item — adequate for
/// the dictation use case (replace + restore-after-delay), and cheaper than
/// reconstructing `NSPasteboardItem` instances.
struct ClipboardSnapshot: Sendable {
    struct Entry: Sendable {
        let typeRawValue: String
        let data: Data
    }
    let entries: [Entry]

    @MainActor
    static func capture() -> ClipboardSnapshot {
        let pb = NSPasteboard.general
        var entries: [Entry] = []
        for type in pb.types ?? [] {
            if let data = pb.data(forType: type) {
                entries.append(Entry(typeRawValue: type.rawValue, data: data))
            }
        }
        return ClipboardSnapshot(entries: entries)
    }

    /// Capture the current pasteboard, then replace its contents with `text`.
    /// The snapshot can later be passed to `restoreToGeneralPasteboard()` to
    /// undo the replacement.
    @MainActor
    static func replace(with text: String) -> ClipboardSnapshot {
        let pb = NSPasteboard.general
        let snapshot = capture()
        pb.clearContents()
        pb.setString(text, forType: .string)
        return snapshot
    }

    @MainActor
    func restoreToGeneralPasteboard() {
        let pb = NSPasteboard.general
        pb.clearContents()
        for entry in entries {
            let type = NSPasteboard.PasteboardType(rawValue: entry.typeRawValue)
            pb.setData(entry.data, forType: type)
        }
    }
}
#endif
