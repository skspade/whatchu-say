#if canImport(AVFoundation)
import Foundation
@preconcurrency import AVFoundation

/// AVAudioEngine-backed `AudioCapturing`. Captures from the default input,
/// converts to 16 kHz mono Int16, re-chunks into 20 ms (320-sample) frames,
/// and emits both the frames and per-frame RMS (dBFS).
///
/// ## Pipeline
/// 1. `installTap` on the input bus, `tapBufferSize` samples per callback in
///    the device-native format.
/// 2. The tap callback runs on a serial CoreAudio dispatch queue. We convert
///    synchronously to our target format using a long-lived `AVAudioConverter`
///    (safe because the converter is only touched from this serial queue).
/// 3. The converted samples are handed to the actor via a Task so chunking,
///    RMS computation, and stream-yielding don't block the audio thread.
///
/// ## Backpressure
/// Both AsyncStreams use `bufferingNewest(64)` (~1.3 s of frames). If the
/// downstream consumer falls behind, oldest frames are dropped. We never
/// block the audio thread.
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

    private let rmsAnalyzer = RMSAnalyzer()
    private nonisolated let inFlightIngest = InFlightCounter()
    private var engine: AVAudioEngine?
    private var chunker = Chunker()
    private var startedAt: ContinuousClock.Instant?
    private var ingestDrainWaiter: CheckedContinuation<Void, Never>?

    private static let targetSampleRate: Double = 16_000
    private static let tapBufferSize: AVAudioFrameCount = 1024
    private static let streamBuffer: Int = 64

    public init() {
        let (fStream, fCont) = AsyncStream<AudioFrame>.makeStream(
            bufferingPolicy: .bufferingNewest(Self.streamBuffer)
        )
        let (rStream, rCont) = AsyncStream<Float>.makeStream(
            bufferingPolicy: .bufferingNewest(Self.streamBuffer)
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
        let inputFormat = input.inputFormat(forBus: 0)
        print("[AVAudioCapture] input format: \(inputFormat)")

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: true
        ) else {
            throw AudioCaptureError.formatUnsupported
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw AudioCaptureError.converterUnavailable
        }

        let box = ConverterBox(converter: converter, outputFormat: outputFormat)
        let captureRef = self

        chunker.reset()
        startedAt = .now

        let counter = inFlightIngest
        input.installTap(
            onBus: 0,
            bufferSize: Self.tapBufferSize,
            format: inputFormat
        ) { inputBuffer, _ in
            guard let outputBuffer = Self.convert(inputBuffer: inputBuffer, using: box) else {
                return
            }
            let samples = Self.extractInt16(from: outputBuffer)
            if samples.isEmpty { return }
            counter.increment()
            Task {
                await captureRef.ingest(samples: samples)
            }
        }

        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            startedAt = nil
            print("[AVAudioCapture] engine.start FAILED: \(error)")
            throw AudioCaptureError.engineStartFailed(String(describing: error))
        }

        print("[AVAudioCapture] engine started")
        self.engine = engine
    }

    public func stop() async {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        // Wait for any tap-spawned ingest Tasks to finish chunking and yielding
        // into the frames stream BEFORE we publish the end-of-session sentinel.
        // removeTap is synchronous, so no new ingest Tasks will be spawned past
        // this point — the counter only goes down from here.
        await awaitIngestDrain()
        chunker.reset()
        startedAt = nil
        // End-of-session sentinel: empty samples mark "all captured audio for
        // the just-ended session is now in the stream." Consumers (the
        // orchestrator's audio forwarder) use this to know when it's safe to
        // send `endOfStream` to the STT provider.
        framesContinuation.yield(AudioFrame(samples: [], timestamp: .zero))
    }

    /// Suspend until every in-flight ingest Task has yielded its chunks.
    /// Resumes immediately if the counter is already at zero.
    private func awaitIngestDrain() async {
        if inFlightIngest.current == 0 { return }
        await withCheckedContinuation { cont in
            ingestDrainWaiter = cont
        }
    }

    // MARK: - Ingest (actor-isolated)

    private func ingest(samples: [Int16]) async {
        let chunks = chunker.ingest(samples)
        let timestamp: Duration = startedAt.map { $0.duration(to: .now) } ?? .zero
        for chunk in chunks {
            framesContinuation.yield(AudioFrame(samples: chunk, timestamp: timestamp))
            let rms = await rmsAnalyzer.process(chunk)
            rmsContinuation.yield(rms)
        }
        let remaining = inFlightIngest.decrement()
        if remaining == 0, let cont = ingestDrainWaiter {
            ingestDrainWaiter = nil
            cont.resume()
        }
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

    init(converter: AVAudioConverter, outputFormat: AVAudioFormat) {
        self.converter = converter
        self.outputFormat = outputFormat
    }
}

// Single-call latch for the AVAudioConverter input block (which is invoked
// repeatedly until we return `.noDataNow`). A class lets the @Sendable
// converter callback mutate its flag without tripping strict-concurrency.
private final class SupplyState: @unchecked Sendable {
    var supplied = false
}

// Lock-protected counter shared between the audio tap (CoreAudio dispatch
// queue, sync) and the actor's `ingest` (async). The tap increments before
// spawning the ingest Task; ingest decrements after yielding its chunks.
final class InFlightCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock(); defer { lock.unlock() }
        count += 1
    }

    func decrement() -> Int {
        lock.lock(); defer { lock.unlock() }
        count -= 1
        return count
    }

    var current: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
}
#endif
