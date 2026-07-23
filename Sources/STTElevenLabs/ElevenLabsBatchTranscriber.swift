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
        if let lang = languageHint {
            appendField("language_code", lang)
        }
        if noVerbatim {
            appendField("no_verbatim", "true")
        }

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(audioFileURL.lastPathComponent)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(Self.contentType(for: audioFileURL.pathExtension))\r\n\r\n".data(using: .utf8)!)
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

    /// Maps an audio file extension to its MIME type for the multipart upload.
    /// Defaults to `audio/ogg` (the format the meeting recorder writes).
    static func contentType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "opus", "ogg": return "audio/ogg"
        case "wav": return "audio/wav"
        case "caf": return "audio/x-caf"
        case "m4a", "mp4": return "audio/mp4"
        case "flac": return "audio/flac"
        case "mp3": return "audio/mpeg"
        default: return "audio/ogg"
        }
    }

    static func parse(_ data: Data) throws -> BatchTranscriptionResult {
        struct Wire: Codable {
            struct Segment: Codable {
                let start: TimeInterval
                let end: TimeInterval
                let speaker: Int?
                let text: String
            }
            let segments: [Segment]
        }
        let wire = try JSONDecoder().decode(Wire.self, from: data)
        let segments = wire.segments.map {
            BatchSegment(start: $0.start, end: $0.end, speakerId: $0.speaker, text: $0.text)
        }
        return BatchTranscriptionResult(segments: segments)
    }
}

public enum BatchTranscriptionError: Error, Equatable {
    case httpStatus(Int, Data)
}
