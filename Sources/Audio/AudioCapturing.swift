import Foundation

public protocol AudioCapturing: Sendable {
    func start() async throws
    func stop() async
    var frames: AsyncStream<AudioFrame> { get }
    var rmsLevels: AsyncStream<Float> { get }
}

public struct AudioFrame: Sendable {
    public let samples: [Int16]
    public let timestamp: Duration

    public init(samples: [Int16], timestamp: Duration) {
        self.samples = samples
        self.timestamp = timestamp
    }
}
