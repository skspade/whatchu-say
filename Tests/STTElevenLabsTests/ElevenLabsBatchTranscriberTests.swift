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
          "segments": [
            {"start": 0.0, "end": 1.5, "speaker": null, "text": "Hello."},
            {"start": 1.5, "end": 3.0, "speaker": 0, "text": "Hi there."}
          ]
        }
        """.data(using: .utf8)!
        StubURLProtocol.stubbedResponse = (json, HTTPURLResponse(url: URL(string: "https://x")!, statusCode: 200, httpVersion: nil, headerFields: nil)!)

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("test.opus")
        try Data().write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let t = ElevenLabsBatchTranscriber(apiKey: "key", urlSession: makeSession())
        let result = try await t.transcribe(audioFileURL: tmp, diarize: true, languageHint: nil)
        #expect(result.segments.count == 2)
        #expect(result.segments[0].speakerId == nil)
        #expect(result.segments[1].speakerId == 0)
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
        let json = #"{"segments": []}"#.data(using: .utf8)!
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
        let json = #"{"segments": []}"#.data(using: .utf8)!
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
