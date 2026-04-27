import Foundation

public enum SttEvent: Sendable {
    case partial(text: String, stability: Float)
    case final(text: String, alternatives: [String])
    case providerInfo(latencyMs: UInt32, model: String)
    case warning(String)
}
