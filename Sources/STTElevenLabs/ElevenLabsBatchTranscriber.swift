import Foundation
import STTCore

public struct ElevenLabsBatchTranscriber: BatchTranscriber {
    private let apiKey: String
    private let urlSession: URLSession
    private let modelId: String
    private let noVerbatim: Bool

    public init(
        apiKey: String,
        urlSession: URLSession = .shared,
        modelId: String = "scribe_v2",
        noVerbatim: Bool = false
    ) {
        self.apiKey = apiKey
        self.urlSession = urlSession
        self.modelId = modelId
        self.noVerbatim = noVerbatim
    }

    public func transcribe(
        audioFileURL: URL,
        diarize: Bool,
        languageHint: String?
    ) async throws -> BatchTranscriptionResult {
        let boundary = "----wcs-\(UUID().uuidString)"
        var request = URLRequest(url: Endpoints.batchSpeechToText)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func appendField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append(value.data(using: .utf8)!)
            body.append("\r\n".data(using: .utf8)!)
        }
        appendField("model_id", modelId)
        appendField("diarize", diarize ? "true" : "false")
        // `parse` builds segments from the per-word timings; ask for them
        // explicitly rather than relying on the API default.
        appendField("timestamps_granularity", "word")
        if let lang = languageHint {
            appendField("language_code", lang)
        }
        if noVerbatim {
            appendField("no_verbatim", "true")
        }

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(audioFileURL.lastPathComponent)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/ogg\r\n\r\n".data(using: .utf8)!)
        body.append(try Data(contentsOf: audioFileURL))
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw BatchTranscriptionError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? -1, data)
        }

        return try Self.parse(data)
    }

    /// A silence longer than this between two words from the same speaker
    /// starts a new segment. Without diarization every word shares a nil
    /// speaker, so this is what keeps the mic stream from collapsing into one
    /// segment that the meeting merger can't interleave with the other side.
    static let maxPauseWithinSegment: TimeInterval = 1.5

    /// Scribe returns a flat `words` list (`word`, `spacing` and
    /// `audio_event` entries, each with a `speaker_id` when diarization is
    /// on). Consecutive words from the same speaker are grouped into one
    /// segment; `spacing` entries only join text, and `audio_event` tags like
    /// "(laughter)" are dropped so they don't leak into transcript text or
    /// split a speaker's turn.
    static func parse(_ data: Data) throws -> BatchTranscriptionResult {
        struct Wire: Decodable {
            struct Word: Decodable {
                let text: String
                let start: TimeInterval?
                let end: TimeInterval?
                let type: String?
                let speakerId: String?

                enum CodingKeys: String, CodingKey {
                    case text, start, end, type
                    case speakerId = "speaker_id"
                }
            }
            let text: String?
            let words: [Word]?
            let audioDurationSecs: TimeInterval?

            enum CodingKeys: String, CodingKey {
                case text, words
                case audioDurationSecs = "audio_duration_secs"
            }
        }
        let wire = try JSONDecoder().decode(Wire.self, from: data)

        guard let words = wire.words, !words.isEmpty else {
            let text = (wire.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return BatchTranscriptionResult(segments: []) }
            return BatchTranscriptionResult(segments: [
                BatchSegment(start: 0, end: wire.audioDurationSecs ?? 0, speakerId: nil, text: text),
            ])
        }

        var segments: [BatchSegment] = []
        var pending: PendingSegment?
        for word in words {
            switch word.type ?? "word" {
            case "spacing":
                // Skip spacing that would double up, e.g. on both sides of a
                // dropped audio event.
                if pending?.text.last?.isWhitespace == false {
                    pending?.text += word.text
                }
            case "audio_event":
                continue
            default:
                let start = word.start ?? pending?.end ?? 0
                let end = word.end ?? start
                if var run = pending,
                   run.speakerLabel == word.speakerId,
                   start - run.end <= maxPauseWithinSegment {
                    run.text += word.text
                    run.end = end
                    pending = run
                } else {
                    if let segment = pending?.segment { segments.append(segment) }
                    pending = PendingSegment(speakerLabel: word.speakerId, start: start, end: end, text: word.text)
                }
            }
        }
        if let segment = pending?.segment { segments.append(segment) }
        return BatchTranscriptionResult(segments: segments)
    }

    /// Scribe labels diarized speakers `speaker_0`, `speaker_1`, …. Anything
    /// else (no diarization, role labels like `agent`) maps to nil.
    static func speakerNumber(from label: String?) -> Int? {
        guard let label, label.hasPrefix("speaker_") else { return nil }
        return Int(label.dropFirst("speaker_".count))
    }
}

/// A segment being accumulated while walking Scribe's `words` list.
private struct PendingSegment {
    let speakerLabel: String?
    let start: TimeInterval
    var end: TimeInterval
    var text: String

    /// The finished segment, or nil if it only ever held whitespace.
    var segment: BatchSegment? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return BatchSegment(
            start: start,
            end: end,
            speakerId: ElevenLabsBatchTranscriber.speakerNumber(from: speakerLabel),
            text: trimmed
        )
    }
}

public enum BatchTranscriptionError: Error, Equatable {
    case httpStatus(Int, Data)
}
