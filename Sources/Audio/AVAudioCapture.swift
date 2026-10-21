#if canImport(AVFoundation)
import Foundation
@preconcurrency import AVFoundation
#if os(macOS)
import AudioToolbox
#endif

/// AVAudioEngine-backed `AudioCapturing`. Captures from the default input,
/// converts to 16 kHz mono Int16, re-chunks into 20 ms (320-sample) frames,
/// and emits both the frames and per-frame RMS (dBFS).
///
/// ## Pipeline
/// 1. `installTap` on the input bus, `tapBufferSize` samples per callback in
///    the device-native format.
/// 2. The tap callback runs on a serial CoreAudio dispatch queue (not the
///    realtime IO thread). We average multichannel input down to mono
///    Float32 ourselves (so 4-mic arrays like the PS Eye contribute every
///    capsule), then convert to mono Int16 16 kHz via a long-lived
///    `AVAudioConverter` (safe because the converter is only touched from
///    this serial queue).
/// 3. Still in the callback, the samples are chunked and yielded straight
///    into the streams (see `TapPipeline`). Handing each buffer to its own
///    Task instead could deliver chunks to the stream out of order.
///
/// ## Backpressure
/// The frames stream holds up to ~30 s (`bufferingNewest(1500)`) so a slow
/// WebSocket send doesn't lose audio; if it still overflows, the oldest
/// frames are dropped and logged. The RMS stream keeps only the newest 64
/// levels (it drives a meter). We never block the audio thread.
///
/// ## Lifecycle
/// `start()` is idempotent (a second call while running is a no-op). `stop()`
/// tears down the engine but keeps the streams open so the same instance can
/// be reused for the next dictation.
public actor AVAudioCapture: AudioCapturing {
    public nonisolated let frames: AsyncStream<AudioFrame>
    public nonisolated let rmsLevels: AsyncStream<Float>

    private nonisolated let framesContinuation: AsyncStream<AudioFrame>.Continuation
    private nonisolated let rmsContinuation: AsyncStream<Float>.Continuation

    private var engine: AVAudioEngine?
    private var pipeline: TapPipeline?

    private static let targetSampleRate: Double = 16_000
    private static let tapBufferSize: AVAudioFrameCount = 1024
    /// 30 s of 20 ms frames.
    private static let framesBuffer: Int = 1500
    private static let rmsBuffer: Int = 64

    public init() {
        let (fStream, fCont) = AsyncStream<AudioFrame>.makeStream(
            bufferingPolicy: .bufferingNewest(Self.framesBuffer)
        )
        let (rStream, rCont) = AsyncStream<Float>.makeStream(
            bufferingPolicy: .bufferingNewest(Self.rmsBuffer)
        )
        self.frames = fStream
        self.rmsLevels = rStream
        self.framesContinuation = fCont
        self.rmsContinuation = rCont
    }

    public func start() async throws {
        guard engine == nil else { return }

        print("[AVAudioCapture] requesting mic permission")
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        print("[AVAudioCapture] mic permission granted=\(granted)")
        guard granted else { throw AudioCaptureError.permissionDenied }

        let engine = AVAudioEngine()
        let input = engine.inputNode

        #if os(macOS)
        // AVAudioEngine may create an aggregate device (CADefaultDeviceAggregate)
        // that combines input + output, producing extra channels and I/O issues.
        // Explicitly pin the input node to the system default input device.
        if let audioUnit = input.audioUnit {
            var defaultDevice = Self.systemDefaultInputDevice()
            if defaultDevice != kAudioObjectUnknown {
                let setStatus = AudioUnitSetProperty(
                    audioUnit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &defaultDevice,
                    UInt32(MemoryLayout<AudioDeviceID>.size)
                )
                if setStatus != noErr {
                    print("[AVAudioCapture] failed to set input device (status \(setStatus))")
                }
            }
        }
        #endif

        let inputFormat = input.inputFormat(forBus: 0)
        print("[AVAudioCapture] input format: \(inputFormat)")

        #if os(macOS)
        if let audioUnit = input.audioUnit {
            print("[AVAudioCapture] input device: \(Self.inputDeviceName(from: audioUnit) ?? "unknown")")
        }
        #endif

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            print("[AVAudioCapture] invalid input format: sampleRate=\(inputFormat.sampleRate) channels=\(inputFormat.channelCount)")
            throw AudioCaptureError.formatUnsupported
        }

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: true
        ) else {
            throw AudioCaptureError.formatUnsupported
        }

        // Multi-channel arrays (e.g. PS Eye 4-mic, USB interfaces) need every
        // capsule mixed in — picking a single channel throws away signal and
        // SNR. We pre-mix to mono Float32 ourselves so the converter only does
        // sample-rate + Int16 conversion. Requires Float32 input, which is
        // what AVAudioEngine produces on macOS.
        guard inputFormat.commonFormat == .pcmFormatFloat32 else {
            print("[AVAudioCapture] unsupported input commonFormat: \(inputFormat.commonFormat.rawValue)")
            throw AudioCaptureError.formatUnsupported
        }

        guard let monoInputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputFormat.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioCaptureError.formatUnsupported
        }

        guard let converter = AVAudioConverter(from: monoInputFormat, to: outputFormat) else {
            throw AudioCaptureError.converterUnavailable
        }

        let box = ConverterBox(
            converter: converter,
            outputFormat: outputFormat,
            monoInputFormat: monoInputFormat
        )

        let pipeline = TapPipeline()
        let framesContinuation = self.framesContinuation
        let rmsContinuation = self.rmsContinuation
        let startedAt = ContinuousClock.now
        let stats = ConversionStats()
        input.installTap(
            onBus: 0,
            bufferSize: Self.tapBufferSize,
            format: inputFormat
        ) { inputBuffer, _ in
            guard pipeline.begin() else { return }
            defer { pipeline.end() }
            guard let monoBuffer = Self.downmixToMono(inputBuffer: inputBuffer, monoFormat: box.monoInputFormat),
                  let outputBuffer = Self.convert(inputBuffer: monoBuffer, using: box) else {
                let count = stats.recordFailure()
                if count == 1 || count % 100 == 0 {
                    print("[AVAudioCapture] conversion FAILED (total: \(count), buffer format: \(inputBuffer.format))")
                }
                return
            }
            let samples = Self.extractInt16(from: outputBuffer)
            if samples.isEmpty { return }
            let timestamp = startedAt.duration(to: .now)
            for chunk in pipeline.chunk(samples) {
                let result = framesContinuation.yield(AudioFrame(samples: chunk, timestamp: timestamp))
                if case .dropped = result {
                    let count = stats.recordDrop()
                    if count == 1 || count % 50 == 0 {
                        print("[AVAudioCapture] frames stream full — dropped oldest frame (total: \(count)); STT send is falling behind")
                    }
                }
                rmsContinuation.yield(RMSAnalyzer.level(chunk))
            }
        }

        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            print("[AVAudioCapture] engine.start FAILED: \(error)")
            throw AudioCaptureError.engineStartFailed(String(describing: error))
        }

        print("[AVAudioCapture] engine started")
        self.engine = engine
        self.pipeline = pipeline
    }

    public func stop() async {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        // A tap callback may still be running on CoreAudio's queue; wait for
        // it so every frame of this session is in the stream BEFORE we
        // publish the end-of-session sentinel.
        await pipeline?.drain()
        pipeline = nil
        // End-of-session sentinel: empty samples mark "all captured audio for
        // the just-ended session is now in the stream." Consumers (the
        // orchestrator's audio forwarder) use this to know when it's safe to
        // send `endOfStream` to the STT provider.
        framesContinuation.yield(AudioFrame(samples: [], timestamp: .zero))
    }

    // MARK: - Format conversion (runs on tap dispatch queue)

    private static func convert(
        inputBuffer: AVAudioPCMBuffer,
        using box: ConverterBox
    ) -> AVAudioPCMBuffer? {
        let inputRate = inputBuffer.format.sampleRate
        let outputRate = box.outputFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(
            ceil(Double(inputBuffer.frameLength) * outputRate / inputRate)
        ) + 32
        guard outputCapacity > 0,
              let outputBuffer = AVAudioPCMBuffer(
                  pcmFormat: box.outputFormat,
                  frameCapacity: outputCapacity
              )
        else { return nil }

        let supplyState = SupplyState()
        var error: NSError?
        let status = box.converter.convert(to: outputBuffer, error: &error) { _, statusPtr in
            if supplyState.supplied {
                statusPtr.pointee = .noDataNow
                return nil
            }
            supplyState.supplied = true
            statusPtr.pointee = .haveData
            return inputBuffer
        }

        if status == .error || error != nil { return nil }
        return outputBuffer
    }

    /// Average all input channels into a single mono Float32 buffer at the
    /// input sample rate. Mono passthrough is a memcpy. Multichannel arrays
    /// (PS Eye 4-mic, USB interfaces) get every capsule mixed in — averaging
    /// preserves peak headroom and reduces uncorrelated noise by √N.
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

    private static func extractInt16(from buffer: AVAudioPCMBuffer) -> [Int16] {
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0,
              let int16Pointer = buffer.int16ChannelData?.pointee
        else { return [] }
        return Array(UnsafeBufferPointer(start: int16Pointer, count: frameLength))
    }
}

