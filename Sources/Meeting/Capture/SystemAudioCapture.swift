#if canImport(AudioToolbox) && os(macOS)
import Foundation
import CoreAudio
import AudioToolbox
@preconcurrency import AVFoundation

@available(macOS 15, *)
public actor SystemAudioCapture: AudioRecorderProtocol {
    private let outputURL: URL
    private var tapId: AudioObjectID = 0
    private var aggregateId: AudioObjectID = 0
    private var engine: AVAudioEngine?
    private var sink: TapFileSink?

    public init(outputURL: URL) {
        self.outputURL = outputURL
    }

    public func start() async throws {
        guard tapId == 0 else { return }

        // Create a global stereo Process Tap (unmuted) that captures every
        // process's output. The list is processes to *exclude*, so empty means
        // all of them; `stereoMixdownOfProcesses:` would instead tap only the
        // listed processes, and an empty list there captures silence.
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.muteBehavior = .unmuted
        description.isPrivate = true
        description.name = "whatchu-say-meeting-tap"

        var tap: AudioObjectID = 0
        let status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { throw MeetingError.systemAudioPermissionDenied(status: status) }
        tapId = tap

        // Wrap the tap in an aggregate device so AVAudioEngine can read it.
        let tapUID = tap.tapUIDString
        let aggregateUID = "whatchu-say-aggregate-\(UUID().uuidString)"
        let dict: [String: Any] = [
            kAudioAggregateDeviceUIDKey as String: aggregateUID,
            kAudioAggregateDeviceNameKey as String: "WhatchuSayMeetingAggregate",
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceTapListKey as String: [
                [kAudioSubTapUIDKey as String: tapUID],
            ],
        ]
        var agg: AudioObjectID = 0
        let aggStatus = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &agg)
        guard aggStatus == noErr else { throw MeetingError.systemAudioPermissionDenied(status: aggStatus) }
        aggregateId = agg

        // Hook AVAudioEngine to the aggregate device and tap its output.
        let engine = AVAudioEngine()
        let input = engine.inputNode
        try input.auAudioUnit.setDeviceID(agg)
        let inputFormat = input.inputFormat(forBus: 0)
        let writer = try OpusFileWriter(url: outputURL, sampleRate: inputFormat.sampleRate)
        let sink = TapFileSink(writer: writer)
        self.engine = engine
        self.sink = sink

        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
            sink.append(buffer)
        }
        try engine.start()
    }

    public func stop() async {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        sink?.close()
        sink = nil
        if aggregateId != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateId)
            aggregateId = 0
        }
        if tapId != 0 {
            AudioHardwareDestroyProcessTap(tapId)
            tapId = 0
        }
    }
}

private extension AudioObjectID {
    var tapUIDString: String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString>.size)
        var uid: Unmanaged<CFString>?
        AudioObjectGetPropertyData(self, &address, 0, nil, &size, &uid)
        return uid?.takeRetainedValue() as String? ?? ""
    }
}
#endif
