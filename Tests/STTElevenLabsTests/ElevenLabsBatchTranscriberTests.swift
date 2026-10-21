import Testing
import Foundation
@testable import STTElevenLabs
import STTCore

final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var stubbedResponse: (Data, HTTPURLResponse)?
    nonisolated(unsafe) static var lastRequestBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        // Capture whatever body URLSession hands the protocol (as
        // httpBodyStream or httpBody). Upload-task bodies aren't guaranteed
        // to arrive here, so multipart assertions read the staged body from
        // `makeUpload` instead.
        if let stream = request.httpBodyStream {
            stream.open()
            var collected = Data()
            let bufferSize = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer {
                buffer.deallocate()
                stream.close()
            }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: bufferSize)
                if read <= 0 { break }
                collected.append(buffer, count: read)
            }
            Self.lastRequestBody = collected
        } else {
            Self.lastRequestBody = request.httpBody
        }

        guard let (data, response) = Self.stubbedResponse else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "stub", code: 0))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("ElevenLabsBatchTranscriber", .serialized)
struct ElevenLabsBatchTranscriberTests {
    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    @Test("parses Scribe v2 JSON response into BatchTranscriptionResult")
    func parseResponse() async throws {
        let json = """
        {
          "language_code": "eng",
          "language_probability": 0.98,
          "text": "Hi there. Hello.",
          "words": [
            {"text": "Hi", "start": 0.0, "end": 0.25, "type": "word", "speaker_id": "speaker_0"},
            {"text": " ", "start": 0.25, "end": 0.5, "type": "spacing", "speaker_id": "speaker_0"},
            {"text": "there.", "start": 0.5, "end": 0.75, "type": "word", "speaker_id": "speaker_0"},
            {"text": " ", "start": 0.75, "end": 1.0, "type": "spacing", "speaker_id": "speaker_1"},
            {"text": "Hello.", "start": 1.0, "end": 1.5, "type": "word", "speaker_id": "speaker_1"}
          ]
        }
        """.data(using: .utf8)!
        StubURLProtocol.stubbedResponse = (json, HTTPURLResponse(url: URL(string: "https://x")!, statusCode: 200, httpVersion: nil, headerFields: nil)!)

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("test.opus")
        try Data().write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let t = ElevenLabsBatchTranscriber(apiKey: "key", urlSession: makeSession())
        let result = try await t.transcribe(audioFileURL: tmp, diarize: true, languageHint: nil)
        #expect(result.segments == [
            BatchSegment(start: 0.0, end: 0.75, speakerId: 0, text: "Hi there."),
            BatchSegment(start: 1.0, end: 1.5, speakerId: 1, text: "Hello."),
        ])
    }

    @Test("groups consecutive words by speaker, starting a new segment on each speaker change")
    func groupsBySpeaker() throws {
        let json = """
        {
          "text": "Hi there. Hello. Bye.",
          "words": [
            {"text": "Hi", "start": 0.0, "end": 0.25, "type": "word", "speaker_id": "speaker_0"},
            {"text": " ", "start": 0.25, "end": 0.5, "type": "spacing", "speaker_id": "speaker_0"},
            {"text": "there.", "start": 0.5, "end": 0.75, "type": "word", "speaker_id": "speaker_0"},
            {"text": " ", "start": 0.75, "end": 1.0, "type": "spacing", "speaker_id": "speaker_0"},
            {"text": "Hello.", "start": 1.0, "end": 1.5, "type": "word", "speaker_id": "speaker_1"},
            {"text": " ", "start": 1.5, "end": 2.0, "type": "spacing", "speaker_id": "speaker_1"},
            {"text": "Bye.", "start": 2.0, "end": 2.5, "type": "word", "speaker_id": "speaker_0"}
          ]
        }
        """.data(using: .utf8)!
        let result = try ElevenLabsBatchTranscriber.parse(json)
        #expect(result.segments == [
            BatchSegment(start: 0.0, end: 0.75, speakerId: 0, text: "Hi there."),
            BatchSegment(start: 1.0, end: 1.5, speakerId: 1, text: "Hello."),
            BatchSegment(start: 2.0, end: 2.5, speakerId: 0, text: "Bye."),
        ])
    }

    @Test("maps speaker_N labels to N and anything else to nil")
    func speakerLabelParsing() throws {
        #expect(ElevenLabsBatchTranscriber.speakerNumber(from: "speaker_0") == 0)
        #expect(ElevenLabsBatchTranscriber.speakerNumber(from: "speaker_12") == 12)
        #expect(ElevenLabsBatchTranscriber.speakerNumber(from: "agent") == nil)
        #expect(ElevenLabsBatchTranscriber.speakerNumber(from: "speaker_") == nil)
        #expect(ElevenLabsBatchTranscriber.speakerNumber(from: nil) == nil)

        let json = """
        {"text": "Yes.", "words": [
          {"text": "Yes.", "start": 0.0, "end": 0.5, "type": "word", "speaker_id": "speaker_3"}
        ]}
        """.data(using: .utf8)!
        let result = try ElevenLabsBatchTranscriber.parse(json)
        #expect(result.segments.map(\.speakerId) == [3])
    }

    @Test("words without speaker_id (no diarization) group into nil-speaker segments")
    func missingSpeakerId() throws {
        let json = """
        {
          "text": "Just me talking.",
          "words": [
            {"text": "Just", "start": 0.0, "end": 0.25, "type": "word"},
            {"text": " ", "start": 0.25, "end": 0.5, "type": "spacing"},
            {"text": "me", "start": 0.5, "end": 0.75, "type": "word"},
            {"text": " ", "start": 0.75, "end": 1.0, "type": "spacing"},
            {"text": "talking.", "start": 1.0, "end": 1.5, "type": "word"}
          ]
        }
        """.data(using: .utf8)!
        let result = try ElevenLabsBatchTranscriber.parse(json)
        #expect(result.segments == [
            BatchSegment(start: 0.0, end: 1.5, speakerId: nil, text: "Just me talking."),
        ])
    }

    @Test("a long pause starts a new segment even for the same speaker")
    func splitsOnPause() throws {
        let json = """
        {
          "text": "First part. Second part.",
          "words": [
            {"text": "First", "start": 0.0, "end": 0.5, "type": "word"},
            {"text": " ", "start": 0.5, "end": 0.5, "type": "spacing"},
            {"text": "part.", "start": 0.5, "end": 1.0, "type": "word"},
            {"text": " ", "start": 1.0, "end": 5.0, "type": "spacing"},
            {"text": "Second", "start": 5.0, "end": 5.5, "type": "word"},
            {"text": " ", "start": 5.5, "end": 5.5, "type": "spacing"},
            {"text": "part.", "start": 5.5, "end": 6.0, "type": "word"}
          ]
        }
        """.data(using: .utf8)!
        let result = try ElevenLabsBatchTranscriber.parse(json)
        #expect(result.segments == [
            BatchSegment(start: 0.0, end: 1.0, speakerId: nil, text: "First part."),
            BatchSegment(start: 5.0, end: 6.0, speakerId: nil, text: "Second part."),
        ])
    }

    @Test("audio events are dropped from text and don't split a speaker's turn")
    func dropsAudioEvents() throws {
        let json = """
        {
          "text": "Okay (laughter) fine.",
          "words": [
            {"text": "Okay", "start": 0.0, "end": 0.5, "type": "word", "speaker_id": "speaker_0"},
            {"text": " ", "start": 0.5, "end": 0.5, "type": "spacing", "speaker_id": "speaker_0"},
            {"text": "(laughter)", "start": 0.5, "end": 1.0, "type": "audio_event", "speaker_id": "speaker_1"},
            {"text": " ", "start": 1.0, "end": 1.0, "type": "spacing", "speaker_id": "speaker_0"},
            {"text": "fine.", "start": 1.0, "end": 1.5, "type": "word", "speaker_id": "speaker_0"}
          ]
        }
        """.data(using: .utf8)!
        let result = try ElevenLabsBatchTranscriber.parse(json)
        #expect(result.segments == [
            BatchSegment(start: 0.0, end: 1.5, speakerId: 0, text: "Okay fine."),
        ])
    }

    @Test("falls back to top-level text when the response has no words")
    func textFallback() throws {
        let json = #"{"text": " Hello world. ", "audio_duration_secs": 2.5}"#.data(using: .utf8)!
        let result = try ElevenLabsBatchTranscriber.parse(json)
        #expect(result.segments == [
            BatchSegment(start: 0, end: 2.5, speakerId: nil, text: "Hello world."),
        ])

        let empty = #"{"text": "", "words": []}"#.data(using: .utf8)!
        #expect(try ElevenLabsBatchTranscriber.parse(empty).segments.isEmpty)
    }

    @Test("requests diarization and word timestamps in the multipart body")
    func diarizationFieldsSent() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("test.opus")
        try Data().write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let t = ElevenLabsBatchTranscriber(apiKey: "key", urlSession: makeSession())
        // Read the staged multipart body directly: a URLProtocol isn't
        // guaranteed to see the body of an upload(for:fromFile:) task.
        let upload = try t.makeUpload(audioFileURL: tmp, diarize: true, languageHint: nil)
        defer { try? FileManager.default.removeItem(at: upload.bodyFileURL) }

        let body = try Data(contentsOf: upload.bodyFileURL)
        let bodyText = try #require(String(data: body, encoding: .utf8))
        #expect(bodyText.contains("name=\"diarize\"\r\n\r\ntrue\r\n"))
        #expect(bodyText.contains("name=\"timestamps_granularity\"\r\n\r\nword\r\n"))
    }

    @Test("throws on non-2xx response")
    func httpError() async throws {
        StubURLProtocol.stubbedResponse = (Data(), HTTPURLResponse(url: URL(string: "https://x")!, statusCode: 401, httpVersion: nil, headerFields: nil)!)

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("test.opus")
        try Data().write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let t = ElevenLabsBatchTranscriber(apiKey: "key", urlSession: makeSession())
        await #expect(throws: Error.self) {
            _ = try await t.transcribe(audioFileURL: tmp, diarize: false, languageHint: nil)
        }
    }

    @Test("noVerbatim=true adds a no_verbatim multipart field")
    func noVerbatimFieldSent() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("test.opus")
        try Data().write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let t = ElevenLabsBatchTranscriber(apiKey: "key", urlSession: makeSession(), noVerbatim: true)
        // Read the staged multipart body directly: a URLProtocol isn't
        // guaranteed to see the body of an upload(for:fromFile:) task.
        let upload = try t.makeUpload(audioFileURL: tmp, diarize: false, languageHint: nil)
        defer { try? FileManager.default.removeItem(at: upload.bodyFileURL) }

        let body = try Data(contentsOf: upload.bodyFileURL)
        let bodyText = try #require(String(data: body, encoding: .utf8))
        #expect(bodyText.contains("name=\"no_verbatim\""))
        #expect(bodyText.contains("\r\n\r\ntrue\r\n"))
    }

    @Test("noVerbatim=false omits the no_verbatim multipart field")
    func noVerbatimFieldOmittedByDefault() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("test.opus")
        try Data().write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let t = ElevenLabsBatchTranscriber(apiKey: "key", urlSession: makeSession())
        // Read the staged multipart body directly: a URLProtocol isn't
        // guaranteed to see the body of an upload(for:fromFile:) task.
        let upload = try t.makeUpload(audioFileURL: tmp, diarize: false, languageHint: nil)
        defer { try? FileManager.default.removeItem(at: upload.bodyFileURL) }

        let body = try Data(contentsOf: upload.bodyFileURL)
        let bodyText = try #require(String(data: body, encoding: .utf8))
        #expect(!bodyText.contains("name=\"no_verbatim\""))
    }

    @Test("upload request carries the configured timeout, 30 minutes by default")
    func requestTimeoutApplied() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("timeout-\(UUID().uuidString).opus")
        try Data().write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let custom = ElevenLabsBatchTranscriber(apiKey: "key", requestTimeout: 5)
        let upload = try custom.makeUpload(audioFileURL: tmp, diarize: false, languageHint: nil)
        defer { try? FileManager.default.removeItem(at: upload.bodyFileURL) }
        #expect(upload.request.timeoutInterval == 5)

        let standard = ElevenLabsBatchTranscriber(apiKey: "key")
        let defaultUpload = try standard.makeUpload(audioFileURL: tmp, diarize: false, languageHint: nil)
        defer { try? FileManager.default.removeItem(at: defaultUpload.bodyFileURL) }
        #expect(defaultUpload.request.timeoutInterval == 30 * 60)
    }

    @Test("audio part Content-Type follows the sniffed container, then the extension")
    func audioContentTypeMapping() {
        let noHeader = Data()
        #expect(ElevenLabsBatchTranscriber.audioContentType(header: noHeader, pathExtension: "opus") == "audio/ogg")
        #expect(ElevenLabsBatchTranscriber.audioContentType(header: noHeader, pathExtension: "ogg") == "audio/ogg")
        #expect(ElevenLabsBatchTranscriber.audioContentType(header: noHeader, pathExtension: "OPUS") == "audio/ogg")
        #expect(ElevenLabsBatchTranscriber.audioContentType(header: noHeader, pathExtension: "caf") == "audio/x-caf")
        #expect(ElevenLabsBatchTranscriber.audioContentType(header: noHeader, pathExtension: "wav") == "audio/wav")
        #expect(ElevenLabsBatchTranscriber.audioContentType(header: noHeader, pathExtension: "m4a") == "audio/mp4")
        #expect(ElevenLabsBatchTranscriber.audioContentType(header: noHeader, pathExtension: "bin") == "application/octet-stream")
        #expect(ElevenLabsBatchTranscriber.audioContentType(header: noHeader, pathExtension: "") == "application/octet-stream")

        // OpusFileWriter's PCM fallback writes CAF into the `.opus`-named file.
        let caf = Data("caff".utf8) + Data([0, 1, 0, 0])
        #expect(ElevenLabsBatchTranscriber.audioContentType(header: caf, pathExtension: "opus") == "audio/x-caf")
        let ogg = Data("OggS".utf8) + Data([0, 2])
        #expect(ElevenLabsBatchTranscriber.audioContentType(header: ogg, pathExtension: "caf") == "audio/ogg")
        let wav = Data("RIFF".utf8) + Data([0, 0, 0, 0]) + Data("WAVE".utf8)
        #expect(ElevenLabsBatchTranscriber.audioContentType(header: wav, pathExtension: "opus") == "audio/wav")
        let m4a = Data([0, 0, 0, 0x20]) + Data("ftypM4A ".utf8)
        #expect(ElevenLabsBatchTranscriber.audioContentType(header: m4a, pathExtension: "opus") == "audio/mp4")
    }

    @Test("multipart body copies the whole audio file across chunks with its sniffed type")
    func multipartBodyStreamsAudio() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("batch-body-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // CAF bytes under an .opus name, as OpusFileWriter's PCM fallback writes.
        let audioURL = dir.appendingPathComponent("mic.opus")
        let audio = Data("caff".utf8) + Data((0..<10_000).map { UInt8(truncatingIfNeeded: $0) })
        try audio.write(to: audioURL)

        let bodyURL = dir.appendingPathComponent("body.multipart")
        try ElevenLabsBatchTranscriber.writeMultipartBody(
            to: bodyURL,
            fields: Data("FIELDS".utf8),
            boundary: "B",
            audioFileURL: audioURL,
            chunkSize: 4096
        )

        var expected = Data("FIELDS".utf8)
        expected.append(Data("--B\r\nContent-Disposition: form-data; name=\"file\"; filename=\"mic.opus\"\r\n".utf8))
        expected.append(Data("Content-Type: audio/x-caf\r\n\r\n".utf8))
        expected.append(audio)
        expected.append(Data("\r\n--B--\r\n".utf8))
        let body = try Data(contentsOf: bodyURL)
        #expect(body == expected)
    }
}
