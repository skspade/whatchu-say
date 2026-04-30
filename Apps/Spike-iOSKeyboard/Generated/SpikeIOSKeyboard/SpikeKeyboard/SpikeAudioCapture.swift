import Foundation
@preconcurrency import AVFoundation

/// Spike-grade `AVAudioEngine` capture. Configures `AVAudioSession`,
/// installs an input tap, converts to 16 kHz mono Int16, re-chunks to
/// 320-sample (20 ms) frames, and yields them through an `AsyncStream`.
///
/// This is intentionally simpler than `Sources/Audio/AVAudioCapture.swift`:
/// no drain handshake, no in-flight counter, no RMS stream. Just enough to
/// answer "does the input tap produce frames inside a keyboard extension."
///
/// Concurrency caveat: the `Chunker`-equivalent `leftover` buffer is mutated
/// from the audio tap dispatch queue, which is serial, so we mark the class
/// `@unchecked Sendable`. Don't promote this code without revisiting that.
final class SpikeAudioCapture: @unchecked Sendable {
    let frames: AsyncStream<[Int16]>
    private let framesContinuation: AsyncStream<[Int16]>.Continuation

    private let engine = AVAudioEngine()
    private var leftover: [Int16] = []

    private static let outputSampleRate: Double = 16_000
    private static let frameSize = 320 // 20 ms at 16 kHz

    init() {
        (self.frames, self.framesContinuation) = AsyncStream<[Int16]>.makeStream(
            bufferingPolicy: .bufferingNewest(64)
        )
    }

    func start() async throws {
        // 1. Permission first. Without it, AVAudioSession may "succeed"
        //    activation but engine.start() fails with the generic
        //    'what' (kAudioUnitErr_NoConnection) error because the audio
        //    path has no granted route. Returns false immediately if iOS
        //    has previously denied or can't show a prompt — the spike
        //    surfaces this distinctly from a session-config failure.
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        let granted: Bool
        switch status {
        case .authorized: granted = true
        case .denied, .restricted: granted = false
        case .notDetermined:
            granted = await AVCaptureDevice.requestAccess(for: .audio)
        @unknown default:
            granted = await AVCaptureDevice.requestAccess(for: .audio)
        }
        guard granted else {
            throw SpikeAudioError.micDenied(initialStatus: status)
        }

        // 2. Configure the audio session for record. Each step logs its
        //    own error so we can see which call rejected.
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .record,
                mode: .measurement,
                options: [.allowBluetoothHFP]
            )
        } catch {
            throw SpikeAudioError.setCategoryFailed(error)
        }
        do {
            try session.setPreferredSampleRate(Self.outputSampleRate)
            try session.setPreferredIOBufferDuration(0.02)
        } catch {
            throw SpikeAudioError.preferredFailed(error)
        }
        do {
            try session.setActive(true, options: [])
        } catch {
            throw SpikeAudioError.setActiveFailed(error)
        }

        // 3. Build the AVAudioEngine input tap.
        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Self.outputSampleRate,
            channels: 1,
            interleaved: true
        ), let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw SpikeAudioError.formatUnsupported
        }

        let box = ConverterBox(converter: converter, outputFormat: outputFormat)

        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.handleBuffer(buffer, box: box)
        }
        do {
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            throw SpikeAudioError.engineStartFailed(error)
        }
    }

    func stop() async {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: [.notifyOthersOnDeactivation]
        )
        framesContinuation.finish()
    }

    private func handleBuffer(_ buffer: AVAudioPCMBuffer, box: ConverterBox) {
        let outputCapacity = AVAudioFrameCount(
            ceil(Double(buffer.frameLength) * box.outputFormat.sampleRate / buffer.format.sampleRate)
        ) + 32
        guard outputCapacity > 0,
              let outBuf = AVAudioPCMBuffer(
                  pcmFormat: box.outputFormat,
                  frameCapacity: outputCapacity
              )
        else { return }

        var supplied = false
        var error: NSError?
        let status = box.converter.convert(to: outBuf, error: &error) { _, statusPtr in
            if supplied { statusPtr.pointee = .noDataNow; return nil }
            supplied = true
            statusPtr.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil else { return }
        let count = Int(outBuf.frameLength)
        guard count > 0, let ptr = outBuf.int16ChannelData?.pointee else { return }

        leftover.append(contentsOf: UnsafeBufferPointer(start: ptr, count: count))
        while leftover.count >= Self.frameSize {
            let frame = Array(leftover.prefix(Self.frameSize))
            leftover.removeFirst(Self.frameSize)
            framesContinuation.yield(frame)
        }
    }
}

enum SpikeAudioError: Error, CustomStringConvertible {
    case micDenied(initialStatus: AVAuthorizationStatus)
    case formatUnsupported
    case setCategoryFailed(Error)
    case preferredFailed(Error)
    case setActiveFailed(Error)
    case engineStartFailed(Error)

    var description: String {
        switch self {
        case .micDenied(let s):     return "micDenied(initial=\(s.label))"
        case .formatUnsupported:    return "formatUnsupported"
        case .setCategoryFailed(let e): return "setCategory: \(e)"
        case .preferredFailed(let e):   return "preferred: \(e)"
        case .setActiveFailed(let e):   return "setActive: \(e)"
        case .engineStartFailed(let e): return "engine.start: \(e)"
        }
    }
}

private extension AVAuthorizationStatus {
    var label: String {
        switch self {
        case .notDetermined: return "notDetermined"
        case .restricted:    return "restricted"
        case .denied:        return "denied"
        case .authorized:    return "authorized"
        @unknown default:    return "unknown"
        }
    }
}

private final class ConverterBox: @unchecked Sendable {
    let converter: AVAudioConverter
    let outputFormat: AVAudioFormat
    init(converter: AVAudioConverter, outputFormat: AVAudioFormat) {
        self.converter = converter
        self.outputFormat = outputFormat
    }
}
