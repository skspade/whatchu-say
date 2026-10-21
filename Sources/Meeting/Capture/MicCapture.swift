#if canImport(AVFoundation)
import Foundation
@preconcurrency import AVFoundation

@available(macOS 15, *)
public actor MicCapture: AudioRecorderProtocol {
    private let outputURL: URL
    private var engine: AVAudioEngine?
    private var sink: TapFileSink?

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
        let writer = try OpusFileWriter(url: outputURL, sampleRate: inputFormat.sampleRate)
        let sink = TapFileSink(writer: writer)
        self.engine = engine
        self.sink = sink

        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
            sink.append(buffer)
        }
        try engine.start()
    }

    public func stop() async {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        sink?.close()
        sink = nil
    }
}
#endif
