import Testing
import Foundation
@testable import Meeting
import STTCore

@Suite("MeetingOrchestrator")
struct MeetingOrchestratorTests {
    func makeLibrary() throws -> (MeetingLibrary, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("orch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (MeetingLibrary(rootDirectory: root), root)
    }

    @Test("start creates session, calls both recorders' start")
    func startBoth() async throws {
        let (lib, root) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let mic = MockAudioRecorder()
        let system = MockAudioRecorder()
        let mock = MockBatchTranscriber()

        let orch = MeetingOrchestrator(
            library: lib,
            micRecorderFactory: { _ in mic },
            systemRecorderFactory: { _ in system },
            transcriber: mock,
            mapper: ContentBasedSpeakerNameMapper()
        )
        let id = try await orch.start(attendees: AttendeeList(names: ["Alice"]), keepAudio: false)
        #expect(await mic.didStart)
        #expect(await system.didStart)
        let session = try lib.load(id: id)
        #expect(session.status == .recording)
    }

    @Test("stop produces a transcript, marks session completed")
    func stopAndTranscribe() async throws {
        let (lib, root) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let mic = MockAudioRecorder()
        let system = MockAudioRecorder()
        let mock = MockBatchTranscriber()

        let orch = MeetingOrchestrator(
            library: lib,
            micRecorderFactory: { _ in mic },
            systemRecorderFactory: { _ in system },
            transcriber: mock,
            mapper: ContentBasedSpeakerNameMapper()
        )
        let id = try await orch.start(attendees: AttendeeList(names: []), keepAudio: false)
        let micURL = try lib.micFile(for: id)
        let systemURL = try lib.systemFile(for: id)
        try Data([0x01]).write(to: micURL)
        try Data([0x01]).write(to: systemURL)
        await mock.setResponse(.init(segments: []), for: micURL)
        await mock.setResponse(.init(segments: [
            .init(start: 0, end: 1, speakerId: 0, text: "hi"),
        ]), for: systemURL)

        try await orch.stop()
        let session = try lib.load(id: id)
        #expect(session.status == .completed)
        #expect(await mic.didStop)
        #expect(await system.didStop)
    }

    @Test("audio is deleted after successful transcription when keepAudio=false")
    func deleteAudioOnSuccess() async throws {
        let (lib, root) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let mock = MockBatchTranscriber()
        let orch = MeetingOrchestrator(
            library: lib,
            micRecorderFactory: { _ in MockAudioRecorder() },
            systemRecorderFactory: { _ in MockAudioRecorder() },
            transcriber: mock,
            mapper: ContentBasedSpeakerNameMapper()
        )
        let id = try await orch.start(attendees: AttendeeList(names: []), keepAudio: false)
        let micURL = try lib.micFile(for: id)
        let systemURL = try lib.systemFile(for: id)
        try Data([0x01]).write(to: micURL)
        try Data([0x01]).write(to: systemURL)
        await mock.setResponse(.init(segments: []), for: micURL)
        await mock.setResponse(.init(segments: []), for: systemURL)
        try await orch.stop()
        #expect(!FileManager.default.fileExists(atPath: micURL.path))
        #expect(!FileManager.default.fileExists(atPath: systemURL.path))
    }

    @Test("audio is retained when transcription fails")
    func retainAudioOnFailure() async throws {
        let (lib, root) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let mock = MockBatchTranscriber()
        let orch = MeetingOrchestrator(
            library: lib,
            micRecorderFactory: { _ in MockAudioRecorder() },
            systemRecorderFactory: { _ in MockAudioRecorder() },
            transcriber: mock,
            mapper: ContentBasedSpeakerNameMapper()
        )
        let id = try await orch.start(attendees: AttendeeList(names: []), keepAudio: false)
        let micURL = try lib.micFile(for: id)
        let systemURL = try lib.systemFile(for: id)
        try Data([0x01]).write(to: micURL)
        try Data([0x01]).write(to: systemURL)
        await #expect(throws: Error.self) {
            try await orch.stop()
        }
        #expect(FileManager.default.fileExists(atPath: micURL.path))
        let session = try lib.load(id: id)
        if case .failed = session.status {} else {
            Issue.record("expected .failed status, got \(session.status)")
        }
    }

    @Test("stop marks session failed when nothing was recorded")
    func failsOnEmptyRecording() async throws {
        let (lib, root) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let mock = MockBatchTranscriber()
        let orch = MeetingOrchestrator(
            library: lib,
            micRecorderFactory: { _ in MockAudioRecorder() },
            systemRecorderFactory: { _ in MockAudioRecorder() },
            transcriber: mock,
            mapper: ContentBasedSpeakerNameMapper()
        )
        // Mock recorders never write audio, so both tracks are empty.
        let id = try await orch.start(attendees: AttendeeList(names: []), keepAudio: false)
        await #expect(throws: MeetingError.emptyRecording) {
            try await orch.stop()
        }
        let session = try lib.load(id: id)
        if case .failed = session.status {} else {
            Issue.record("expected .failed status, got \(session.status)")
        }
        #expect(await mock.callCount == 0)
    }

    @Test("recover transcribes a half-written session")
    func recover() async throws {
        let (lib, root) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let mock = MockBatchTranscriber()

        let session = MeetingSession(id: UUID(), title: "x", startedAt: Date(), attendees: AttendeeList(names: []), keepAudio: false)
        _ = try lib.create(session: session)
        let micURL = try lib.micFile(for: session.id)
        let systemURL = try lib.systemFile(for: session.id)
        try Data([0x01]).write(to: micURL)
        try Data([0x01]).write(to: systemURL)
        await mock.setResponse(.init(segments: []), for: micURL)
        await mock.setResponse(.init(segments: [
            .init(start: 0, end: 1, speakerId: 0, text: "hi"),
        ]), for: systemURL)

        let orch = MeetingOrchestrator(
            library: lib,
            micRecorderFactory: { _ in MockAudioRecorder() },
            systemRecorderFactory: { _ in MockAudioRecorder() },
            transcriber: mock,
            mapper: ContentBasedSpeakerNameMapper()
        )
        try await orch.recover(id: session.id)
        let recovered = try lib.load(id: session.id)
        #expect(recovered.status == .completed)
        #expect(recovered.endedAt != nil)
    }

    @Test("findIncomplete returns sessions still recording or transcribing")
    func findIncomplete() throws {
        let (lib, root) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        let recording = MeetingSession(id: UUID(), title: "r", startedAt: Date(), attendees: AttendeeList(names: []), keepAudio: false)
        var done = MeetingSession(id: UUID(), title: "d", startedAt: Date(), attendees: AttendeeList(names: []), keepAudio: false)
        done.markStopped(at: Date())
        done.markCompleted()
        _ = try lib.create(session: recording)
        _ = try lib.create(session: done)
        try lib.update(session: done)

        let incomplete = try lib.findIncomplete()
        #expect(incomplete.count == 1)
        #expect(incomplete[0].id == recording.id)
    }

    @Test("alreadyRecording on double start")
    func doubleStart() async throws {
        let (lib, root) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let orch = MeetingOrchestrator(
            library: lib,
            micRecorderFactory: { _ in MockAudioRecorder() },
            systemRecorderFactory: { _ in MockAudioRecorder() },
            transcriber: MockBatchTranscriber(),
            mapper: ContentBasedSpeakerNameMapper()
        )
        _ = try await orch.start(attendees: AttendeeList(names: []), keepAudio: false)
        await #expect(throws: MeetingError.alreadyRecording) {
            _ = try await orch.start(attendees: AttendeeList(names: []), keepAudio: false)
        }
    }
}
