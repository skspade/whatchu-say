import Testing
import Foundation
@testable import Meeting

@Suite("MeetingSession")
struct MeetingSessionTests {
    @Test("init sets required fields, status starts at .recording")
    func initFields() {
        let id = UUID()
        let started = Date()
        let s = MeetingSession(
            id: id,
            title: "Test",
            startedAt: started,
            attendees: AttendeeList(names: ["Alice"]),
            keepAudio: false
        )
        #expect(s.id == id)
        #expect(s.title == "Test")
        #expect(s.startedAt == started)
        #expect(s.attendees.names == ["Alice"])
        #expect(s.keepAudio == false)
        #expect(s.status == .recording)
        #expect(s.endedAt == nil)
    }

    @Test("default title uses ISO date when not provided")
    func defaultTitle() {
        let s = MeetingSession(id: UUID(), title: nil, startedAt: Date(timeIntervalSince1970: 0), attendees: AttendeeList(names: []), keepAudio: false)
        #expect(s.title.contains("Meeting —"))
    }

    @Test("status transitions")
    func transitions() {
        var s = MeetingSession(id: UUID(), title: "x", startedAt: Date(), attendees: AttendeeList(names: []), keepAudio: false)
        s.markStopped(at: Date(timeIntervalSince1970: 100))
        #expect(s.status == .transcribing)
        #expect(s.endedAt == Date(timeIntervalSince1970: 100))
        s.markCompleted()
        #expect(s.status == .completed)
        s.markFailed(reason: "boom")
        #expect(s.status == .failed("boom"))
    }
}
