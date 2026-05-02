import Testing
@testable import Meeting

@Suite("ContentBasedSpeakerNameMapper")
struct SpeakerNameMapperTests {
    @Test("returns empty map when no attendees")
    func noAttendees() async throws {
        let mapper = ContentBasedSpeakerNameMapper()
        let result = try await mapper.map(
            transcript: MeetingTranscript(segments: [.init(start:0,end:1,speaker:.anonymous(0),text:"hi")]),
            attendees: AttendeeList(names: [])
        )
        #expect(result.isEmpty)
    }

    @Test("matches self-introduction 'I'm <Name>' to the speaking speaker")
    func selfIntro() async throws {
        let mapper = ContentBasedSpeakerNameMapper()
        let result = try await mapper.map(
            transcript: MeetingTranscript(segments: [
                .init(start: 0, end: 1, speaker: .anonymous(0), text: "Hey, I'm Alice."),
                .init(start: 1, end: 2, speaker: .anonymous(1), text: "Nice to meet you."),
            ]),
            attendees: AttendeeList(names: ["Alice", "Bob"])
        )
        #expect(result == [0: "Alice"])
    }

    @Test("does not map names not in attendee list")
    func unknownName() async throws {
        let mapper = ContentBasedSpeakerNameMapper()
        let result = try await mapper.map(
            transcript: MeetingTranscript(segments: [
                .init(start: 0, end: 1, speaker: .anonymous(0), text: "I'm Charlie."),
            ]),
            attendees: AttendeeList(names: ["Alice", "Bob"])
        )
        #expect(result.isEmpty)
    }

    @Test("does not map .me or .tagged segments")
    func skipsNonAnonymous() async throws {
        let mapper = ContentBasedSpeakerNameMapper()
        let result = try await mapper.map(
            transcript: MeetingTranscript(segments: [
                .init(start: 0, end: 1, speaker: .me, text: "I'm Alice."),
            ]),
            attendees: AttendeeList(names: ["Alice"])
        )
        #expect(result.isEmpty)
    }
}
