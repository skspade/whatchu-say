import Testing
import Foundation
@testable import STTElevenLabs
import STTCore

final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var stubbedResponse: (Data, HTTPURLResponse)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
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
}
