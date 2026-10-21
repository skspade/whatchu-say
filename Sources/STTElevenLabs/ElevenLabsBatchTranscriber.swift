import Foundation
import STTCore

public struct ElevenLabsBatchTranscriber: BatchTranscriber {
    private let apiKey: String
    private let urlSession: URLSession
    private let modelId: String
    private let noVerbatim: Bool
    private let requestTimeout: TimeInterval

    /// - Parameter requestTimeout: idle timeout for the upload. The endpoint
    ///   is synchronous and sends nothing back until transcription finishes,
    ///   which for a long meeting runs far past URLRequest's 60 s default
    ///   once the upload completes.
    public init(
        apiKey: String,
        urlSession: URLSession = .shared,
        modelId: String = "scribe_v2",
        noVerbatim: Bool = false,
        requestTimeout: TimeInterval = 30 * 60
    ) {
        self.apiKey = apiKey
        self.urlSession = urlSession
        self.modelId = modelId
        self.noVerbatim = noVerbatim
        self.requestTimeout = requestTimeout
    }

    public func transcribe(
        audioFileURL: URL,
        diarize: Bool,
        languageHint: String?
    ) async throws -> BatchTranscriptionResult {
        let (request, bodyFileURL) = try makeUpload(
            audioFileURL: audioFileURL,
            diarize: diarize,
            languageHint: languageHint
        )
        defer { try? FileManager.default.removeItem(at: bodyFileURL) }

        let (data, response) = try await urlSession.upload(for: request, fromFile: bodyFileURL)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw BatchTranscriptionError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? -1, data)
        }

        return try Self.parse(data)
    }

    /// Builds the request and stages its multipart body in a temp file that
    /// the caller uploads and then deletes. Uploading from disk keeps an
    /// hour-long recording from being held in memory whole.
    func makeUpload(
        audioFileURL: URL,
        diarize: Bool,
        languageHint: String?
    ) throws -> (request: URLRequest, bodyFileURL: URL) {
        let boundary = "----wcs-\(UUID().uuidString)"
        var request = URLRequest(url: Endpoints.batchSpeechToText)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var fields = Data()
        func appendField(_ name: String, _ value: String) {
            fields.append("--\(boundary)\r\n".data(using: .utf8)!)
            fields.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            fields.append(value.data(using: .utf8)!)
            fields.append("\r\n".data(using: .utf8)!)
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

        let bodyFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wcs-batch-\(UUID().uuidString).multipart")
        do {
            try Self.writeMultipartBody(
                to: bodyFileURL,
                fields: fields,
                boundary: boundary,
                audioFileURL: audioFileURL
            )
        } catch {
            try? FileManager.default.removeItem(at: bodyFileURL)
            throw error
        }
        return (request, bodyFileURL)
    }

    /// Writes the encoded `fields`, the audio file part and the closing
    /// boundary to `destination`. The audio is copied `chunkSize` bytes at a
    /// time; its first chunk also decides the part's Content-Type.
    static func writeMultipartBody(
        to destination: URL,
        fields: Data,
        boundary: String,
        audioFileURL: URL,
        chunkSize: Int = 1 << 20
    ) throws {
        let input = try FileHandle(forReadingFrom: audioFileURL)
        defer { try? input.close() }
        var chunk = try input.read(upToCount: chunkSize) ?? Data()
        let contentType = audioContentType(header: chunk, pathExtension: audioFileURL.pathExtension)

        var head = fields
        head.append("--\(boundary)\r\n".data(using: .utf8)!)
        head.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(audioFileURL.lastPathComponent)\"\r\n".data(using: .utf8)!)
        head.append("Content-Type: \(contentType)\r\n\r\n".data(using: .utf8)!)
        try head.write(to: destination)

        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        _ = try output.seekToEnd()
        while !chunk.isEmpty {
            try output.write(contentsOf: chunk)
            chunk = try autoreleasepool { try input.read(upToCount: chunkSize) } ?? Data()
        }
        try output.write(contentsOf: "\r\n--\(boundary)--\r\n".data(using: .utf8)!)
    }

    /// MIME type for the audio part. `OpusFileWriter` falls back to PCM in
    /// the same `.opus`-named file, and `AVAudioFile` picks the container
    /// itself, so the extension can't be trusted: sniff the container from
    /// its leading bytes and use the extension only when they're unknown.
    static func audioContentType(header: Data, pathExtension: String) -> String {
        func hasMagic(_ magic: String, at offset: Int = 0) -> Bool {
            let bytes = Array(magic.utf8)
            guard header.count >= offset + bytes.count else { return false }
            return header.dropFirst(offset).prefix(bytes.count).elementsEqual(bytes)
        }
        if hasMagic("OggS") { return "audio/ogg" }
        if hasMagic("caff") { return "audio/x-caf" }
        if hasMagic("RIFF"), hasMagic("WAVE", at: 8) { return "audio/wav" }
        if hasMagic("ftyp", at: 4) { return "audio/mp4" }
        switch pathExtension.lowercased() {
        case "opus", "ogg": return "audio/ogg"
        case "caf": return "audio/x-caf"
        case "wav": return "audio/wav"
        case "m4a": return "audio/mp4"
        default: return "application/octet-stream"
        }
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
