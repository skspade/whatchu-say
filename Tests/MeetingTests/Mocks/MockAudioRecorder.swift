import Foundation
@testable import Meeting

actor MockAudioRecorder: AudioRecorderProtocol {
    var didStart = false
    var didStop = false
    var startError: Error?

    func setStartError(_ e: Error?) { startError = e }

    func start() async throws {
        if let e = startError { throw e }
        didStart = true
    }
    func stop() async { didStop = true }
}
