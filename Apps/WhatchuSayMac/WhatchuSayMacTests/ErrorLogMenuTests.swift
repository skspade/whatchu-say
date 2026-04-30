import Testing
import Foundation
@testable import WhatchuSayMac

@Suite("ErrorLogMenu: pure helpers")
@MainActor
struct ErrorLogMenuTests {
    private let fixedDate = Date(timeIntervalSinceReferenceDate: 0)

    @Test("label includes a HH:mm prefix and the full text when under budget")
    func labelShortText() {
        let entry = ErrorLogEntry(text: "boom", timestamp: fixedDate)
        let label = ErrorLogMenu.label(for: entry, maxLength: 80)
        // The exact formatted hour depends on locale; assert structure.
        #expect(label.contains("boom"))
        #expect(label.count >= "00:00  boom".count)
        #expect(!label.hasSuffix("…"))
    }

    @Test("label truncates with ellipsis when text plus prefix exceeds the budget")
    func labelLongText() {
        let longText = String(repeating: "x", count: 200)
        let entry = ErrorLogEntry(text: longText, timestamp: fixedDate)
        let label = ErrorLogMenu.label(for: entry, maxLength: 30)
        #expect(label.hasSuffix("…"))
        #expect(label.count <= 31) // budget + "…"
    }

    @Test("visibleEntries returns at most topLevelDisplayCount")
    func visibleEntriesCap() {
        let entries = (0..<10).map { ErrorLogEntry(text: "e\($0)") }
        let visible = ErrorLogMenu.visibleEntries(from: entries)
        #expect(visible.count == ErrorLogConfig.topLevelDisplayCount)
        #expect(visible.first?.text == "e0")
    }

    @Test("overflowEntries returns everything past topLevelDisplayCount")
    func overflowEntries() {
        let entries = (0..<10).map { ErrorLogEntry(text: "e\($0)") }
        let overflow = ErrorLogMenu.overflowEntries(from: entries)
        #expect(overflow.count == 10 - ErrorLogConfig.topLevelDisplayCount)
        #expect(overflow.first?.text == "e\(ErrorLogConfig.topLevelDisplayCount)")
    }

    @Test("visibleEntries on a buffer smaller than the cap returns the whole buffer")
    func visibleEntriesUndersized() {
        let entries = [ErrorLogEntry(text: "only")]
        let visible = ErrorLogMenu.visibleEntries(from: entries)
        #expect(visible.map(\.text) == ["only"])
    }

    @Test("overflowEntries on a buffer smaller than the cap is empty")
    func overflowEmptyForSmallBuffer() {
        let entries = [ErrorLogEntry(text: "only")]
        let overflow = ErrorLogMenu.overflowEntries(from: entries)
        #expect(overflow.isEmpty)
    }
}
