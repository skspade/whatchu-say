#if canImport(AVFoundation)
import Foundation
import os
import Core
@preconcurrency import AVFoundation

/// Writes audio to an Ogg/Opus file via `AVAudioFile`. If Opus is unavailable
/// in the SDK we're building against, falls back to CAF/PCM (still accepted
/// by Scribe v2 batch). The container choice is internal — callers only see
/// the URL.
///
/// The file is always mono, but capture taps deliver buffers in the device's
/// native layout (stereo for the system tap, 2–4+ channels for USB/array
/// mics). `append` averages those down to mono and resamples to the file's
/// `processingFormat` when needed, since `AVAudioFile.write(from:)` rejects
/// any buffer that doesn't match it.
@available(macOS 15, *)
public final class OpusFileWriter {
    private static let log = AppLogger.logger(for: .audio)

    private let file: AVAudioFile
    /// Long-lived so resampler state carries across buffers; rebuilt only if
    /// the incoming format changes.
    private var converter: AVAudioConverter?
    private var writeFailures = 0

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

    /// Capture actors call this once per tap buffer and can't act on a
    /// failure, so failures are also logged here (first, then every 100th)
    /// rather than vanishing into their `try?`.
    public func append(buffer: AVAudioPCMBuffer) throws {
        do {
            guard let conformed = try conform(buffer) else { return }
            try file.write(from: conformed)
        } catch {
            writeFailures += 1
            let count = writeFailures
            if count == 1 || count % 100 == 0 {
                let name = file.url.lastPathComponent
                let format = String(describing: buffer.format)
                Self.log.error("write to \(name, privacy: .public) FAILED (total: \(count), buffer format: \(format, privacy: .public)): \(error.localizedDescription, privacy: .public)")
            }
            throw error
        }
    }

    public func close() throws {
        // Closing finalizes the header now instead of whenever the file is
        // deinitialized. The class is already macOS 15+; the check only
        // matters for iOS builds of the package.
        if #available(iOS 18.0, *) {
            file.close()
        }
    }

    // MARK: - Format conversion

    /// Returns `buffer` in the file's processing format, or nil if there is
    /// nothing to write yet (empty input, or the resampler is still priming).
    private func conform(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0 else { return nil }
        let target = file.processingFormat
        if buffer.format == target { return buffer }

        var source = buffer
        if buffer.format.channelCount > 1, target.channelCount == 1 {
            // Downmix straight into the target format when only the channel
            // count differs, so the common case needs no converter at all.
            let downmixesIntoTarget = target.commonFormat == .pcmFormatFloat32
                && target.sampleRate == buffer.format.sampleRate
            let monoFormat: AVAudioFormat? = downmixesIntoTarget
                ? target
                : AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: buffer.format.sampleRate,
                    channels: 1,
                    interleaved: false
                )
            guard let monoFormat,
                  let mono = Self.downmixToMono(inputBuffer: buffer, monoFormat: monoFormat)
            else {
                throw MeetingError.captureSetupFailed("cannot downmix \(buffer.format) to mono")
            }
            if downmixesIntoTarget { return mono }
            source = mono
        }
        return try convert(source, to: target)
    }

    private func convert(_ inputBuffer: AVAudioPCMBuffer, to target: AVAudioFormat) throws -> AVAudioPCMBuffer? {
        let converter: AVAudioConverter
        if let cached = self.converter, cached.inputFormat == inputBuffer.format {
            converter = cached
        } else {
            guard let fresh = AVAudioConverter(from: inputBuffer.format, to: target) else {
                throw MeetingError.captureSetupFailed("no converter from \(inputBuffer.format) to \(target)")
            }
            self.converter = fresh
            converter = fresh
        }

        let outputCapacity = AVAudioFrameCount(
            ceil(Double(inputBuffer.frameLength) * target.sampleRate / inputBuffer.format.sampleRate)
        ) + 32
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outputCapacity) else {
            throw MeetingError.captureSetupFailed("cannot allocate \(outputCapacity) frames of \(target)")
        }

        let supplyState = SupplyState()
        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error) { _, statusPtr in
            if supplyState.supplied {
                statusPtr.pointee = .noDataNow
                return nil
            }
            supplyState.supplied = true
            statusPtr.pointee = .haveData
            return inputBuffer
        }

        if let error { throw error }
        if status == .error {
            throw MeetingError.captureSetupFailed("conversion from \(inputBuffer.format) to \(target) failed")
        }
        return outputBuffer.frameLength > 0 ? outputBuffer : nil
    }

    /// Average all input channels into a single mono Float32 buffer at the
    /// input sample rate. Same approach as dictation's `AVAudioCapture`
    /// (copied, since Meeting doesn't depend on the Audio target): array mics
    /// contribute every capsule, and averaging preserves peak headroom.
    private static func downmixToMono(
        inputBuffer: AVAudioPCMBuffer,
        monoFormat: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let frameLength = Int(inputBuffer.frameLength)
        guard frameLength > 0,
              let inChannels = inputBuffer.floatChannelData,
              let monoBuffer = AVAudioPCMBuffer(
                  pcmFormat: monoFormat,
                  frameCapacity: AVAudioFrameCount(frameLength)
              ),
              let outData = monoBuffer.floatChannelData?[0]
        else { return nil }

        monoBuffer.frameLength = AVAudioFrameCount(frameLength)
        let channelCount = Int(inputBuffer.format.channelCount)

        if channelCount == 1 {
            memcpy(outData, inChannels[0], frameLength * MemoryLayout<Float>.size)
        } else if inputBuffer.format.isInterleaved {
            let inData = inChannels[0]
            let scale: Float = 1.0 / Float(channelCount)
            for frame in 0..<frameLength {
                var sum: Float = 0
                for ch in 0..<channelCount {
                    sum += inData[frame * channelCount + ch]
                }
                outData[frame] = sum * scale
            }
        } else {
            let scale: Float = 1.0 / Float(channelCount)
            for frame in 0..<frameLength {
                var sum: Float = 0
                for ch in 0..<channelCount {
                    sum += inChannels[ch][frame]
                }
                outData[frame] = sum * scale
            }
        }

        return monoBuffer
    }
}

// Single-call latch for the AVAudioConverter input block (which is invoked
// repeatedly until we return `.noDataNow`). A class lets the @Sendable
// converter callback mutate its flag without tripping strict-concurrency.
private final class SupplyState: @unchecked Sendable {
    var supplied = false
}
#endif
