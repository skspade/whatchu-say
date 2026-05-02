import Foundation
import STTCore

public actor MeetingOrchestrator {
    public enum State: Sendable, Equatable {
        case idle
        case recording(UUID)
        case transcribing(UUID)
    }

    public typealias RecorderFactory = @Sendable (URL) -> any AudioRecorderProtocol

    private let library: any MeetingLibraryProtocol
    private let micRecorderFactory: RecorderFactory
    private let systemRecorderFactory: RecorderFactory
    private let transcriber: any BatchTranscriber
    private let mapper: any SpeakerNameMapper
    private var activeMicRecorder: (any AudioRecorderProtocol)?
    private var activeSystemRecorder: (any AudioRecorderProtocol)?
    public private(set) var state: State = .idle

    public init(
        library: any MeetingLibraryProtocol,
        micRecorderFactory: @escaping RecorderFactory,
        systemRecorderFactory: @escaping RecorderFactory,
        transcriber: any BatchTranscriber,
        mapper: any SpeakerNameMapper
    ) {
        self.library = library
        self.micRecorderFactory = micRecorderFactory
        self.systemRecorderFactory = systemRecorderFactory
        self.transcriber = transcriber
        self.mapper = mapper
    }

    public func start(attendees: AttendeeList, keepAudio: Bool) async throws -> UUID {
        guard case .idle = state else { throw MeetingError.alreadyRecording }
        let session = MeetingSession(
            id: UUID(),
            title: nil,
            startedAt: Date(),
            attendees: attendees,
            keepAudio: keepAudio
        )
        _ = try library.create(session: session)

        let micURL = try library.micFile(for: session.id)
        let systemURL = try library.systemFile(for: session.id)
        let mic = micRecorderFactory(micURL)
        let system = systemRecorderFactory(systemURL)

        do {
            try await mic.start()
            try await system.start()
        } catch {
            await mic.stop()
            await system.stop()
            try? library.delete(id: session.id)
            throw error
        }
        activeMicRecorder = mic
        activeSystemRecorder = system
        state = .recording(session.id)
        return session.id
    }

    public func stop() async throws {
        guard case .recording(let id) = state else { return }
        await activeMicRecorder?.stop()
        await activeSystemRecorder?.stop()
        activeMicRecorder = nil
        activeSystemRecorder = nil
        try await transcribe(id: id)
    }

    /// Resume transcription for a session left half-written by a crash. The
    /// session must already exist in the library; recorders are not started.
    /// Used by the launch-time recovery flow.
    public func recover(id: UUID) async throws {
        guard case .idle = state else { throw MeetingError.alreadyRecording }
        try await transcribe(id: id)
    }

    private func transcribe(id: UUID) async throws {
        var session = try library.load(id: id)
        if session.endedAt == nil {
            session.markStopped(at: Date())
        }
        try library.update(session: session)
        state = .transcribing(id)

        let micURL = try library.micFile(for: id)
        let systemURL = try library.systemFile(for: id)
        let pipeline = MeetingTranscriptionPipeline(transcriber: transcriber, mapper: mapper)

        do {
            let transcript = try await pipeline.run(
                micAudio: micURL,
                systemAudio: systemURL,
                attendees: session.attendees
            )
            try library.writeTranscript(transcript, for: id, title: session.title)
            session.markCompleted()
            try library.update(session: session)
            if !session.keepAudio {
                try? library.deleteAudio(for: id)
            }
            state = .idle
        } catch {
            session.markFailed(reason: String(describing: error))
            try? library.update(session: session)
            state = .idle
            throw error
        }
    }
}
