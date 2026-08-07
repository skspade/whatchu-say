import AVFoundation
import Foundation
import Speech
import STTCore

/// One Apple SpeechAnalyzer session. Two transcribers share the same analyzer:
/// a progressive one drives the HUD and a final-only one supplies committed
/// text. Keeping them separate prevents a volatile phrase that becomes final
/// without being reissued from being lost by the generic STT event contract.
@available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
public actor AppleSpeechSession: SttSession {
    public nonisolated let events: AsyncStream<SttEvent>
    private nonisolated let eventsContinuation: AsyncStream<SttEvent>.Continuation

    private let analyzer: SpeechAnalyzer
    private let progressiveTranscriber: SpeechTranscriber
    private let finalTranscriber: SpeechTranscriber
    private let inputFormat: AVAudioFormat
    private let context: AnalysisContext
    private let inputSequence: AsyncStream<AnalyzerInput>
    private let inputContinuation: AsyncStream<AnalyzerInput>.Continuation

    private var progressiveTask: Task<Void, Never>?
    private var finalTask: Task<Void, Never>?
    private var closed = false
    private var endRequested = false
    private var finishedResultStreams = 0

    init(
        progressiveTranscriber: SpeechTranscriber,
        finalTranscriber: SpeechTranscriber,
        inputFormat: AVAudioFormat,
        context: AnalysisContext
    ) {
        self.progressiveTranscriber = progressiveTranscriber
        self.finalTranscriber = finalTranscriber
        self.inputFormat = inputFormat
        self.context = context
        self.analyzer = SpeechAnalyzer(modules: [progressiveTranscriber, finalTranscriber])

        let (inputSequence, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.inputSequence = inputSequence
        self.inputContinuation = inputContinuation

        let (eventStream, eventContinuation) = AsyncStream<SttEvent>.makeStream()
        self.events = eventStream
        self.eventsContinuation = eventContinuation
    }

    /// Starts the result consumers before the analyzer so no early result can
    /// be missed while the first audio buffer is arriving.
    func start() async throws {
        startResultConsumers()
        do {
            try await analyzer.setContext(context)
            try await analyzer.prepareToAnalyze(in: inputFormat)
            try await analyzer.start(inputSequence: inputSequence)
        } catch {
            await close()
            throw SttError.fatal(error.localizedDescription)
        }
    }

    public func pushAudio(_ samples: [Int16]) async throws {
        guard !closed, !endRequested else { throw SttError.cancelled }
        guard !samples.isEmpty else { return }

        let buffer = try Self.makeBuffer(samples: samples, format: inputFormat)
        inputContinuation.yield(AnalyzerInput(buffer: buffer))
    }

    public func endOfStream() async throws {
        guard !closed, !endRequested else { return }
        endRequested = true
        inputContinuation.finish()

        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            eventsContinuation.yield(.warning("Apple Speech finalization failed: \(error.localizedDescription)"))
            await close()
            throw SttError.fatal(error.localizedDescription)
        }

        await waitForResultConsumers()
        finishEvents()
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        inputContinuation.finish()
        progressiveTask?.cancel()
        finalTask?.cancel()
        progressiveTask = nil
        finalTask = nil
        await analyzer.cancelAndFinishNow()
        finishEvents()
    }

    static func makeBuffer(samples: [Int16], format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ), let destination = buffer.int16ChannelData?[0]
        else {
            throw SttError.fatal("failed to allocate Apple Speech audio buffer")
        }

        for (index, sample) in samples.enumerated() {
            destination[index] = sample
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        return buffer
    }

    private func startResultConsumers() {
        progressiveTask = Task { [weak self] in
            await self?.consumeProgressiveResults()
        }
        finalTask = Task { [weak self] in
            await self?.consumeFinalResults()
        }
    }

    private func consumeProgressiveResults() async {
        do {
            for try await result in progressiveTranscriber.results {
                guard !Task.isCancelled else { return }
                guard !result.isFinal else { continue }
                eventsContinuation.yield(
                    .partial(
                        text: String(result.text.characters),
                        stability: 0.5
                    )
                )
            }
        } catch is CancellationError {
            return
        } catch {
            await handleResultError(error)
            return
        }
        resultConsumerFinished()
    }

    private func consumeFinalResults() async {
        do {
            for try await result in finalTranscriber.results {
                guard !Task.isCancelled else { return }
                let alternatives = result.alternatives.dropFirst().map {
                    String($0.characters)
                }
                eventsContinuation.yield(
                    .final(text: String(result.text.characters), alternatives: alternatives)
                )
            }
        } catch is CancellationError {
            return
        } catch {
            await handleResultError(error)
            return
        }
        resultConsumerFinished()
    }

    private func handleResultError(_ error: Error) async {
        guard !closed else { return }
        eventsContinuation.yield(.warning("Apple Speech failed: \(error.localizedDescription)"))
        await close()
    }

    private func resultConsumerFinished() {
        finishedResultStreams += 1
        if finishedResultStreams == 2, !closed {
            finishEvents()
        }
    }

    private func waitForResultConsumers() async {
        if let progressiveTask {
            await progressiveTask.value
        }
        if let finalTask {
            await finalTask.value
        }
        progressiveTask = nil
        finalTask = nil
    }

    private func finishEvents() {
        eventsContinuation.finish()
    }
}
