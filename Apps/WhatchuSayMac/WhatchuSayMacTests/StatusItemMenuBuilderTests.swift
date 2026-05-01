import Testing
import AppKit
import Foundation
@testable import WhatchuSayMac

/// Drive `StatusItemController.makeMenuItems()` against every meaningful
/// `AppState` shape and inspect the resulting `[NSMenuItem]`. The
/// controller is constructed without `install()`, so no real status item
/// is created — the menu builder is pure with respect to AppKit's status
/// bar and is safe to exercise in unit tests.
@MainActor
@Suite("StatusItemController.makeMenuItems: structure per AppState")
struct StatusItemMenuBuilderTests {

    // MARK: - Fixtures

    private func makeController(
        status: AppState.Status = .idle,
        lastError: String? = nil,
        permissionIssue: PermissionDeepLink? = nil,
        transcripts: [TranscriptEntry] = [],
        errors: [ErrorLogEntry] = []
    ) -> StatusItemController {
        let state = AppState()
        state.status = status
        state.lastError = lastError
        state.permissionIssue = permissionIssue

        let recent = RecentTranscriptsStore()
        for entry in transcripts.reversed() {
            // record(text:) inserts at the front, so reverse to preserve order
            recent.record(text: entry.text)
        }
        let errorLog = ErrorLogStore()
        for entry in errors.reversed() {
            errorLog.record(text: entry.text)
        }

        return StatusItemController(
            state: state,
            recentTranscripts: recent,
            errorLog: errorLog,
            handlers: noopHandlers
        )
    }

    private var noopHandlers: StatusItemController.Handlers {
        StatusItemController.Handlers(
            onSetKey: {},
            onCopyTranscript: { _ in },
            onClearTranscripts: {},
            onCopyErrorEntry: { _ in },
            onClearErrorLog: {},
            onDismissError: {},
            onOpenPermission: { _ in },
            onOpenSettings: {}
        )
    }

    private func titles(of items: [NSMenuItem]) -> [String] {
        items.map { $0.isSeparatorItem ? "<sep>" : $0.title }
    }

    // MARK: - Always-present items

    @Test("idle, no error: status header + Update API Key + section headers + Quit")
    func idleEmptyHasBaseItems() {
        let controller = makeController()
        let items = controller.makeMenuItems()
        let allTitles = titles(of: items)
        #expect(allTitles.contains("Idle"))
        #expect(allTitles.contains("Update API Key…"))
        #expect(allTitles.contains("Recent Transcripts"))
        #expect(allTitles.contains("Recent Errors"))
        #expect(allTitles.contains("No recent transcripts"))
        #expect(allTitles.contains("No recent errors"))
        #expect(allTitles.contains("Quit"))
    }

    @Test("Quit item has ⌘Q key equivalent")
    func quitHasCommandQ() {
        let controller = makeController()
        let items = controller.makeMenuItems()
        let quit = items.first { $0.title == "Quit" }
        #expect(quit?.keyEquivalent == "q")
    }

    @Test("Settings… item is present, has ⌘, and sits directly above Quit")
    func settingsItemShape() {
        let controller = makeController()
        let items = controller.makeMenuItems()
        let allTitles = titles(of: items)
        #expect(allTitles.contains("Settings…"))

        let settings = items.first { $0.title == "Settings…" }
        #expect(settings?.keyEquivalent == ",")

        guard let settingsIndex = items.firstIndex(where: { $0.title == "Settings…" }),
              let quitIndex = items.firstIndex(where: { $0.title == "Quit" }) else {
            Issue.record("expected both Settings… and Quit items")
            return
        }
        #expect(quitIndex == settingsIndex + 1)
    }

    @Test("status header is disabled (non-clickable label)")
    func statusHeaderDisabled() {
        let controller = makeController()
        let items = controller.makeMenuItems()
        let header = items.first { $0.title == "Idle" }
        #expect(header?.isEnabled == false)
        #expect(header?.action == nil)
    }

    // MARK: - Status-driven Set/Update labelling

    @Test("needsSetup uses 'Set ElevenLabs API Key…' label")
    func needsSetupLabelling() {
        let controller = makeController(status: .needsSetup)
        let titles = titles(of: controller.makeMenuItems())
        #expect(titles.contains("Set ElevenLabs API Key…"))
        #expect(!titles.contains("Update API Key…"))
    }

    @Test("listening uses 'Update API Key…' label and 'Listening…' header")
    func listeningLabelling() {
        let controller = makeController(status: .listening)
        let titles = titles(of: controller.makeMenuItems())
        #expect(titles.contains("Listening…"))
        #expect(titles.contains("Update API Key…"))
    }

    @Test("startupFailed surfaces the failure message in the header")
    func startupFailedHeader() {
        let controller = makeController(status: .startupFailed("permission denied"))
        let titles = titles(of: controller.makeMenuItems())
        #expect(titles.contains("Startup failed: permission denied"))
    }

    // MARK: - Recent transcripts section

    @Test("transcripts under topLevelDisplayCount: all visible, no Older… submenu, Clear item present")
    func transcriptsUnderCap() {
        let entries = (0..<3).map { TranscriptEntry(text: "entry \($0)") }
        let controller = makeController(transcripts: entries)
        let items = controller.makeMenuItems()
        let allTitles = titles(of: items)
        for entry in entries {
            #expect(allTitles.contains(entry.text))
        }
        #expect(!allTitles.contains("Older…"))
        #expect(allTitles.contains("Clear Recent Transcripts"))
    }

