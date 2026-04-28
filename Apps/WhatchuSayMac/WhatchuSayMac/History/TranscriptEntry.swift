import Foundation

/// One captured transcript ready to be re-pasted from the menu. Slim shape:
/// the full Milestone 1.5 history schema (TECH_SPEC §9.3) is a superset and
/// migration fills missing fields with defaults.
struct TranscriptEntry: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    let text: String
    let timestamp: Date

    init(id: UUID = UUID(), text: String, timestamp: Date = Date()) {
        self.id = id
        self.text = text
        self.timestamp = timestamp
    }
}
