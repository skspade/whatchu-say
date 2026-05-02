import Foundation
import STTCore

public struct MeetingTranscriptionPipeline: Sendable {
    private let transcriber: any BatchTranscriber
    private let mapper: any SpeakerNameMapper

    public init(transcriber: any BatchTranscriber, mapper: any SpeakerNameMapper) {
        self.transcriber = transcriber
        self.mapper = mapper
    }

    public func run(
        micAudio: URL,
        systemAudio: URL,
        attendees: AttendeeList,
        languageHint: String? = nil
    ) async throws -> MeetingTranscript {
        async let micResult = transcriber.transcribe(audioFileURL: micAudio, diarize: false, languageHint: languageHint)
        async let systemResult = transcriber.transcribe(audioFileURL: systemAudio, diarize: true, languageHint: languageHint)
        let (mic, system) = try await (micResult, systemResult)

        let micSegments = mic.segments.map {
            Segment(start: $0.start, end: $0.end, speaker: .me, text: $0.text)
        }
        let systemSegments = system.segments.map { seg in
            Segment(
                start: seg.start,
                end: seg.end,
                speaker: seg.speakerId.map(Speaker.anonymous) ?? .anonymous(0),
                text: seg.text
            )
        }

        let merged = TranscriptMerger.merge(mic: micSegments, system: systemSegments)
        var transcript = MeetingTranscript(segments: merged)
        let mapping = try await mapper.map(transcript: transcript, attendees: attendees)
        transcript.applySpeakerMapping(mapping)
        return transcript
    }
}
