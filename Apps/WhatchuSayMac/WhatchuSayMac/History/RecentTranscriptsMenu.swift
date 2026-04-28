import SwiftUI

/// Menu-bar surface for the recent-transcripts buffer. Renders a flat list
/// of the top-N entries inline plus an "Older…" submenu when overflow
/// exists. Clicking an entry copies its text to the clipboard so the user
/// can paste it manually with `Cmd+V` — see §3.2 of
/// `docs/PLAN_RECENT_TRANSCRIPTS.md` for why we don't auto-inject.
struct RecentTranscriptsMenu: View {
    let entries: [TranscriptEntry]
    let onCopy: (TranscriptEntry) -> Void
    let onClear: () -> Void

    static let labelMaxLength = 60

    var body: some View {
        Section("Recent Transcripts") {
            if entries.isEmpty {
                Text("No recent transcripts")
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
                Button("Clear Recent Transcripts", role: .destructive) {
                    onClear()
                }
            }
        }
    }

    private func entryButton(_ entry: TranscriptEntry) -> some View {
        Button(Self.label(for: entry.text, maxLength: Self.labelMaxLength)) {
            onCopy(entry)
        }
        .help(entry.text)
    }

    // MARK: - Helpers (internal so we can unit-test them)

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
