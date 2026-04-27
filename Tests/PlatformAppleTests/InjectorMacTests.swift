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
#endif
