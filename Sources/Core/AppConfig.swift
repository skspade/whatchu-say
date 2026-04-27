import Foundation

/// Top-level user configuration for whatchu-say.
///
/// The schema is versioned (`schemaVersion`) so persisted configs can be migrated
/// across releases via `ConfigMigration`. Concrete sub-schemas (provider, hotkey,
/// injection, etc.) are added in later milestones.
public struct AppConfig: Codable, Sendable {
    public static let currentSchemaVersion: UInt32 = 1

    public var schemaVersion: UInt32

    public init(schemaVersion: UInt32 = AppConfig.currentSchemaVersion) {
        self.schemaVersion = schemaVersion
    }
}
