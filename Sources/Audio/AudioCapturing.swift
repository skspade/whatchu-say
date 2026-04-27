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

public enum AudioCaptureError: Error, Sendable, Equatable {
    /// User declined the microphone permission prompt (or the host app lacks
    /// the required entitlement / Info.plist usage description).
    case permissionDenied
    /// Target output format (16 kHz mono Int16) could not be constructed.
    case formatUnsupported
    /// AVAudioConverter could not bridge the device-native format to ours.
    case converterUnavailable
    /// AVAudioEngine.start() threw — message preserved for diagnostics.
    case engineStartFailed(String)
}
