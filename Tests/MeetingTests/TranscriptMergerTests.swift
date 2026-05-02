import Testing
@testable import Meeting

@Suite("TranscriptMerger")
struct TranscriptMergerTests {
    @Test("interleaves by start time")
    func interleave() {
        let mic: [Segment] = [
            .init(start: 0.0, end: 1.0, speaker: .me, text: "hi"),
            .init(start: 5.0, end: 6.0, speaker: .me, text: "yes"),
        ]
        let system: [Segment] = [
            .init(start: 2.0, end: 3.0, speaker: .anonymous(1), text: "hello"),
            .init(start: 4.0, end: 4.5, speaker: .anonymous(2), text: "ok"),
        ]
        let merged = TranscriptMerger.merge(mic: mic, system: system)
        #expect(merged.map(\.start) == [0.0, 2.0, 4.0, 5.0])
        #expect(merged[0].speaker == .me)
        #expect(merged[1].speaker == .anonymous(1))
    }

    @Test("on tie at start, mic comes first")
    func tieFavorsMe() {
        let mic: [Segment] = [.init(start: 1.0, end: 2.0, speaker: .me, text: "a")]
        let system: [Segment] = [.init(start: 1.0, end: 2.0, speaker: .anonymous(1), text: "b")]
        let merged = TranscriptMerger.merge(mic: mic, system: system)
        #expect(merged.map(\.speaker) == [.me, .anonymous(1)])
    }

    @Test("empty inputs produce empty output")
    func empties() {
        #expect(TranscriptMerger.merge(mic: [], system: []) == [])
    }
}
