#if os(macOS)
import Testing
import Foundation
import AppKit
@testable import PlatformApple
@testable import Injector

@Suite("ClipboardSnapshot round-trip")
@MainActor
struct ClipboardSnapshotTests {
    @Test("capture preserves the current string and restore puts it back")
    func captureAndRestoreString() async {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString("original", forType: .string)

        let snapshot = ClipboardSnapshot.capture()
        pb.clearContents()
        pb.setString("replacement", forType: .string)
        #expect(pb.string(forType: .string) == "replacement")

        snapshot.restoreToGeneralPasteboard()
        #expect(pb.string(forType: .string) == "original")
    }

    @Test("replace(with:) sets text and yields a snapshot of the prior state")
    func replaceCapturesPriorState() async {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString("before", forType: .string)

        let snapshot = ClipboardSnapshot.replace(with: "after")
        #expect(pb.string(forType: .string) == "after")

        snapshot.restoreToGeneralPasteboard()
        #expect(pb.string(forType: .string) == "before")
    }

    @Test("snapshot of an empty pasteboard restores to empty")
    func emptyPasteboardRoundTrip() async {
        let pb = NSPasteboard.general
        pb.clearContents()

        let snapshot = ClipboardSnapshot.capture()
        pb.setString("intrusion", forType: .string)
        snapshot.restoreToGeneralPasteboard()

        #expect(pb.string(forType: .string) == nil)
    }
}

@Suite("InjectorMac inject")
struct InjectorMacInjectTests {
    @Test("empty text is a no-op (no error, no event posted)")
    func emptyText() async throws {
        let injector = InjectorMac()
        try await injector.inject(text: "", hint: .auto)
    }

    @Test("strategy resolution defers to selector under .auto hint")
    func resolveAuto() async {
        let selector = StrategySelector(typeMaxChars: 8)
        // Don't actually inject — just verify the selector contract holds for
        // the inputs the injector will hand it.
        #expect(selector.resolve(text: "hi", frontmostBundleID: nil) == .type)
        #expect(selector.resolve(text: "this is much longer", frontmostBundleID: nil) == .paste)
        #expect(selector.resolve(text: "ok", frontmostBundleID: "com.apple.Terminal") == .paste)
    }
}

// MARK: - Paste timing tests

/// Records the clipboard state at the moment the paste command fires.
private final class PasteCommandSpy: @unchecked Sendable {
    private(set) var clipboardAtPasteTime: String?
    private(set) var callCount = 0

    func record() {
        clipboardAtPasteTime = NSPasteboard.general.string(forType: .string)
        callCount += 1
    }
}

@Suite("InjectorMac paste timing", .serialized)
struct InjectorMacPasteTimingTests {
    @Test("clipboard contains injected text at the moment paste command fires")
    func clipboardCorrectAtPasteTime() async throws {
        let spy = PasteCommandSpy()
        let injector = InjectorMac(
            restoreClipboard: false,
            pasteCommand: spy.record
        )

        await MainActor.run {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString("old content", forType: .string)
        }

        try await injector.inject(text: "new transcription", hint: .forcePaste)

        #expect(spy.callCount == 1)
        #expect(spy.clipboardAtPasteTime == "new transcription")
    }

    @Test("pending restore from previous paste does not clobber current paste")
    func restoreDoesNotClobberNextPaste() async throws {
        let spy = PasteCommandSpy()
        let injector = InjectorMac(
            restoreClipboard: true,
            restoreDelay: .zero,
            pasteCommand: spy.record
        )

        await MainActor.run {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString("original", forType: .string)
        }

        try await injector.inject(text: "first", hint: .forcePaste)

        // Let the zero-delay restore fire.
        try await Task.sleep(for: .milliseconds(50))

        try await injector.inject(text: "second", hint: .forcePaste)

        #expect(spy.callCount == 2)
        #expect(spy.clipboardAtPasteTime == "second")
    }

    @Test("clipboard is restored after restoreDelay when restoreClipboard is enabled")
    func clipboardRestoredAfterDelay() async throws {
        let spy = PasteCommandSpy()
        let injector = InjectorMac(
            restoreClipboard: true,
            restoreDelay: .milliseconds(50),
            pasteCommand: spy.record
        )

        await MainActor.run {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString("user clipboard", forType: .string)
        }

        try await injector.inject(text: "transcription", hint: .forcePaste)
        #expect(spy.clipboardAtPasteTime == "transcription")

        try await Task.sleep(for: .milliseconds(150))

        let restored = await MainActor.run {
            NSPasteboard.general.string(forType: .string)
        }
        #expect(restored == "user clipboard")
    }
}
#endif
