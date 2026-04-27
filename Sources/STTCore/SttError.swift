import Foundation

public enum SttError: Error, Sendable {
    case authentication
    case rateLimit(retryAfter: Duration?)
    case transient(String)
    case fatal(String)
    case cancelled
}
