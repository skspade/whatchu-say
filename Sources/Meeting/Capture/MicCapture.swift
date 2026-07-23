#if canImport(AVFoundation)
import Foundation
import Core
import OSLog
@preconcurrency import AVFoundation

@available(macOS 15, *)
public actor MicCapture: AudioRecorderProtocol {
    private let outputURL: URL
    private let log = AppLogger.logger(for: .audio)
    private var engine: AVAudioEngine?
    private var writer: OpusFileWriter?

    public init(outputURL: URL) {
        self.outputURL = outputURL
    }

    public func start() async throws {
        guard engine == nil else { return }
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard granted else { throw MeetingError.micPermissionDenied }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        let writer = try OpusFileWriter(url: outputURL)
        self.engine = engine
        self.writer = writer

        // Write synchronously on the tap's serial thread: the buffer is only
        // valid for the callback, and serial writes preserve frame order.
        let log = self.log
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
            do {
                try writer.append(buffer: buffer)
            } catch {
                if writer.registerFailure() {
                    log.error("Meeting mic audio write failed; recording may be empty: \(String(describing: error), privacy: .public)")
                }
            }
        }
        try engine.start()
    }

    public func stop() async {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        if let writer, writer.writeFailureCount > 0 {
            log.error("Meeting mic recording finished with \(writer.writeFailureCount, privacy: .public) failed audio buffers")
        }
        try? writer?.close()
        writer = nil
    }
}
#endif
