import Testing
import Foundation
@testable import WhatchuSayMac

@Suite("RecentTranscriptsStore: in-memory behavior")
@MainActor
struct RecentTranscriptsStoreInMemoryTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("whatchu-say-test-\(UUID().uuidString).json")
    }

    @Test("record inserts at the front (newest first)")
    func recordInsertsAtFront() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = RecentTranscriptsStore(fileURL: url, maxCount: 5)

        store.record(text: "first")
        store.record(text: "second")
        store.record(text: "third")

        #expect(store.entries.map(\.text) == ["third", "second", "first"])
    }

    @Test("record of empty text is a no-op")
    func recordEmptyIsNoOp() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = RecentTranscriptsStore(fileURL: url, maxCount: 5)

        store.record(text: "")

        #expect(store.entries.isEmpty)
    }

    @Test("record of duplicate-of-most-recent bumps timestamp without growing")
    func recordDuplicateBumpsTimestamp() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = RecentTranscriptsStore(fileURL: url, maxCount: 5)

        store.record(text: "hello")
        let firstId = store.entries[0].id
        let firstTimestamp = store.entries[0].timestamp

        try await Task.sleep(for: .milliseconds(10))
        store.record(text: "hello")

        #expect(store.entries.count == 1)
        #expect(store.entries[0].id == firstId)
        #expect(store.entries[0].timestamp > firstTimestamp)
    }

    @Test("record of text matching an older (not-most-recent) entry inserts a new entry")
    func recordOfOlderTextDoesNotDedup() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = RecentTranscriptsStore(fileURL: url, maxCount: 5)

        store.record(text: "a")
        store.record(text: "b")
        store.record(text: "a")

        // Order-of-use is preserved; the older "a" is not collapsed away.
        #expect(store.entries.map(\.text) == ["a", "b", "a"])
    }

    @Test("record past maxCount evicts the oldest entry")
    func recordEvictsOldest() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = RecentTranscriptsStore(fileURL: url, maxCount: 3)

        store.record(text: "a")
        store.record(text: "b")
        store.record(text: "c")
        store.record(text: "d")

        #expect(store.entries.count == 3)
        #expect(store.entries.map(\.text) == ["d", "c", "b"])
    }

    @Test("clear empties the buffer in memory")
    func clearEmptiesMemory() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = RecentTranscriptsStore(fileURL: url, maxCount: 5)

        store.record(text: "one")
        store.record(text: "two")
        store.clear()

        #expect(store.entries.isEmpty)
    }
}

@Suite("RecentTranscriptsStore: persistence")
@MainActor
struct RecentTranscriptsStorePersistenceTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("whatchu-say-test-\(UUID().uuidString).json")
    }

    @Test("load on missing file returns an empty buffer without throwing")
    func loadMissingFile() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonexistent-\(UUID().uuidString).json")
        let store = RecentTranscriptsStore(fileURL: url, maxCount: 5)

        await store.load()

        #expect(store.entries.isEmpty)
    }

    @Test("load on corrupt JSON returns an empty buffer without throwing")
    func loadCorruptJSON() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try "{ this is not valid json".write(to: url, atomically: true, encoding: .utf8)

        let store = RecentTranscriptsStore(fileURL: url, maxCount: 5)
        await store.load()

        #expect(store.entries.isEmpty)
    }

    @Test("flushPendingWrites + load round-trips entries newest-first")
    func roundTrip() async {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = RecentTranscriptsStore(fileURL: url, maxCount: 5)
        writer.record(text: "a")
        writer.record(text: "b")
        writer.record(text: "c")
        writer.flushPendingWrites()

        let reader = RecentTranscriptsStore(fileURL: url, maxCount: 5)
        await reader.load()

        #expect(reader.entries.map(\.text) == ["c", "b", "a"])
    }

    @Test("load truncates a too-large on-disk file to maxCount")
    func loadTruncatesOversizedFile() async {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        // Write 5 entries through a writer with a generous cap.
        let writer = RecentTranscriptsStore(fileURL: url, maxCount: 100)
        writer.record(text: "1")
        writer.record(text: "2")
        writer.record(text: "3")
        writer.record(text: "4")
        writer.record(text: "5")
        writer.flushPendingWrites()

        // Reader has a tighter cap; load should trim.
        let reader = RecentTranscriptsStore(fileURL: url, maxCount: 3)
        await reader.load()

        #expect(reader.entries.count == 3)
        #expect(reader.entries.map(\.text) == ["5", "4", "3"])
    }

    @Test("clear + flush persists an empty buffer to disk")
    func clearPersistsEmpty() async {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = RecentTranscriptsStore(fileURL: url, maxCount: 5)
        writer.record(text: "one")
        writer.record(text: "two")
        writer.flushPendingWrites()

        writer.clear()
        writer.flushPendingWrites()

        let reader = RecentTranscriptsStore(fileURL: url, maxCount: 5)
        await reader.load()
        #expect(reader.entries.isEmpty)
    }

    @Test("save creates the parent directory if missing")
    func saveCreatesDirectory() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("whatchu-say-nested-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("recent-transcripts.json")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = RecentTranscriptsStore(fileURL: url, maxCount: 5)
        store.record(text: "hello")
        store.flushPendingWrites()

        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