    @Test("transcripts over topLevelDisplayCount: top-N visible + Older… submenu carries the remainder")
    func transcriptsOverCap() {
        let cap = RecentTranscriptsConfig.topLevelDisplayCount
        let entries = (0..<(cap + 3)).map { TranscriptEntry(text: "entry \($0)") }
        let controller = makeController(transcripts: entries)
        let items = controller.makeMenuItems()

        // The Recent Transcripts "Older…" parent is the first one.
        let older = items.first { $0.title == "Older…" }
        #expect(older?.submenu != nil)
        #expect(older?.submenu?.items.count == 3)

        let topLevelEntryTitles = titles(of: items).filter { $0.hasPrefix("entry ") }
        #expect(topLevelEntryTitles.count == cap)
    }

    @Test("transcripts: each entry item carries its TranscriptEntry as representedObject")
    func transcriptItemRepresentedObject() {
        let controller = makeController(transcripts: [TranscriptEntry(text: "hello world")])
        let item = controller.makeMenuItems().first { $0.title == "hello world" }
        let represented = item?.representedObject as? TranscriptEntry
        #expect(represented?.text == "hello world")
        #expect(item?.toolTip == "hello world")
    }

    // MARK: - Error log section

    @Test("errors under cap: visible + Clear item")
    func errorsUnderCap() {
        let entries = [
            ErrorLogEntry(text: "boom one"),
            ErrorLogEntry(text: "boom two")
        ]
        let controller = makeController(errors: entries)
        let titles = titles(of: controller.makeMenuItems())
        #expect(titles.contains("Clear Recent Errors"))
        #expect(!titles.contains("No recent errors"))
    }

    @Test("errors over cap: Older… submenu present")
    func errorsOverCap() {
        let cap = ErrorLogConfig.topLevelDisplayCount
        let entries = (0..<(cap + 2)).map { ErrorLogEntry(text: "boom \($0)") }
        let controller = makeController(errors: entries)
        let items = controller.makeMenuItems()
        // Two "Older…" titles can exist (transcripts + errors); since
        // transcripts is empty here, only the error one is present.
        let olders = items.filter { $0.title == "Older…" }
        #expect(olders.count == 1)
        #expect(olders.first?.submenu?.items.count == 2)
    }

    // MARK: - Error / permission affordances

    @Test("lastError nil: no error line, no Dismiss Error item")
    func noErrorLineWhenClean() {
        let controller = makeController()
        let titles = titles(of: controller.makeMenuItems())
        #expect(!titles.contains("Dismiss Error"))
        #expect(!titles.contains { $0.hasPrefix("Error: ") })
    }

    @Test("lastError set: shows 'Error: <text>' line and Dismiss Error item")
    func errorLineAndDismiss() {
        let controller = makeController(lastError: "connection lost")
        let titles = titles(of: controller.makeMenuItems())
        #expect(titles.contains("Error: connection lost"))
        #expect(titles.contains("Dismiss Error"))
    }

    @Test("lastError + permissionIssue: fix-it deep-link button appears between error line and dismiss")
    func errorWithPermissionShowsFixIt() {
        let controller = makeController(
            lastError: PermissionDeepLink.microphone.errorMessage,
            permissionIssue: .microphone
        )
        let titles = titles(of: controller.makeMenuItems())
        #expect(titles.contains(PermissionDeepLink.microphone.buttonLabel))

        // Order: error line → fix-it → Dismiss Error
        let errorIdx = titles.firstIndex { $0.hasPrefix("Error: ") }
        let fixItIdx = titles.firstIndex(of: PermissionDeepLink.microphone.buttonLabel)
        let dismissIdx = titles.firstIndex(of: "Dismiss Error")
        #expect(errorIdx != nil && fixItIdx != nil && dismissIdx != nil)
        if let e = errorIdx, let f = fixItIdx, let d = dismissIdx {
            #expect(e < f)
            #expect(f < d)
        }
    }

    @Test("permission fix-it item carries the PermissionDeepLink as representedObject")
    func permissionItemRepresentedObject() {
        let controller = makeController(
            lastError: PermissionDeepLink.accessibility.errorMessage,
            permissionIssue: .accessibility
        )
        let item = controller.makeMenuItems().first {
            $0.title == PermissionDeepLink.accessibility.buttonLabel
        }
        let link = item?.representedObject as? PermissionDeepLink
        #expect(link == .accessibility)
    }

    // MARK: - Menu structure: separators

    @Test("menu starts with header, separator, set-key, separator")
    func menuStartsWithHeaderBlock() {
        let controller = makeController()
        let items = controller.makeMenuItems()
        #expect(items.count >= 4)
        #expect(items[0].title == "Idle")
        #expect(items[1].isSeparatorItem)
        #expect(items[2].title == "Update API Key…")
        #expect(items[3].isSeparatorItem)
    }

    @Test("menu ends with separator + Settings… + Quit")
    func menuEndsWithQuit() {
        let controller = makeController()
        let items = controller.makeMenuItems()
        #expect(items.count >= 3)
        #expect(items[items.count - 1].title == "Quit")
        #expect(items[items.count - 2].title == "Settings…")
        #expect(items[items.count - 3].isSeparatorItem)
    }
}
