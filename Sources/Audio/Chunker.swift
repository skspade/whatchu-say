import Foundation

/// Re-chunks variable-size audio buffers into fixed-size frames suitable for the
/// STT provider. Stateful: leftover samples are retained between calls and
/// concatenated with the next batch.
public struct Chunker: Sendable {
    public let frameSize: Int
    private var pending: [Int16] = []

    public init(frameSize: Int = 320) {
        precondition(frameSize > 0, "frameSize must be positive")
        self.frameSize = frameSize
    }

    /// Append `samples` to the internal buffer and return every complete frame
    /// that can be formed. Any remainder stays buffered until the next call.
    public mutating func ingest(_ samples: [Int16]) -> [[Int16]] {
        if samples.isEmpty { return [] }
        pending.append(contentsOf: samples)
        guard pending.count >= frameSize else { return [] }

        var output: [[Int16]] = []
        var offset = 0
        while pending.count - offset >= frameSize {
            output.append(Array(pending[offset..<(offset + frameSize)]))
            offset += frameSize
        }
        pending.removeFirst(offset)
        return output
    }

    /// Drop any buffered partial frame. Call on session end to avoid leaking
    /// the tail of one capture into the head of the next.
    public mutating func reset() {
        pending.removeAll(keepingCapacity: true)
    }

    public var pendingCount: Int { pending.count }
}
