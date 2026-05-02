import Foundation

/// Optional capability for STT providers that support file-based batch
/// transcription with diarization. Distinct from the realtime `SttSession`
/// path; batch is "POST a finished audio file, get a JSON transcript back".
public protocol BatchTranscriber: Sendable {
    func transcribe(
        audioFileURL: URL,
        diarize: Bool,
        languageHint: String?
    ) async throws -> BatchTranscriptionResult
}

public struct BatchTranscriptionResult: Sendable, Equatable, Codable {
    public let segments: [BatchSegment]
    public init(segments: [BatchSegment]) { self.segments = segments }
}

/// One segment from a batch provider response. `speakerId` is the
/// provider-assigned diarization label (typically 0, 1, 2, …) — not yet
/// mapped to a name. `nil` if diarization was disabled.
public struct BatchSegment: Sendable, Equatable, Codable {
    public let start: TimeInterval
    public let end: TimeInterval
    public let speakerId: Int?
    public let text: String

    public init(start: TimeInterval, end: TimeInterval, speakerId: Int?, text: String) {
        self.start = start
        self.end = end
        self.speakerId = speakerId
        self.text = text
    }
}
