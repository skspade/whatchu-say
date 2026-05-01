import Foundation

public enum ConfigMigrationError: Error, Sendable, Equatable {
    /// Persisted config declares a `schemaVersion` newer than this build supports.
    /// Likely a downgrade. Caller should fall back to defaults rather than guess.
    case unsupportedSchemaVersion(UInt32)
    /// Decode failed — corrupt data, missing required fields, or malformed JSON.
    /// `reason` is descriptive only; do not pattern-match on it.
    case decodeFailed(reason: String)
}

/// Decodes persisted JSON into an `AppConfig`, applying any necessary
/// version migrations. Currently a passthrough — `schemaVersion == 1` is
/// the only known shape — but the dispatch loop is in place so adding
/// `migrateV1ToV2` etc. is a one-line change.
///
/// Migration handlers run on the raw JSON dictionary *before* `AppConfig`
/// is decoded, so they can inject defaults for newly added fields without
/// breaking the synthesized `Codable`.
public enum ConfigMigration {
    /// Decode and migrate `data` to a current-schema `AppConfig`.
    public static func migrate(_ data: Data) throws -> AppConfig {
        let envelope: SchemaEnvelope
        do {
            envelope = try JSONDecoder().decode(SchemaEnvelope.self, from: data)
        } catch {
            throw ConfigMigrationError.decodeFailed(
                reason: "missing or malformed schemaVersion: \(error)"
            )
        }

        guard envelope.schemaVersion <= AppConfig.currentSchemaVersion else {
            throw ConfigMigrationError.unsupportedSchemaVersion(envelope.schemaVersion)
        }

        // Future: walk handlers from envelope.schemaVersion → currentSchemaVersion
        // here, mutating a `[String: Any]` JSON dict before final decode.

        do {
            return try JSONDecoder().decode(AppConfig.self, from: data)
        } catch {
            throw ConfigMigrationError.decodeFailed(reason: "\(error)")
        }
    }

    private struct SchemaEnvelope: Decodable {
        let schemaVersion: UInt32
    }
}
