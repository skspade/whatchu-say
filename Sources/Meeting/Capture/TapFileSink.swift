#if canImport(AVFoundation)
import Foundation
@preconcurrency import AVFoundation

/// Owns a recorder's `OpusFileWriter` and serializes access to it between the
/// tap callback, which appends right on CoreAudio's serial tap queue, and the
/// recorder's `stop()`.
///
/// Appending in the callback keeps buffers in capture order (a Task per
/// buffer can reach the recorder actor out of order) and writes each buffer
/// before the engine can reuse it. `close()` takes the same lock, so it waits
/// out an in-progress append, and later callbacks become no-ops.
@available(macOS 15, *)
final class TapFileSink: @unchecked Sendable {
    private let lock = NSLock()
    private var writer: OpusFileWriter?

    init(writer: OpusFileWriter) {
        self.writer = writer
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            _ = try? writer?.append(buffer: buffer)
        }
    }

    func close() {
        lock.withLock {
            try? writer?.close()
            writer = nil
        }
    }
}
#endif
