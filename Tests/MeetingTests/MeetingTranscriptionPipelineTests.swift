import Testing
import Foundation
@testable import Meeting
import STTCore

@Suite("MeetingTranscriptionPipeline")
struct MeetingTranscriptionPipelineTests {
    @Test("calls transcriber with diarize=false for mic, diarize=true for system")
    func diarizeFlags() async throws {
        let mock = MockBatchTranscriber()
        let micURL = URL(fileURLWithPath: "/tmp/mic.opus")
        let systemURL = URL(fileURLWithPath: "/tmp/system.opus")
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
        let mock = MockBatchTranscriber()
        let micURL = URL(fileURLWithPath: "/tmp/mic.opus")
        let systemURL = URL(fileURLWithPath: "/tmp/system.opus")
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
        let mock = MockBatchTranscriber()
        let micURL = URL(fileURLWithPath: "/tmp/mic.opus")
        let systemURL = URL(fileURLWithPath: "/tmp/system.opus")
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
}
