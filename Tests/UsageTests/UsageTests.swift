import Testing
@testable import Usage

@Suite("Usage smoke")
struct UsageSmokeTests {
    @Test("tracker records sessions and reports snapshot")
    func recordAndSnapshot() async {
        let tracker = UsageTracker()
        await tracker.recordSession(durationMs: 1_000, provider: "mock")
        await tracker.recordSession(durationMs: 3_000, provider: "mock")
        let snapshot = await tracker.snapshot()
        #expect(snapshot.sessionCount == 2)
        #expect(snapshot.totalSeconds == 4)
    }
}
