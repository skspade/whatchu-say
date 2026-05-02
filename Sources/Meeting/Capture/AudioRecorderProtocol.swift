import Foundation

/// Protocol both `MicCapture` and `SystemAudioCapture` conform to. Lets the
/// orchestrator depend on an interface rather than the concrete actors,
/// which makes it testable without real audio hardware.
public protocol AudioRecorderProtocol: Sendable {
    func start() async throws
    func stop() async
}
