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
/// version migrations. Walks migration handlers from the persisted
/// `schemaVersion` up to `AppConfig.currentSchemaVersion`, mutating the
/// raw JSON dict before final decode so newly added required fields get
/// injected with defaults.
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

        // Walk handlers from envelope.schemaVersion → currentSchemaVersion.
        // Each handler mutates the raw JSON dict, then we re-encode and decode.
        var working: [String: Any]
        do {
            guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ConfigMigrationError.decodeFailed(reason: "top-level JSON is not an object")
            }
            working = dict
        } catch let e as ConfigMigrationError {
            throw e
        } catch {
            throw ConfigMigrationError.decodeFailed(reason: "\(error)")
        }

        if envelope.schemaVersion < 2 {
            migrateV1ToV2(&working)
        }
        working["schemaVersion"] = AppConfig.currentSchemaVersion

        let migrated: Data
        do {
            migrated = try JSONSerialization.data(withJSONObject: working)
        } catch {
            throw ConfigMigrationError.decodeFailed(reason: "re-serialize after migration: \(error)")
        }

        do {
            return try JSONDecoder().decode(AppConfig.self, from: migrated)
        } catch {
            throw ConfigMigrationError.decodeFailed(reason: "\(error)")
        }
    }

    private static func migrateV1ToV2(_ dict: inout [String: Any]) {
        if dict["meetings"] == nil {
            dict["meetings"] = [
                "showAttendeeFieldAtStart": true,
                "showConsentReminder": true,
                "deleteAudioAfterTranscription": true,
            ]
        }
    }

    private struct SchemaEnvelope: Decodable {
        let schemaVersion: UInt32
    }
}
