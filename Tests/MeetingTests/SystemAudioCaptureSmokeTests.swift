import Testing
import Foundation
@testable import Meeting

@Suite("SystemAudioCapture", .disabled("manual: requires Screen & System Audio Recording permission + audio playing"))
struct SystemAudioCaptureSmokeTests {
    @Test("captures 200ms of system audio while audio plays")
    func roundtrip() async throws {
        guard #available(macOS 15, *) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("system-\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let cap = SystemAudioCapture(outputURL: url)
        try await cap.start()
        try await Task.sleep(for: .milliseconds(500))
        await cap.stop()
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int
        #expect(size > 1024)
    }
}
