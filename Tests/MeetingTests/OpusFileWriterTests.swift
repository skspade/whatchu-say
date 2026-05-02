import Testing
import Foundation
import AVFoundation
@testable import Meeting

@Suite("OpusFileWriter")
struct OpusFileWriterTests {
    @Test("writes a non-empty file")
    func writeSomething() throws {
        guard #available(macOS 15, *) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try OpusFileWriter(url: url, sampleRate: 16_000)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
        buffer.frameLength = 16_000
        try writer.append(buffer: buffer)
        try writer.close()

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = attrs[.size] as! Int
        #expect(size > 0)
    }
}
