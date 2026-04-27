import Foundation

public protocol SttSession: Sendable {
    func pushAudio(_ samples: [Int16]) async throws
    func endOfStream() async throws
    var events: AsyncStream<SttEvent> { get }
    func close() async
}
