import Foundation

/// Pure presentation helpers for the menu-bar "Recent Transcripts" surface.
///
/// Exposes the truncation rule and the visible-vs-overflow split so the
/// AppKit menu builder (`StatusItemController`) and unit tests can call
/// them without instantiating any UI. Clicking an entry copies its text to
/// the clipboard so the user can paste it manually with `Cmd+V` — see §3.2
/// of `docs/PLAN_RECENT_TRANSCRIPTS.md` for why we don't auto-inject.
enum RecentTranscriptsMenu {
    static let labelMaxLength = 60

    static func label(for text: String, maxLength: Int) -> String {
        if text.count <= maxLength { return text }
        return String(text.prefix(maxLength)) + "…"
    }

    static func visibleEntries(from entries: [TranscriptEntry]) -> [TranscriptEntry] {
        Array(entries.prefix(RecentTranscriptsConfig.topLevelDisplayCount))
    }

    static func overflowEntries(from entries: [TranscriptEntry]) -> [TranscriptEntry] {
        Array(entries.dropFirst(RecentTranscriptsConfig.topLevelDisplayCount))
    }
}
