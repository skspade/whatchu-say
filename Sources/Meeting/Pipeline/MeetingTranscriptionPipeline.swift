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
        let micEmpty = Self.isEmpty(micAudio)
        let systemEmpty = Self.isEmpty(systemAudio)
        // Nothing was captured — fail loudly instead of uploading empty files
        // and surfacing a confusing HTTP error from the transcription service.
        if micEmpty && systemEmpty { throw MeetingError.emptyRecording }

        async let micResult = transcribeIfNonEmpty(micAudio, isEmpty: micEmpty, diarize: false, languageHint: languageHint)
        async let systemResult = transcribeIfNonEmpty(systemAudio, isEmpty: systemEmpty, diarize: true, languageHint: languageHint)
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

    /// Transcribe a track, or return an empty result for an empty track so we
    /// don't waste an API call (and error) on a file with no audio.
    private func transcribeIfNonEmpty(
        _ url: URL,
        isEmpty: Bool,
        diarize: Bool,
        languageHint: String?
    ) async throws -> BatchTranscriptionResult {
        if isEmpty { return BatchTranscriptionResult(segments: []) }
        return try await transcriber.transcribe(audioFileURL: url, diarize: diarize, languageHint: languageHint)
    }

    private static func isEmpty(_ url: URL) -> Bool {
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int else {
            return true
        }
        return size == 0
    }
}
