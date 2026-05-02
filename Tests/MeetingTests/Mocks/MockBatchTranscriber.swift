import Foundation
import STTCore

actor MockBatchTranscriber: BatchTranscriber {
    var responseFor: [URL: BatchTranscriptionResult] = [:]
    var callCount = 0
    var lastDiarize: Bool?

    func setResponse(_ result: BatchTranscriptionResult, for url: URL) {
        responseFor[url] = result
    }

    func transcribe(audioFileURL: URL, diarize: Bool, languageHint: String?) async throws -> BatchTranscriptionResult {
        callCount += 1
        lastDiarize = diarize
        guard let r = responseFor[audioFileURL] else {
            throw NSError(domain: "MockBatch", code: 1)
        }
        return r
    }
}
