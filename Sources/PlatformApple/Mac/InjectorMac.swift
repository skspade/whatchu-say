#if os(macOS)
import Foundation
import AppKit
@preconcurrency import CoreGraphics
import Core
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
///   `restoreDelay`, which must outlast the target app's (asynchronous)
///   handling of Cmd+V — restore too early and the app pastes the *old*
///   clipboard. The restore is skipped if anything else has written to the
///   pasteboard since, and a paste that lands before the previous restore
///   ran carries the user's original clipboard forward instead of
///   snapshotting the previous transcript. While a restore is pending the
///   transcript is marked transient so clipboard managers skip it.
///
/// All AppKit work happens on the main actor; CoreGraphics calls (which
/// are thread-safe) run on this actor.
public actor InjectorMac: Injector {
    /// What to put back once the latest paste has landed.
    private struct PasteRecord: Sendable {
        /// Clipboard contents from before the paste.
        let original: ClipboardSnapshot
        /// `NSPasteboard.changeCount` right after the transcript was written.
        let changeCount: Int
    }

    private let selector: StrategySelector
    private let restoreClipboard: Bool
    private let restoreDelay: Duration
    private let typeInterval: Duration
    private var pendingRestore: Task<Void, Never>?
    private var lastPaste: PasteRecord?
    private let pasteCommand: @Sendable () throws -> Void

    public init(
        selector: StrategySelector = StrategySelector(),
        restoreClipboard: Bool = true,
        restoreDelay: Duration = .milliseconds(500),
        typeInterval: Duration = .milliseconds(1),
        pasteCommand: (@Sendable () throws -> Void)? = nil
    ) {
        self.selector = selector
        self.restoreClipboard = restoreClipboard
        self.restoreDelay = restoreDelay
        self.typeInterval = typeInterval
        self.pasteCommand = pasteCommand ?? Self.postCmdV
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
        let carried = lastPaste
        lastPaste = nil

        let command = pasteCommand
        let transient = restoreClipboard
        let record = try await MainActor.run {
            // If the pasteboard still holds our previous transcript (its
            // restore hadn't run yet), the clipboard to restore is the one
            // from before that paste, not the transcript.
            let original: ClipboardSnapshot
            if let carried, NSPasteboard.general.changeCount == carried.changeCount {
                original = carried.original
            } else {
                original = ClipboardSnapshot.capture()
            }
            let changeCount = ClipboardSnapshot.write(text, transient: transient)
            try command()
            return PasteRecord(original: original, changeCount: changeCount)
        }

        guard restoreClipboard else { return }
        lastPaste = record
        let delay = restoreDelay
        pendingRestore = Task {
            try? await Task.sleep(for: delay)
            if Task.isCancelled { return }
            await record.original.restoreToGeneralPasteboard(ifChangeCountIs: record.changeCount)
        }
    }

    private nonisolated static func postCmdV() throws {
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

    /// nspasteboard.org marker telling clipboard managers the entry is
    /// short-lived and shouldn't be recorded.
    static let transientTypeRawValue = "org.nspasteboard.TransientType"

    /// Replace the pasteboard contents with `text` and return the resulting
    /// `changeCount`, so a later restore can tell whether anyone else has
    /// written since. `transient` adds the clipboard-manager marker.
    @MainActor
    static func write(_ text: String, transient: Bool) -> Int {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        if transient {
            pb.setData(Data(), forType: NSPasteboard.PasteboardType(rawValue: transientTypeRawValue))
        }
        return pb.changeCount
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

    /// Restore only if the pasteboard hasn't changed since `changeCount` —
    /// if the user (or another app) copied something meanwhile, keep it.
    @MainActor
    func restoreToGeneralPasteboard(ifChangeCountIs changeCount: Int) {
        guard NSPasteboard.general.changeCount == changeCount else { return }
        restoreToGeneralPasteboard()
    }
}
#endif
