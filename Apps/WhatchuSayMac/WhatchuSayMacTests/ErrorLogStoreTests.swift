import Testing
import Foundation
@testable import WhatchuSayMac

@Suite("ErrorLogStore: in-memory behavior")
@MainActor
struct ErrorLogStoreInMemoryTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("whatchu-say-error-test-\(UUID().uuidString).json")
    }

    @Test("record inserts at the front (newest first)")
    func recordInsertsAtFront() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ErrorLogStore(fileURL: url, maxCount: 10)

        store.record(text: "first")
        store.record(text: "second")
        store.record(text: "third")

        #expect(store.entries.map(\.text) == ["third", "second", "first"])
    }

    @Test("record of empty text is a no-op")
    func recordEmptyIsNoOp() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ErrorLogStore(fileURL: url, maxCount: 10)

        store.record(text: "")

        #expect(store.entries.isEmpty)
    }

    @Test("identical errors recorded twice in a row are kept (no dedup)")
    func recordDuplicateKeepsBoth() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ErrorLogStore(fileURL: url, maxCount: 10)

        store.record(text: "connection lost")
        store.record(text: "connection lost")

        #expect(store.entries.count == 2)
        #expect(store.entries.map(\.text) == ["connection lost", "connection lost"])
        // Distinct IDs so SwiftUI ForEach doesn't collapse them.
        #expect(store.entries[0].id != store.entries[1].id)
    }

    @Test("record past maxCount evicts the oldest entry")
    func recordEvictsOldest() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ErrorLogStore(fileURL: url, maxCount: 3)

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
        let store = ErrorLogStore(fileURL: url, maxCount: 10)

        store.record(text: "one")
        store.record(text: "two")
        store.clear()

        #expect(store.entries.isEmpty)
    }
}

@Suite("ErrorLogStore: persistence")
@MainActor
struct ErrorLogStorePersistenceTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("whatchu-say-error-test-\(UUID().uuidString).json")
    }

    @Test("load on missing file returns an empty buffer without throwing")
    func loadMissingFile() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonexistent-\(UUID().uuidString).json")
        let store = ErrorLogStore(fileURL: url, maxCount: 10)

        await store.load()

        #expect(store.entries.isEmpty)
    }

    @Test("load on corrupt JSON returns an empty buffer without throwing")
    func loadCorruptJSON() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try "{ this is not valid json".write(to: url, atomically: true, encoding: .utf8)

        let store = ErrorLogStore(fileURL: url, maxCount: 10)
        await store.load()

        #expect(store.entries.isEmpty)
    }

    @Test("flushPendingWrites + load round-trips entries newest-first")
    func roundTrip() async {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = ErrorLogStore(fileURL: url, maxCount: 10)
        writer.record(text: "a")
        writer.record(text: "b")
        writer.record(text: "c")
        writer.flushPendingWrites()

        let reader = ErrorLogStore(fileURL: url, maxCount: 10)
        await reader.load()

        #expect(reader.entries.map(\.text) == ["c", "b", "a"])
    }

    @Test("load truncates a too-large on-disk file to maxCount")
    func loadTruncatesOversizedFile() async {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = ErrorLogStore(fileURL: url, maxCount: 100)
        for i in 1...5 { writer.record(text: "err\(i)") }
        writer.flushPendingWrites()

        let reader = ErrorLogStore(fileURL: url, maxCount: 3)
        await reader.load()

        #expect(reader.entries.count == 3)
        #expect(reader.entries.map(\.text) == ["err5", "err4", "err3"])
    }

    @Test("clear + flush persists an empty buffer to disk")
    func clearPersistsEmpty() async {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = ErrorLogStore(fileURL: url, maxCount: 10)
        writer.record(text: "one")
        writer.record(text: "two")
        writer.flushPendingWrites()
        writer.clear()
        writer.flushPendingWrites()

        let reader = ErrorLogStore(fileURL: url, maxCount: 10)
        await reader.load()
        #expect(reader.entries.isEmpty)
    }

    @Test("save creates the parent directory if missing")
    func saveCreatesDirectory() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("whatchu-say-error-nested-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("error-log.json")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ErrorLogStore(fileURL: url, maxCount: 10)
        store.record(text: "boom")
        store.flushPendingWrites()

        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
