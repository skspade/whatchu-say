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
        // URLProtocol receives the streamed body via httpBodyStream when the
        // request originated from URLSession with multipart data, so drain it
        // here to make the multipart payload assertable in tests.
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
    func diarizationFieldsSent() async throws {
        let json = #"{"text": "", "words": []}"#.data(using: .utf8)!
        StubURLProtocol.stubbedResponse = (json, HTTPURLResponse(url: URL(string: "https://x")!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        StubURLProtocol.lastRequestBody = nil

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("test.opus")
        try Data().write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let t = ElevenLabsBatchTranscriber(apiKey: "key", urlSession: makeSession())
        _ = try await t.transcribe(audioFileURL: tmp, diarize: true, languageHint: nil)

        let body = try #require(StubURLProtocol.lastRequestBody)
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
    func noVerbatimFieldSent() async throws {
        let json = #"{"text": "", "words": []}"#.data(using: .utf8)!
        StubURLProtocol.stubbedResponse = (json, HTTPURLResponse(url: URL(string: "https://x")!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        StubURLProtocol.lastRequestBody = nil

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("test.opus")
        try Data().write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let t = ElevenLabsBatchTranscriber(apiKey: "key", urlSession: makeSession(), noVerbatim: true)
        _ = try await t.transcribe(audioFileURL: tmp, diarize: false, languageHint: nil)

        let body = try #require(StubURLProtocol.lastRequestBody)
        let bodyText = try #require(String(data: body, encoding: .utf8))
        #expect(bodyText.contains("name=\"no_verbatim\""))
        #expect(bodyText.contains("\r\n\r\ntrue\r\n"))
    }

    @Test("noVerbatim=false omits the no_verbatim multipart field")
    func noVerbatimFieldOmittedByDefault() async throws {
        let json = #"{"text": "", "words": []}"#.data(using: .utf8)!
        StubURLProtocol.stubbedResponse = (json, HTTPURLResponse(url: URL(string: "https://x")!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        StubURLProtocol.lastRequestBody = nil

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("test.opus")
        try Data().write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let t = ElevenLabsBatchTranscriber(apiKey: "key", urlSession: makeSession())
        _ = try await t.transcribe(audioFileURL: tmp, diarize: false, languageHint: nil)

        let body = try #require(StubURLProtocol.lastRequestBody)
        let bodyText = try #require(String(data: body, encoding: .utf8))
        #expect(!bodyText.contains("name=\"no_verbatim\""))
    }
}
