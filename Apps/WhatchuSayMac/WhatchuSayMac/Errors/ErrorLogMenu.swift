import Foundation

/// Pure presentation helpers for the menu-bar "Recent Errors" surface.
///
/// Exposes the truncation/labelling rule and the visible-vs-overflow split
/// so the AppKit menu builder (`StatusItemController`) and unit tests can
/// call them without instantiating any UI. Same UX shape as
/// `RecentTranscriptsMenu`; clicking an entry copies its text to the
/// clipboard for pasting into a bug report or scratchpad.
enum ErrorLogMenu {
    static let labelMaxLength = 80

    /// Format an entry as `HH:mm  text…` for the menu row, truncated to
    /// `maxLength` characters total. The timestamp prefix gives chronology
    /// at a glance — when chasing a flaky issue the time you saw it
    /// matters, not just the message.
    static func label(for entry: ErrorLogEntry, maxLength: Int) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let prefix = formatter.string(from: entry.timestamp) + "  "
        let budget = max(0, maxLength - prefix.count)
        if entry.text.count <= budget { return prefix + entry.text }
        return prefix + String(entry.text.prefix(budget)) + "…"
    }

    static func visibleEntries(from entries: [ErrorLogEntry]) -> [ErrorLogEntry] {
        Array(entries.prefix(ErrorLogConfig.topLevelDisplayCount))
    }

    static func overflowEntries(from entries: [ErrorLogEntry]) -> [ErrorLogEntry] {
        Array(entries.dropFirst(ErrorLogConfig.topLevelDisplayCount))
    }
}
