import Foundation
import Observation

/// In-memory ring of the user's most recent dictation transcripts, persisted
/// to a JSON file under Application Support. Drives the menu-bar "Recent
/// Transcripts" surface so the user can re-paste a transcript when the
/// original injection landed in the wrong field.
///
/// MainActor-bound so SwiftUI views can read `entries` without hopping
/// actors. Disk I/O hops to background tasks via `Task.detached`.
///
/// Behavior:
/// - `record(text:)` inserts at the front; same-text-as-most-recent bumps
///   the timestamp on the existing entry instead of duplicating.
/// - Capacity enforced at insert time (`maxCount`) and on load (in case the
///   on-disk file was edited or we lowered the cap).
/// - Saves are debounced ~250 ms so dedup-then-insert bursts coalesce.
/// - `flushPendingWrites()` is synchronous for use from
///   `applicationWillTerminate`.
@MainActor
@Observable
final class RecentTranscriptsStore {
    private(set) var entries: [TranscriptEntry] = []

    private let fileURL: URL
    private let maxCount: Int
    private var pendingSaveTask: Task<Void, Never>?

    private static let schemaVersion: Int = 1
    private static let saveDebounce: Duration = .milliseconds(250)

    init(
        fileURL: URL = .recentTranscriptsDefault,
        maxCount: Int = RecentTranscriptsConfig.maxCount
    ) {
        self.fileURL = fileURL
        self.maxCount = maxCount
    }

    /// Hydrate from disk. Missing or corrupt file → empty buffer; never
    /// throws. Idempotent — calling twice is fine.
    func load() async {
        let url = fileURL
        let max = maxCount
        let loaded = await Task.detached(priority: .userInitiated) {
            Self.loadFromDisk(url: url, maxCount: max)
        }.value
        entries = loaded
    }

    /// Insert `text` at the front. If the most-recent entry has the same
    /// text, bump its timestamp in place instead of inserting a duplicate
    /// (preserves the entry's UUID so SwiftUI `ForEach` doesn't churn).
    /// Empty input is rejected — this matches the live-injection contract
    /// and keeps callers from having to filter.
    func record(text: String) {
        guard !text.isEmpty else { return }

        if let first = entries.first, first.text == text {
            entries[0] = TranscriptEntry(id: first.id, text: text, timestamp: Date())
        } else {
            entries.insert(TranscriptEntry(text: text), at: 0)
            if entries.count > maxCount {
                entries.removeLast(entries.count - maxCount)
            }
        }
        scheduleSave()
    }

    /// Wipe memory and disk.
    func clear() {
        entries = []
        scheduleSave()
    }

    /// Cancel any pending debounced save and write the current state to
    /// disk synchronously. For `applicationWillTerminate` and tests where a
    /// deterministic on-disk state is required.
    func flushPendingWrites() {
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        Self.saveToDisk(entries: entries, url: fileURL)
    }

    // MARK: - Save scheduling

    private func scheduleSave() {
        pendingSaveTask?.cancel()
        let url = fileURL
        pendingSaveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDebounce)
            guard !Task.isCancelled, let self else { return }
            let snapshot = self.entries
            await Task.detached(priority: .utility) {
                Self.saveToDisk(entries: snapshot, url: url)
            }.value
        }
    }

    // MARK: - Disk I/O (nonisolated; called from background tasks or sync flush)

    private nonisolated static func loadFromDisk(url: URL, maxCount: Int) -> [TranscriptEntry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let envelope = try decoder.decode(PersistedRecentTranscripts.self, from: data)
            return Array(envelope.entries.prefix(maxCount))
        } catch {
            print("[RecentTranscriptsStore] decode failed at \(url.path): \(error). Treating as empty.")
            return []
        }
    }

    private nonisolated static func saveToDisk(entries: [TranscriptEntry], url: URL) {
        let envelope = PersistedRecentTranscripts(
            schemaVersion: schemaVersion,
            entries: entries
        )
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(envelope)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: [.atomic])
        } catch {
            print("[RecentTranscriptsStore] save failed at \(url.path): \(error)")
        }
    }
}

private struct PersistedRecentTranscripts: Codable {
    let schemaVersion: Int
    let entries: [TranscriptEntry]
}
