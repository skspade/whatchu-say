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
        try Data().write(to: micURL)
        try Data().write(to: systemURL)
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
        try Data().write(to: micURL)
        try Data().write(to: systemURL)
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
        try Data().write(to: micURL)
        try Data().write(to: systemURL)
        await #expect(throws: Error.self) {
            try await orch.stop()
        }
        #expect(FileManager.default.fileExists(atPath: micURL.path))
        let session = try lib.load(id: id)
        if case .failed = session.status {} else {
            Issue.record("expected .failed status, got \(session.status)")
        }
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
        try Data().write(to: micURL)
        try Data().write(to: systemURL)
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

    @Test("start while another start is awaiting recorders throws alreadyRecording")
    func concurrentStart() async throws {
        let (lib, root) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let mic = MockAudioRecorder()
        let system = MockAudioRecorder()
        await mic.blockStart()
        let orch = MeetingOrchestrator(
            library: lib,
            micRecorderFactory: { _ in mic },
            systemRecorderFactory: { _ in system },
            transcriber: MockBatchTranscriber(),
            mapper: ContentBasedSpeakerNameMapper()
        )

        let first = Task {
            try await orch.start(attendees: AttendeeList(names: []), keepAudio: false)
        }
        await waitForStartBlocked(mic)
        #expect(await orch.state == .starting)
        await #expect(throws: MeetingError.alreadyRecording) {
            _ = try await orch.start(attendees: AttendeeList(names: []), keepAudio: false)
        }

        await mic.releaseStart()
        let id = try await first.value
        #expect(await orch.state == .recording(id))
        #expect(await mic.startCount == 1)
        #expect(await system.startCount == 1)
        let sessions = try lib.listAll()
        #expect(sessions.map(\.id) == [id])
    }

    @Test("stop while another stop is awaiting recorders is a no-op")
    func concurrentStop() async throws {
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
        try Data().write(to: micURL)
        try Data().write(to: systemURL)
        await mock.setResponse(.init(segments: []), for: micURL)
        await mock.setResponse(.init(segments: []), for: systemURL)

        await mic.blockStop()
        let first = Task { try await orch.stop() }
        await waitForStopBlocked(mic)
        #expect(await orch.state == .stopping(id))
        try await orch.stop()

        await mic.releaseStop()
        try await first.value
        // One pipeline run transcribes each track once.
        #expect(await mock.callCount == 2)
        #expect(await mic.stopCount == 1)
        #expect(await system.stopCount == 1)
        #expect(await orch.state == .idle)
        let session = try lib.load(id: id)
        #expect(session.status == .completed)
    }

    @Test("library failure before transcription returns to idle")
    func libraryFailureResetsState() async throws {
        let (lib, root) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let orch = MeetingOrchestrator(
            library: lib,
            micRecorderFactory: { _ in MockAudioRecorder() },
            systemRecorderFactory: { _ in MockAudioRecorder() },
            transcriber: MockBatchTranscriber(),
            mapper: ContentBasedSpeakerNameMapper()
        )
        let id = try await orch.start(attendees: AttendeeList(names: []), keepAudio: false)
        // Losing meta.json makes `library.load` throw at the top of
        // transcription, before the pipeline's own error handling.
        let metaURL = try lib.directory(for: id).appendingPathComponent("meta.json")
        try FileManager.default.removeItem(at: metaURL)
        await #expect(throws: Error.self) {
            try await orch.stop()
        }
        #expect(await orch.state == .idle)

        await #expect(throws: Error.self) {
            try await orch.recover(id: UUID())
        }
        #expect(await orch.state == .idle)

        let next = try await orch.start(attendees: AttendeeList(names: []), keepAudio: false)
        #expect(next != id)
        #expect(await orch.state == .recording(next))
    }

    @Test("recorder start failure returns to idle")
    func startFailureResetsState() async throws {
        let (lib, root) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let mic = MockAudioRecorder()
        await mic.setStartError(MeetingError.micPermissionDenied)
        let orch = MeetingOrchestrator(
            library: lib,
            micRecorderFactory: { _ in mic },
            systemRecorderFactory: { _ in MockAudioRecorder() },
            transcriber: MockBatchTranscriber(),
            mapper: ContentBasedSpeakerNameMapper()
        )
        await #expect(throws: MeetingError.micPermissionDenied) {
            _ = try await orch.start(attendees: AttendeeList(names: []), keepAudio: false)
        }
        #expect(await orch.state == .idle)
        let sessions = try lib.listAll()
        #expect(sessions.isEmpty)

        await mic.setStartError(nil)
        let id = try await orch.start(attendees: AttendeeList(names: []), keepAudio: false)
        #expect(await orch.state == .recording(id))
    }

    private func waitForStartBlocked(_ recorder: MockAudioRecorder) async {
        for _ in 0..<2_000 {
            if await recorder.isStartBlocked { return }
            await Task.yield()
        }
    }

    private func waitForStopBlocked(_ recorder: MockAudioRecorder) async {
        for _ in 0..<2_000 {
            if await recorder.isStopBlocked { return }
            await Task.yield()
        }
    }
}