// AVAudioConverter is not Sendable but is only ever touched from the tap's
// serial dispatch queue; the box keeps Swift 6 strict-concurrency happy.
private final class ConverterBox: @unchecked Sendable {
    let converter: AVAudioConverter
    let outputFormat: AVAudioFormat
    let monoInputFormat: AVAudioFormat

    init(converter: AVAudioConverter, outputFormat: AVAudioFormat, monoInputFormat: AVAudioFormat) {
        self.converter = converter
        self.outputFormat = outputFormat
        self.monoInputFormat = monoInputFormat
    }
}

// Single-call latch for the AVAudioConverter input block (which is invoked
// repeatedly until we return `.noDataNow`). A class lets the @Sendable
// converter callback mutate its flag without tripping strict-concurrency.
private final class SupplyState: @unchecked Sendable {
    var supplied = false
}

/// Per-capture state shared between the tap callback (CoreAudio's serial tap
/// queue) and the actor's `stop()`. The callback chunks samples here and
/// yields them itself, so frames reach the stream in capture order.
/// `drain()` lets `stop()` wait out a callback that was still running when
/// the tap was removed, so none of its frames land after the sentinel.
final class TapPipeline: @unchecked Sendable {
    private let lock = NSLock()
    private var chunker = Chunker()
    private var accepting = true
    private var inFlight = 0
    private var drainWaiter: CheckedContinuation<Void, Never>?

