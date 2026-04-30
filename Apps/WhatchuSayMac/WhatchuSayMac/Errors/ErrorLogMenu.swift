import SwiftUI

/// Menu-bar surface for the error-log buffer. Renders a flat list of the
/// top-N entries inline plus an "Older…" submenu when overflow exists.
/// Clicking an entry copies its text to the clipboard so the user can
/// paste it into a bug report or scratchpad — same UX shape as
/// `RecentTranscriptsMenu`.
struct ErrorLogMenu: View {
    let entries: [ErrorLogEntry]
    let onCopy: (ErrorLogEntry) -> Void
    let onClear: () -> Void

    static let labelMaxLength = 80

    var body: some View {
        Section("Recent Errors") {
            if entries.isEmpty {
                Text("No recent errors")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Self.visibleEntries(from: entries)) { entry in
                    entryButton(entry)
                }
                let overflow = Self.overflowEntries(from: entries)
                if !overflow.isEmpty {
                    Menu("Older…") {
                        ForEach(overflow) { entry in
                            entryButton(entry)
                        }
                    }
                }
                Divider()
                Button("Clear Recent Errors", role: .destructive) {
                    onClear()
                }
            }
        }
    }

    private func entryButton(_ entry: ErrorLogEntry) -> some View {
        Button(Self.label(for: entry, maxLength: Self.labelMaxLength)) {
            onCopy(entry)
        }
        .help(entry.text)
    }

    // MARK: - Helpers (internal so unit tests can drive them)

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
