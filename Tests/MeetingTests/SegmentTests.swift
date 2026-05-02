import Testing
import Foundation
@testable import Meeting

@Suite("Speaker")
struct SpeakerTests {
    @Test("equality across cases")
    func equality() {
        #expect(Speaker.me == .me)
        #expect(Speaker.tagged("Alice") == .tagged("Alice"))
        #expect(Speaker.anonymous(1) == .anonymous(1))
        #expect(Speaker.tagged("Alice") != .tagged("Bob"))
        #expect(Speaker.anonymous(1) != .tagged("Alice"))
    }

    @Test("roundtrips through JSON")
    func codable() throws {
        let cases: [Speaker] = [.me, .tagged("Alice"), .anonymous(3)]
        for s in cases {
            let data = try JSONEncoder().encode(s)
            let decoded = try JSONDecoder().decode(Speaker.self, from: data)
            #expect(decoded == s)
        }
    }
}

@Suite("Segment")
struct SegmentTests {
    @Test("constructs with values")
    func construct() {
        let s = Segment(start: 1.0, end: 2.5, speaker: .me, text: "hello")
        #expect(s.start == 1.0)
        #expect(s.end == 2.5)
        #expect(s.speaker == .me)
        #expect(s.text == "hello")
    }

    @Test("duration")
    func duration() {
        let s = Segment(start: 1.0, end: 2.5, speaker: .me, text: "x")
        #expect(s.duration == 1.5)
    }
}
