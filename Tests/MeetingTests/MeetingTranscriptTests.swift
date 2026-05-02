import Testing
@testable import Meeting

@Suite("MeetingTranscript")
struct MeetingTranscriptTests {
    let segments: [Segment] = [
        .init(start: 0, end: 1, speaker: .me, text: "Hi everyone."),
        .init(start: 1, end: 2, speaker: .anonymous(1), text: "Hi Sean."),
        .init(start: 2, end: 3, speaker: .anonymous(2), text: "Hello."),
    ]

    @Test("applies mapping to anonymous speakers")
    func applyMapping() {
        var t = MeetingTranscript(segments: segments)
        t.applySpeakerMapping([1: "Alice"])
        #expect(t.segments[0].speaker == .me)
        #expect(t.segments[1].speaker == .tagged("Alice"))
        #expect(t.segments[2].speaker == .anonymous(2))
    }

    @Test("manual rename overrides")
    func manualRename() {
        var t = MeetingTranscript(segments: segments)
        t.renameSpeaker(.anonymous(2), to: "Bob")
        #expect(t.segments[2].speaker == .tagged("Bob"))
    }

    @Test("renders markdown with [mm:ss] timestamps")
    func renderMarkdown() {
        let t = MeetingTranscript(segments: [
            .init(start: 65, end: 67, speaker: .me, text: "Hello."),
            .init(start: 70, end: 72, speaker: .tagged("Alice"), text: "Hi."),
        ])
        let md = t.renderMarkdown(title: "Test meeting")
        #expect(md.contains("# Test meeting"))
        #expect(md.contains("[01:05] **Me:** Hello."))
        #expect(md.contains("[01:10] **Alice:** Hi."))
    }
}
