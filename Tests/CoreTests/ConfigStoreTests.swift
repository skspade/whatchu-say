import Testing
import Foundation
@testable import Core

@MainActor
@Suite("ConfigStore: load")
struct ConfigStoreLoadTests {
    @Test("Empty persistence yields default config")
    func emptyLoad() {
        let persistence = InMemoryConfigPersistence()
        let store = ConfigStore(persistence: persistence)
        #expect(store.config == AppConfig())
    }

    @Test("Empty persistence persists defaults so subsequent load matches")
    func emptyLoadPersistsDefaults() throws {
        let persistence = InMemoryConfigPersistence()
        _ = ConfigStore(persistence: persistence)

        let saved = persistence.snapshot
        #expect(saved != nil)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: saved!)
        #expect(decoded == AppConfig())
    }

    @Test("Pre-existing valid config is loaded as-is")
    func loadExisting() throws {
        var seed = AppConfig()
        seed.startup.launchAtLogin = true
        seed.usage.menubarIndicator = .minutes
        let data = try JSONEncoder().encode(seed)

        let persistence = InMemoryConfigPersistence(initial: data)
        let store = ConfigStore(persistence: persistence)
        #expect(store.config == seed)
    }

    @Test("Corrupt persistence falls back to defaults and overwrites the bad blob")
    func corruptLoad() throws {
        let persistence = InMemoryConfigPersistence(initial: "garbage".data(using: .utf8))
        let store = ConfigStore(persistence: persistence)
        #expect(store.config == AppConfig())

        let saved = persistence.snapshot
        #expect(saved != nil)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: saved!)
        #expect(decoded == AppConfig())
    }

    @Test("Future schema version falls back to defaults rather than crashing")
    func futureSchemaLoad() {
        let json = #"{"schemaVersion": 99}"#.data(using: .utf8)
        let persistence = InMemoryConfigPersistence(initial: json)
        let store = ConfigStore(persistence: persistence)
        #expect(store.config == AppConfig())
    }
}

@MainActor
@Suite("ConfigStore: update + persist")
struct ConfigStoreUpdateTests {
    @Test("Update mutates in-memory config immediately")
    func updateInMemory() {
        let store = ConfigStore(persistence: InMemoryConfigPersistence())
        store.update { $0.startup.launchAtLogin = true }
        #expect(store.config.startup.launchAtLogin == true)
    }

    @Test("Debounced save reaches persistence after the debounce window")
    func debouncedSave() async throws {
        let persistence = InMemoryConfigPersistence()
        let store = ConfigStore(persistence: persistence, saveDebounce: .milliseconds(20))

        store.update { $0.usage.menubarIndicator = .cost }

        // Wait past the debounce window with a small margin.
        try await Task.sleep(for: .milliseconds(80))

        let saved = persistence.snapshot
        #expect(saved != nil)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: saved!)
        #expect(decoded.usage.menubarIndicator == .cost)
    }

    @Test("Coalesced updates only persist the latest snapshot")
    func coalescedUpdates() async throws {
        let persistence = InMemoryConfigPersistence()
        let store = ConfigStore(persistence: persistence, saveDebounce: .milliseconds(50))

        store.update { $0.history.retentionDays = 10 }
        store.update { $0.history.retentionDays = 20 }
        store.update { $0.history.retentionDays = 30 }

        try await Task.sleep(for: .milliseconds(150))

        let decoded = try JSONDecoder().decode(AppConfig.self, from: persistence.snapshot!)
        #expect(decoded.history.retentionDays == 30)
    }

    @Test("Flush persists immediately and cancels the pending debounce")
    func flushImmediate() throws {
        let persistence = InMemoryConfigPersistence()
        let store = ConfigStore(persistence: persistence, saveDebounce: .seconds(60))

        store.update { $0.privacy.hasReadDisclosure = true }
        store.flush()

        let decoded = try JSONDecoder().decode(AppConfig.self, from: persistence.snapshot!)
        #expect(decoded.privacy.hasReadDisclosure == true)
    }
}
