import Testing
import Foundation
@testable import Meeting

@Suite("MeetingLibrary")
struct MeetingLibraryTests {
    func makeTempLibrary() throws -> (MeetingLibrary, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (MeetingLibrary(rootDirectory: root), root)
    }

    @Test("creates session directory on save")
    func saveCreatesDir() throws {
        let (lib, root) = try makeTempLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = MeetingSession(id: UUID(), title: "x", startedAt: Date(), attendees: AttendeeList(names: ["Alice"]), keepAudio: false)
        let dir = try lib.create(session: session)
        #expect(FileManager.default.fileExists(atPath: dir.path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("meta.json").path))
    }

    @Test("round-trips meta.json")
    func roundtripMeta() throws {
        let (lib, root) = try makeTempLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = MeetingSession(id: UUID(), title: "x", startedAt: Date(timeIntervalSince1970: 1000), attendees: AttendeeList(names: ["A","B"]), keepAudio: true)
        _ = try lib.create(session: original)
        let loaded = try lib.load(id: original.id)
        #expect(loaded.id == original.id)
        #expect(loaded.attendees.names == ["A","B"])
        #expect(loaded.keepAudio == true)
    }

    @Test("writeTranscript persists transcript.json + transcript.md")
    func writeTranscript() throws {
        let (lib, root) = try makeTempLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let s = MeetingSession(id: UUID(), title: "x", startedAt: Date(), attendees: AttendeeList(names: []), keepAudio: false)
        _ = try lib.create(session: s)
        let t = MeetingTranscript(segments: [.init(start: 0, end: 1, speaker: .me, text: "hi")])
        try lib.writeTranscript(t, for: s.id, title: "Test")
        let dir = try lib.directory(for: s.id)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("transcript.json").path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("transcript.md").path))
    }

    @Test("deleteAudio removes mic.opus and system.opus only")
    func deleteAudio() throws {
        let (lib, root) = try makeTempLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let s = MeetingSession(id: UUID(), title: "x", startedAt: Date(), attendees: AttendeeList(names: []), keepAudio: false)
        let dir = try lib.create(session: s)
        try Data().write(to: dir.appendingPathComponent("mic.opus"))
        try Data().write(to: dir.appendingPathComponent("system.opus"))
        try Data().write(to: dir.appendingPathComponent("meta.json"))
        try lib.deleteAudio(for: s.id)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("mic.opus").path))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("system.opus").path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("meta.json").path))
    }
}
