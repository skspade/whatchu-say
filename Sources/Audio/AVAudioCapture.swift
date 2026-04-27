#if canImport(AVFoundation)
import Foundation
import AVFoundation

/// AVAudioEngine-backed `AudioCapturing`. Stub: real implementation in Milestone 1.2.
public actor AVAudioCapture: AudioCapturing {
    public nonisolated let frames: AsyncStream<AudioFrame>
    public nonisolated let rmsLevels: AsyncStream<Float>

    private let framesContinuation: AsyncStream<AudioFrame>.Continuation
    private let rmsContinuation: AsyncStream<Float>.Continuation

    public init() {
        let (fStream, fCont) = AsyncStream<AudioFrame>.makeStream()
        let (rStream, rCont) = AsyncStream<Float>.makeStream()
        self.frames = fStream
        self.rmsLevels = rStream
        self.framesContinuation = fCont
        self.rmsContinuation = rCont
    }

    public func start() async throws {
        // TODO: configure AVAudioEngine, install input tap, push frames.
    }

    public func stop() async {
        framesContinuation.finish()
        rmsContinuation.finish()
    }
}
#endif
