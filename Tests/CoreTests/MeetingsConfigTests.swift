import Testing
import Foundation
@testable import Core

@Suite("MeetingsConfig")
struct MeetingsConfigTests {
    @Test("defaults are spec-aligned")
    func defaults() {
        let m = MeetingsConfig()
        #expect(m.showAttendeeFieldAtStart == true)
        #expect(m.showConsentReminder == true)
        #expect(m.deleteAudioAfterTranscription == true)
    }

    @Test("AppConfig encodes meetings field")
    func roundtrip() throws {
        let original = AppConfig()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded.meetings == original.meetings)
    }
}
