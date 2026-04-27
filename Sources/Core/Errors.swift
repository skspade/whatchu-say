import Foundation

public enum AppError: Error, Sendable {
    case info(String)
    case warning(String)
    case error(String)
}
