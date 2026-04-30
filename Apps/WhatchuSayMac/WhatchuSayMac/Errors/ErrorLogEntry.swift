import Foundation

/// One captured runtime error, retained for post-hoc debugging in the
/// menu-bar "Recent Errors" surface. Slim shape — text + timestamp.
/// Severity / fix-it / structured `AppError` can graduate later without
/// breaking on-disk compatibility (any new fields default at decode time).
struct ErrorLogEntry: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    let text: String
    let timestamp: Date

    init(id: UUID = UUID(), text: String, timestamp: Date = Date()) {
        self.id = id
        self.text = text
        self.timestamp = timestamp
    }
}
