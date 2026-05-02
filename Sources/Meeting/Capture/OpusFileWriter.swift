#if canImport(AVFoundation)
import Foundation
@preconcurrency import AVFoundation

/// Writes audio to an Ogg/Opus file via `AVAudioFile`. If Opus is unavailable
/// in the SDK we're building against, falls back to CAF/PCM (still accepted
/// by Scribe v2 batch). The container choice is internal — callers only see
/// the URL.
@available(macOS 15, *)
public final class OpusFileWriter {
    private let file: AVAudioFile

    public init(url: URL, sampleRate: Double) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatOpus,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
        do {
            self.file = try AVAudioFile(forWriting: url, settings: settings)
        } catch {
            // Fallback: write CAF/Float32. Scribe v2 also accepts WAV/CAF.
            let pcm: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
            ]
            self.file = try AVAudioFile(forWriting: url, settings: pcm)
        }
    }

    public func append(buffer: AVAudioPCMBuffer) throws {
        try file.write(from: buffer)
    }

    public func close() throws {
        // AVAudioFile flushes on deinit. Nothing else to do here, but we keep
        // the explicit close so callers can handle errors deterministically.
    }
}
#endif
