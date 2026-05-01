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
}
