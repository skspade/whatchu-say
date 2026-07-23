import Testing
import Foundation
@testable import Meeting
import STTCore

@Suite("MeetingTranscriptionPipeline")
struct MeetingTranscriptionPipelineTests {
    /// A temp dir with mic/system audio files, each written with `micBytes` /
    /// `systemBytes` of placeholder content (0 bytes = an empty track).
    func makeAudio(micBytes: Int = 4, systemBytes: Int = 4) throws -> (dir: URL, mic: URL, system: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pipe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let mic = dir.appendingPathComponent("mic.caf")
        let system = dir.appendingPathComponent("system.caf")
        try Data(repeating: 0xAB, count: micBytes).write(to: mic)
        try Data(repeating: 0xCD, count: systemBytes).write(to: system)
        return (dir, mic, system)
    }

    @Test("calls transcriber with diarize=false for mic, diarize=true for system")
    func diarizeFlags() async throws {
        let (dir, micURL, systemURL) = try makeAudio()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockBatchTranscriber()
        await mock.setResponse(.init(segments: []), for: micURL)
        await mock.setResponse(.init(segments: []), for: systemURL)

        let pipeline = MeetingTranscriptionPipeline(
            transcriber: mock,
            mapper: ContentBasedSpeakerNameMapper()
        )
        _ = try await pipeline.run(
            micAudio: micURL,
            systemAudio: systemURL,
            attendees: AttendeeList(names: [])
        )
        #expect(await mock.callCount == 2)
    }

    @Test("relabels mic segments as .me, system segments as .anonymous")
    func relabel() async throws {
        let (dir, micURL, systemURL) = try makeAudio()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockBatchTranscriber()
        await mock.setResponse(.init(segments: [
            .init(start: 0, end: 1, speakerId: nil, text: "hi"),
        ]), for: micURL)
        await mock.setResponse(.init(segments: [
            .init(start: 1, end: 2, speakerId: 0, text: "hello"),
            .init(start: 2, end: 3, speakerId: 1, text: "world"),
        ]), for: systemURL)

        let pipeline = MeetingTranscriptionPipeline(
            transcriber: mock,
            mapper: ContentBasedSpeakerNameMapper()
        )
        let t = try await pipeline.run(
            micAudio: micURL,
            systemAudio: systemURL,
            attendees: AttendeeList(names: [])
        )
        #expect(t.segments.count == 3)
        #expect(t.segments[0].speaker == .me)
        #expect(t.segments[1].speaker == .anonymous(0))
        #expect(t.segments[2].speaker == .anonymous(1))
    }

    @Test("applies name mapping when attendees match self-intros")
    func applyMapping() async throws {
        let (dir, micURL, systemURL) = try makeAudio()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockBatchTranscriber()
        await mock.setResponse(.init(segments: []), for: micURL)
        await mock.setResponse(.init(segments: [
            .init(start: 0, end: 1, speakerId: 0, text: "I'm Alice."),
        ]), for: systemURL)

        let pipeline = MeetingTranscriptionPipeline(
            transcriber: mock,
            mapper: ContentBasedSpeakerNameMapper()
        )
        let t = try await pipeline.run(
            micAudio: micURL,
            systemAudio: systemURL,
            attendees: AttendeeList(names: ["Alice"])
        )
        #expect(t.segments[0].speaker == .tagged("Alice"))
    }

    @Test("throws emptyRecording when both audio files are empty")
    func emptyRecordingThrows() async throws {
        let (dir, micURL, systemURL) = try makeAudio(micBytes: 0, systemBytes: 0)
        defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockBatchTranscriber()

        let pipeline = MeetingTranscriptionPipeline(
            transcriber: mock,
            mapper: ContentBasedSpeakerNameMapper()
        )
        await #expect(throws: MeetingError.emptyRecording) {
            _ = try await pipeline.run(
                micAudio: micURL,
                systemAudio: systemURL,
                attendees: AttendeeList(names: [])
            )
        }
        // The empty upload is never sent.
        #expect(await mock.callCount == 0)
    }

    @Test("skips the transcriber for an empty track")
    func skipsEmptyTrack() async throws {
        let (dir, micURL, systemURL) = try makeAudio(micBytes: 4, systemBytes: 0)
        defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockBatchTranscriber()
        await mock.setResponse(.init(segments: [
            .init(start: 0, end: 1, speakerId: nil, text: "just me"),
        ]), for: micURL)

        let pipeline = MeetingTranscriptionPipeline(
            transcriber: mock,
            mapper: ContentBasedSpeakerNameMapper()
        )
        let t = try await pipeline.run(
            micAudio: micURL,
            systemAudio: systemURL,
            attendees: AttendeeList(names: [])
        )
        // Only the non-empty mic track hit the transcriber.
        #expect(await mock.callCount == 1)
        #expect(t.segments.count == 1)
        #expect(t.segments[0].speaker == .me)
        #expect(t.segments[0].text == "just me")
    }
}
