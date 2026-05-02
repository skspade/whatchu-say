import Testing
import Foundation
@testable import Core

@Suite("ConfigMigration")
struct ConfigMigrationTests {
    @Test("Valid v1 JSON decodes to AppConfig")
    func validV1() throws {
        let original = AppConfig()
        let data = try JSONEncoder().encode(original)
        let migrated = try ConfigMigration.migrate(data)
        #expect(migrated == original)
    }

    @Test("Future schema version throws unsupportedSchemaVersion")
    func futureSchema() throws {
        let json = #"{"schemaVersion": 99}"#.data(using: .utf8)!
        do {
            _ = try ConfigMigration.migrate(json)
            Issue.record("expected unsupportedSchemaVersion to throw")
        } catch let error as ConfigMigrationError {
            #expect(error == .unsupportedSchemaVersion(99))
        }
    }

    @Test("Garbage JSON throws decodeFailed")
    func garbage() throws {
        let bad = "not json".data(using: .utf8)!
        do {
            _ = try ConfigMigration.migrate(bad)
            Issue.record("expected decodeFailed to throw")
        } catch let error as ConfigMigrationError {
            if case .decodeFailed = error {
                // expected
            } else {
                Issue.record("expected decodeFailed, got \(error)")
            }
        }
    }

    @Test("JSON missing schemaVersion throws decodeFailed")
    func missingSchemaVersion() throws {
        let bad = #"{"provider": {"providerName": "elevenlabs", "hints": []}}"#.data(using: .utf8)!
        do {
            _ = try ConfigMigration.migrate(bad)
            Issue.record("expected decodeFailed to throw")
        } catch let error as ConfigMigrationError {
            if case .decodeFailed = error {
                // expected
            } else {
                Issue.record("expected decodeFailed, got \(error)")
            }
        }
    }

    @Test("Valid envelope but incomplete AppConfig throws decodeFailed")
    func envelopeButIncompleteConfig() throws {
        // Has schemaVersion, but missing all the required sub-configs.
        let bad = #"{"schemaVersion": 1}"#.data(using: .utf8)!
        do {
            _ = try ConfigMigration.migrate(bad)
            Issue.record("expected decodeFailed to throw")
        } catch let error as ConfigMigrationError {
            if case .decodeFailed = error {
                // expected
            } else {
                Issue.record("expected decodeFailed, got \(error)")
            }
        }
    }

    @Test("v1 JSON migrates to v2 by injecting default meetings")
    func migrateV1ToV2() throws {
        // Hand-crafted v1 JSON: schemaVersion=1, no meetings field, all other
        // sub-configs at their defaults. We round-trip a default AppConfig but
        // strip both schemaVersion → 1 and the meetings field, so the migration
        // path runs.
        let defaultConfig = AppConfig()
        var dict = try JSONSerialization.jsonObject(with: JSONEncoder().encode(defaultConfig)) as! [String: Any]
        dict["schemaVersion"] = 1
        dict.removeValue(forKey: "meetings")
        let v1Data = try JSONSerialization.data(withJSONObject: dict)

        let migrated = try ConfigMigration.migrate(v1Data)
        #expect(migrated.schemaVersion == AppConfig.currentSchemaVersion)
        #expect(migrated.meetings.showAttendeeFieldAtStart == true)
        #expect(migrated.meetings.showConsentReminder == true)
        #expect(migrated.meetings.deleteAudioAfterTranscription == true)
    }

    @Test("v2 JSON with explicit meetings preserved")
    func v2Preserved() throws {
        var config = AppConfig()
        config.meetings.deleteAudioAfterTranscription = false
        let data = try JSONEncoder().encode(config)
        let migrated = try ConfigMigration.migrate(data)
        #expect(migrated.meetings.deleteAudioAfterTranscription == false)
    }
}
