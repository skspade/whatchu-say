import Testing
import Foundation
@testable import WhatchuSayMac

@Suite("RecentTranscriptsMenu: label truncation")
struct RecentTranscriptsMenuLabelTests {
    @Test("text shorter than maxLength is returned unchanged")
    func shortTextUnchanged() {
        let result = RecentTranscriptsMenu.label(for: "hello world", maxLength: 60)
        #expect(result == "hello world")
    }

    @Test("text equal to maxLength is returned unchanged")
    func exactLengthUnchanged() {
        let text = String(repeating: "a", count: 60)
        let result = RecentTranscriptsMenu.label(for: text, maxLength: 60)
        #expect(result == text)
    }

    @Test("text longer than maxLength is truncated with ellipsis suffix")
    func longTextTruncatedWithEllipsis() {
        let text = String(repeating: "a", count: 100)
        let result = RecentTranscriptsMenu.label(for: text, maxLength: 60)
        #expect(result == String(repeating: "a", count: 60) + "…")
        #expect(result.count == 61) // 60 chars + 1 ellipsis
    }

    @Test("preserves opening words (front-truncation, not end-truncation)")
    func preservesOpeningWords() {
        let text = "Once upon a time in a land far far away there was a transcript that went on and on"
        let result = RecentTranscriptsMenu.label(for: text, maxLength: 30)
        #expect(result.hasPrefix("Once upon a time"))
        #expect(result.hasSuffix("…"))
    }
}

@Suite("RecentTranscriptsMenu: visible / overflow split")
struct RecentTranscriptsMenuSplitTests {
    private func entries(_ count: Int) -> [TranscriptEntry] {
        (0..<count).map { TranscriptEntry(text: "entry \($0)") }
    }

    @Test("empty input yields empty visible and empty overflow")
    func emptyInput() {
        let result = entries(0)
        #expect(RecentTranscriptsMenu.visibleEntries(from: result).isEmpty)
        #expect(RecentTranscriptsMenu.overflowEntries(from: result).isEmpty)
    }

    @Test("entries fitting in topLevelDisplayCount yield empty overflow")
    func fitsWithoutOverflow() {
        let cap = RecentTranscriptsConfig.topLevelDisplayCount
        let input = entries(cap)
        #expect(RecentTranscriptsMenu.visibleEntries(from: input).count == cap)
        #expect(RecentTranscriptsMenu.overflowEntries(from: input).isEmpty)
    }

    @Test("entries exceeding topLevelDisplayCount split correctly")
    func exceedsAndSplits() {
        let cap = RecentTranscriptsConfig.topLevelDisplayCount
        let input = entries(cap + 3)
        let visible = RecentTranscriptsMenu.visibleEntries(from: input)
        let overflow = RecentTranscriptsMenu.overflowEntries(from: input)
        #expect(visible.count == cap)
        #expect(overflow.count == 3)
        // No overlap; visible+overflow reconstructs the original list.
        #expect(visible + overflow == input)
    }

    @Test("under-cap input yields all entries visible and none overflow")
    func underCap() {
        let input = entries(2)
        let visible = RecentTranscriptsMenu.visibleEntries(from: input)
        #expect(visible.count == 2)
        #expect(RecentTranscriptsMenu.overflowEntries(from: input).isEmpty)
    }
}
