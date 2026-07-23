#if canImport(AVFoundation)
import Foundation
@preconcurrency import AVFoundation

/// Writes audio as mono 16 kHz Opus (in a CAF container) via `AVAudioFile`.
///
/// The Opus codec is wrapped in CAF rather than Ogg (`.opus`) because
/// `AVAudioFile` cannot write an Ogg/Opus container on macOS — it yields
/// zero-byte files. CAF holds the same codec and writes correctly. 16 kHz is a
/// valid Opus rate and the standard speech-to-text input rate.
///
/// Tap buffers arrive in the device-native format (commonly stereo, 44.1/48 kHz
/// Float32), which does not match the file's mono 16 kHz processing format.
/// `append` downmixes + resamples through an `AVAudioConverter` before writing,
/// so callers can hand over whatever the hardware produces.
///
/// Not an actor: it is only ever touched from the capture tap's serial thread
/// during recording, and from `stop()` after the tap has been removed, so
/// `@unchecked Sendable` is safe.
@available(macOS 15, *)
public final class OpusFileWriter: @unchecked Sendable {
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?

    /// Number of buffers that failed to encode. Non-zero means the recording is
    /// incomplete (or empty). Read after `close()` for a summary.
    public private(set) var writeFailureCount = 0
    private var didLogFailure = false

    public init(url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatOpus,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
        self.file = try AVAudioFile(forWriting: url, settings: settings)
    }

    public func append(buffer: AVAudioPCMBuffer) throws {
        guard let file else { return }
        let target = file.processingFormat
        if buffer.format == target {
            try file.write(from: buffer)
            return
        }
        let converted = try convert(buffer, to: target)
        try file.write(from: converted)
    }

    /// Records a write failure and returns `true` only the first time, so
    /// callers can log once per recording instead of once per dropped buffer.
    public func registerFailure() -> Bool {
        writeFailureCount += 1
        if didLogFailure { return false }
        didLogFailure = true
        return true
    }

    public func close() throws {
        // AVAudioFile writes incrementally and flushes on release; dropping the
        // reference finalizes the file deterministically here rather than at an
        // unspecified deinit.
        file = nil
    }

    // MARK: - Conversion

    private func convert(_ input: AVAudioPCMBuffer, to target: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let converter = try converter(from: input.format, to: target)

        let inputRate = input.format.sampleRate
        let outputRate = target.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * outputRate / inputRate)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw MeetingError.captureSetupFailed("could not allocate conversion buffer")
        }

        let supply = SupplyState()
        var convError: NSError?
        let status = converter.convert(to: output, error: &convError) { _, statusPtr in
            if supply.supplied {
                statusPtr.pointee = .noDataNow
                return nil
            }
            supply.supplied = true
            statusPtr.pointee = .haveData
            return input
        }
        if status == .error {
            throw convError ?? MeetingError.captureSetupFailed("audio conversion failed")
        }
        return output
    }

    /// Lazily builds and caches the converter, rebuilding if the input format
    /// changes mid-stream (e.g. the user switches input device).
    private func converter(from inputFormat: AVAudioFormat, to target: AVAudioFormat) throws -> AVAudioConverter {
        if let converter, converterInputFormat == inputFormat {
            return converter
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: target) else {
            throw MeetingError.captureSetupFailed("could not create audio converter")
        }
        self.converter = converter
        self.converterInputFormat = inputFormat
        return converter
    }
}

/// Single-call latch for the `AVAudioConverter` input block, which is invoked
/// repeatedly until it returns `.noDataNow`. A class lets the callback flip its
/// flag without tripping strict-concurrency capture rules.
private final class SupplyState: @unchecked Sendable {
    var supplied = false
}
#endif
