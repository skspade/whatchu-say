import Foundation

/// Re-chunks variable-size audio buffers into fixed-size frames suitable for the
/// STT provider. Stub: real implementation in Milestone 1.2.
public actor Chunker {
    public let frameSize: Int

    public init(frameSize: Int = 320) {
        self.frameSize = frameSize
    }
}
