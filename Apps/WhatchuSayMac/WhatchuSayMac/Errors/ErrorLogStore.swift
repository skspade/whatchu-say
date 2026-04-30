import Foundation
import Observation

/// In-memory ring of recent runtime errors, persisted to a JSON file under
/// Application Support. Drives the menu-bar "Recent Errors" surface so the
/// user can scroll back when chasing a flaky failure.
///
/// MainActor-bound so SwiftUI views can read `entries` without hopping
/// actors. Disk I/O hops to background tasks via `Task.detached`.
///
/// Behavior — mirrors `RecentTranscriptsStore` deliberately so the future
/// settings UI and (eventually) the SQLite-backed history store can share
/// patterns:
/// - `record(text:)` inserts at the front. **No dedup**: identical errors
///   recorded twice in a row are kept as separate entries — frequency is
///   itself useful information when debugging ("this happened 5 times").
/// - Capacity enforced at insert time (`maxCount`) and on load.
/// - Saves are debounced ~250 ms.
/// - `flushPendingWrites()` is synchronous for `applicationWillTerminate`.
@MainActor
@Observable
final class ErrorLogStore {
    private(set) var entries: [ErrorLogEntry] = []

    private let fileURL: URL
    private let maxCount: Int
    private var pendingSaveTask: Task<Void, Never>?

    private static let schemaVersion: Int = 1
    private static let saveDebounce: Duration = .milliseconds(250)

    init(
        fileURL: URL = .errorLogDefault,
        maxCount: Int = ErrorLogConfig.maxCount
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

    /// Insert `text` at the front. Empty input is rejected so callers don't
    /// have to filter.
    func record(text: String) {
        guard !text.isEmpty else { return }
        entries.insert(ErrorLogEntry(text: text), at: 0)
        if entries.count > maxCount {
            entries.removeLast(entries.count - maxCount)
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

    private nonisolated static func loadFromDisk(url: URL, maxCount: Int) -> [ErrorLogEntry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let envelope = try decoder.decode(PersistedErrorLog.self, from: data)
            return Array(envelope.entries.prefix(maxCount))
        } catch {
            print("[ErrorLogStore] decode failed at \(url.path): \(error). Treating as empty.")
            return []
        }
    }

    private nonisolated static func saveToDisk(entries: [ErrorLogEntry], url: URL) {
        let envelope = PersistedErrorLog(
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
            print("[ErrorLogStore] save failed at \(url.path): \(error)")
        }
    }
}

private struct PersistedErrorLog: Codable {
    let schemaVersion: Int
    let entries: [ErrorLogEntry]
}
