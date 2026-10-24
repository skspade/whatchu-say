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

    @Test("downmixes multi-channel Float32 buffers into the mono file", arguments: [2, 4])
    func writeMultiChannel(channels: Int) throws {
        guard #available(macOS 15, *) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try OpusFileWriter(url: url, sampleRate: 48_000)
        let buffer = try Self.tone(channels: channels, sampleRate: 48_000, frames: 4_800)
        for _ in 0..<10 {
            try writer.append(buffer: buffer)
        }
        try writer.close()

        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int
        #expect(size > 0)
        #expect(try AVAudioFile(forReading: url).length > 0)
    }

    @Test("downmixes and resamples when the buffer rate differs from the file's")
    func writeResampled() throws {
        guard #available(macOS 15, *) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try OpusFileWriter(url: url, sampleRate: 16_000)
        let buffer = try Self.tone(channels: 2, sampleRate: 48_000, frames: 4_800)
        for _ in 0..<10 {
            try writer.append(buffer: buffer)
        }
        try writer.close()

        #expect(try AVAudioFile(forReading: url).length > 0)
    }

    /// Deinterleaved Float32 buffer with a 440 Hz sine on every channel, like
    /// a tap on a stereo or multi-mic device. Formats with more than two
    /// channels need an explicit channel layout.
    private static func tone(channels: Int, sampleRate: Double, frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        let layout: AVAudioChannelLayout? = AVAudioChannelLayout(
            layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | AudioChannelLayoutTag(channels)
        )
        let channelLayout = try #require(layout)
        let format: AVAudioFormat? = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            interleaved: false,
            channelLayout: channelLayout
        )
        let pcmFormat = try #require(format)
        #expect(pcmFormat.channelCount == AVAudioChannelCount(channels))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: frames))
        buffer.frameLength = frames

        let data = try #require(buffer.floatChannelData)
        let step = 2 * Float.pi * 440 / Float(sampleRate)
        for ch in 0..<channels {
            for i in 0..<Int(frames) {
                data[ch][i] = 0.5 * sin(step * Float(i))
            }
        }
        return buffer
    }
}
