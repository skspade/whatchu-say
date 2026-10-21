import Testing
@testable import Audio

@Suite("RMSAnalyzer")
struct RMSAnalyzerTests {
    @Test("returns -60 for empty input")
    func rmsEmptyInput() async {
        let analyzer = RMSAnalyzer()
        let result = await analyzer.process([])
        #expect(result == -60)
    }

    @Test("returns ~0 dBFS for full-scale input")
    func rmsFullScale() async {
        let analyzer = RMSAnalyzer()
        let samples = [Int16](repeating: Int16.max, count: 320)
        let result = await analyzer.process(samples)
        #expect(result >= -1)
    }
}

@Suite("Chunker")
struct ChunkerTests {
    @Test("emits exact frame from exact input")
    func exactFrame() {
        var chunker = Chunker(frameSize: 320)
        let frames = chunker.ingest([Int16](repeating: 1, count: 320))
        #expect(frames.count == 1)
        #expect(frames[0].count == 320)
        #expect(chunker.pendingCount == 0)
    }

    @Test("retains leftover samples when below frame size")
    func partialInput() {
        var chunker = Chunker(frameSize: 320)
        let frames = chunker.ingest([Int16](repeating: 1, count: 200))
        #expect(frames.isEmpty)
        #expect(chunker.pendingCount == 200)
    }

    @Test("emits multiple frames from a large input and keeps remainder")
    func multipleFrames() {
        var chunker = Chunker(frameSize: 320)
        let frames = chunker.ingest([Int16](repeating: 1, count: 1024))
        #expect(frames.count == 3)
        for frame in frames { #expect(frame.count == 320) }
        #expect(chunker.pendingCount == 1024 - 3 * 320)
    }

    @Test("accumulates samples across calls")
    func multipleCalls() {
        var chunker = Chunker(frameSize: 320)
        _ = chunker.ingest([Int16](repeating: 1, count: 200))
        let frames = chunker.ingest([Int16](repeating: 2, count: 200))
        #expect(frames.count == 1)
        #expect(frames[0].count == 320)
        // First 200 are 1s, next 120 are 2s, leftover 80 are 2s.
        #expect(frames[0].prefix(200).allSatisfy { $0 == 1 })
        #expect(frames[0].suffix(120).allSatisfy { $0 == 2 })
        #expect(chunker.pendingCount == 80)
    }

    @Test("reset clears any pending leftover")
    func resetClearsBuffer() {
        var chunker = Chunker(frameSize: 320)
        _ = chunker.ingest([Int16](repeating: 1, count: 200))
        chunker.reset()
        #expect(chunker.pendingCount == 0)
        let frames = chunker.ingest([Int16](repeating: 9, count: 320))
        #expect(frames.count == 1)
        #expect(frames[0].allSatisfy { $0 == 9 })
    }

    @Test("empty input is a no-op")
    func emptyInput() {
        var chunker = Chunker(frameSize: 320)
        let frames = chunker.ingest([])
        #expect(frames.isEmpty)
        #expect(chunker.pendingCount == 0)
    }
}

@Suite("RMSAnalyzer.level")
struct RMSLevelTests {
    @Test("static level matches the actor's process")
    func staticMatchesActor() async {
        let samples = (0..<320).map { Int16(truncatingIfNeeded: $0 * 97) }
        let viaActor = await RMSAnalyzer().process(samples)
        #expect(RMSAnalyzer.level(samples) == viaActor)
        #expect(RMSAnalyzer.level([]) == -60)
    }
}

#if canImport(AVFoundation)
@Suite("TapPipeline")
struct TapPipelineTests {
    @Test("chunks across callbacks in order, keeping the remainder")
    func chunksInOrder() {
        let pipeline = TapPipeline()
        #expect(pipeline.begin())
        let first = pipeline.chunk((0..<500).map { Int16($0) })
        pipeline.end()
        #expect(pipeline.begin())
        let second = pipeline.chunk((500..<700).map { Int16($0) })
        pipeline.end()

        #expect(first.count == 1)
        #expect(second.count == 1)
        #expect((first + second).flatMap { $0 } == (0..<640).map { Int16($0) })
    }

    @Test("drain returns immediately when no callback is running, then rejects new ones")
    func drainWhenIdle() async {
        let pipeline = TapPipeline()
        await pipeline.drain()
        #expect(!pipeline.begin())
    }

    @Test("drain waits for a callback that is still running", .timeLimit(.minutes(1)))
    func drainWaitsForInFlightCallback() async {
        let pipeline = TapPipeline()
        #expect(pipeline.begin())

        let drained = Task { await pipeline.drain() }
        // Give drain() a chance to register as the waiter. (If it hasn't by
        // the time end() runs, it finds the pipeline idle — either order
        // must complete.)
        for _ in 0..<100 { await Task.yield() }
        pipeline.end()
        await drained.value
        #expect(!pipeline.begin())
    }
}
#endif