    /// Call at the top of each tap callback; `false` once draining started.
    /// A `true` result must be paired with `end()`.
    func begin() -> Bool {
        lock.withLock {
            guard accepting else { return false }
            inFlight += 1
            return true
        }
    }

    func chunk(_ samples: [Int16]) -> [[Int16]] {
        lock.withLock { chunker.ingest(samples) }
    }

    func end() {
        let waiter: CheckedContinuation<Void, Never>? = lock.withLock {
            inFlight -= 1
            guard inFlight == 0, let pending = drainWaiter else { return nil }
            drainWaiter = nil
            return pending
        }
        waiter?.resume()
    }

    /// Stop accepting callbacks and wait for any still running to finish.
    func drain() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let idle: Bool = lock.withLock {
                accepting = false
                if inFlight == 0 { return true }
                drainWaiter = cont
                return false
            }
            if idle { cont.resume() }
        }
    }
}

private final class ConversionStats: @unchecked Sendable {
    private let lock = NSLock()
    private var failures = 0
    private var drops = 0

    func recordFailure() -> Int {
        lock.lock(); defer { lock.unlock() }
        failures += 1
        return failures
    }

    func recordDrop() -> Int {
        lock.lock(); defer { lock.unlock() }
        drops += 1
        return drops
    }
}

#if os(macOS)
extension AVAudioCapture {
    fileprivate static func inputDeviceName(from audioUnit: AudioUnit) -> String? {
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            &size
        )
        guard status == noErr, deviceID != 0 else { return nil }

        var name: CFString = "" as CFString
        var nameSize = UInt32(MemoryLayout<CFString>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let nameStatus = AudioObjectGetPropertyData(
            deviceID, &address, 0, nil, &nameSize, &name
        )
        guard nameStatus == noErr else { return nil }
        return name as String
    }

    fileprivate static func systemDefaultInputDevice() -> AudioDeviceID {
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        return deviceID
    }
}
#endif
#endif
