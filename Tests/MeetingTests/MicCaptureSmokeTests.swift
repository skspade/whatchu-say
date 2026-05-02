import Testing
import Foundation
@testable import Meeting

@Suite("MicCapture", .disabled("requires mic permission, manual run"))
struct MicCaptureSmokeTests {
    @Test("start/stop produces a file")
    func roundtrip() async throws {
        guard #available(macOS 15, *) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mic-\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let mic = MicCapture(outputURL: url)
        try await mic.start()
        try await Task.sleep(for: .milliseconds(200))
        await mic.stop()
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attrs[.size] as! Int) > 0)
    }
}
