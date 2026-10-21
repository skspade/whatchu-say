import Foundation
@testable import Meeting

actor MockAudioRecorder: AudioRecorderProtocol {
    var didStart = false
    var didStop = false
    private(set) var startCount = 0
    private(set) var stopCount = 0
    var startError: Error?

    /// One-shot gates: when armed, the next `start()` / `stop()` parks until
    /// released, so tests can race other orchestrator calls against a
    /// recorder that is still spinning up (e.g. behind a TCC prompt).
    private var blockNextStart = false
    private var blockNextStop = false
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var stopContinuation: CheckedContinuation<Void, Never>?

    func setStartError(_ e: Error?) { startError = e }
    func blockStart() { blockNextStart = true }
    func blockStop() { blockNextStop = true }

    var isStartBlocked: Bool { startContinuation != nil }
    var isStopBlocked: Bool { stopContinuation != nil }

    func releaseStart() {
        guard let cont = startContinuation else { return }
        startContinuation = nil
        cont.resume()
    }

    func releaseStop() {
        guard let cont = stopContinuation else { return }
        stopContinuation = nil
        cont.resume()
    }

    func start() async throws {
        startCount += 1
        if blockNextStart {
            blockNextStart = false
            await withCheckedContinuation { cont in
                startContinuation = cont
            }
        }
        if let e = startError { throw e }
        didStart = true
    }

    func stop() async {
        stopCount += 1
        if blockNextStop {
            blockNextStop = false
            await withCheckedContinuation { cont in
                stopContinuation = cont
            }
        }
        didStop = true
    }
}
