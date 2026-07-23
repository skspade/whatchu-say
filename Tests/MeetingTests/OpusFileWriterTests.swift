import Testing
import Foundation
import AVFoundation
@testable import Meeting

@Suite("OpusFileWriter")
struct OpusFileWriterTests {
    @Test("writes a non-empty file from a mono 16kHz buffer")
    func writeMono() throws {
        guard #available(macOS 15, *) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try OpusFileWriter(url: url)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
        buffer.frameLength = 16_000
        try writer.append(buffer: buffer)
        try writer.close()

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = attrs[.size] as! Int
        #expect(size > 0)
    }

    @Test("writes a non-empty file from a stream of stereo 44.1kHz buffers")
    func writeStereoHardwareBuffers() throws {
        guard #available(macOS 15, *) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try OpusFileWriter(url: url)

        // Mirror what a real mic/system tap delivers: a stream of small stereo
        // 44.1 kHz Float32 buffers (the tap uses bufferSize 1024). The writer
        // must downmix + resample to its mono 16 kHz target.
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 2, interleaved: false)!
        let framesPerBuffer = AVAudioFrameCount(1024)
        var phase = 0
        for _ in 0..<200 {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesPerBuffer)!
            buffer.frameLength = framesPerBuffer
            for ch in 0..<Int(format.channelCount) {
                let data = buffer.floatChannelData![ch]
                for frame in 0..<Int(framesPerBuffer) {
                    data[frame] = sin(Float(phase + frame) * 0.05)
                }
            }
            phase += Int(framesPerBuffer)
            try writer.append(buffer: buffer)
        }
        try writer.close()

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = attrs[.size] as! Int
        #expect(size > 0)
        #expect(writer.writeFailureCount == 0)
    }
}
