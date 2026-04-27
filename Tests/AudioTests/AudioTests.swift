import Testing
@testable import Audio

@Suite("Audio smoke")
struct AudioSmokeTests {
    @Test("RMSAnalyzer returns -60 for empty input")
    func rmsEmptyInput() async {
        let analyzer = RMSAnalyzer()
        let result = await analyzer.process([])
        #expect(result == -60)
    }

    @Test("RMSAnalyzer returns 0 dBFS for full-scale input")
    func rmsFullScale() async {
        let analyzer = RMSAnalyzer()
        let samples = [Int16](repeating: Int16.max, count: 320)
        let result = await analyzer.process(samples)
        #expect(result >= -1)
    }
}
