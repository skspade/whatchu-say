import Foundation

public enum SttError: Error, Sendable, LocalizedError {
    case authentication
    case rateLimit(retryAfter: Duration?)
    case transient(String)
    case fatal(String)
    case cancelled

    /// Surface the embedded diagnostic string. Without this, `.fatal` /
    /// `.transient` collapse to Foundation's useless
    /// "(STTCore.SttError error 3.)" in logs and the error-log UI, hiding
    /// the only information that explains why a session failed.
    public var errorDescription: String? {
        switch self {
        case .authentication:
            return "Authentication failed — check the API key."
        case .rateLimit(let retryAfter):
            if let retryAfter {
                return "Rate limited — retry after \(retryAfter)."
            }
            return "Rate limited."
        case .transient(let message):
            return "Transient error: \(message)"
        case .fatal(let message):
            return message
        case .cancelled:
            return "Cancelled."
        }
    }
}
