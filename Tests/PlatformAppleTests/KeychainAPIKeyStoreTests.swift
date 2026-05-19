#if os(macOS)
import Testing
import Foundation
@testable import PlatformApple

/// Round-trip Keychain coverage. Each test uses a unique service name so
/// concurrent runs and stale entries from prior runs don't interfere — and
/// every test cleans up after itself.
@Suite("KeychainAPIKeyStore round-trip")
struct KeychainAPIKeyStoreTests {

    private func makeStore() -> (KeychainAPIKeyStore, String) {
        let service = "whatchu-say.tests.\(UUID().uuidString)"
        return (KeychainAPIKeyStore(service: service), service)
    }

    @Test("read returns nil for an unknown provider")
    func readMissing() async throws {
        let (store, _) = makeStore()
        try await #expect(store.read(provider: "elevenlabs") == nil)
    }

    @Test("write then read returns the same key")
    func writeRead() async throws {
        let (store, _) = makeStore()
        try await store.write(provider: "elevenlabs", key: "sk_abc123")
        try await #expect(store.read(provider: "elevenlabs") == "sk_abc123")
        try await store.delete(provider: "elevenlabs")
    }

    @Test("write overwrites a prior value")
    func overwrite() async throws {
        let (store, _) = makeStore()
        try await store.write(provider: "elevenlabs", key: "sk_old")
        try await store.write(provider: "elevenlabs", key: "sk_new")
        try await #expect(store.read(provider: "elevenlabs") == "sk_new")
        try await store.delete(provider: "elevenlabs")
    }

    @Test("delete removes the entry; subsequent read is nil")
    func deleteRemoves() async throws {
        let (store, _) = makeStore()
        try await store.write(provider: "elevenlabs", key: "sk_temp")
        try await store.delete(provider: "elevenlabs")
        try await #expect(store.read(provider: "elevenlabs") == nil)
    }

    @Test("delete on missing entry is a no-op")
    func deleteMissingIsNoOp() async throws {
        let (store, _) = makeStore()
        try await store.delete(provider: "elevenlabs")
    }

    @Test("entries are scoped per provider")
    func providerScoping() async throws {
        let (store, _) = makeStore()
        try await store.write(provider: "elevenlabs", key: "sk_eleven")
        try await store.write(provider: "openai", key: "sk_openai")
        try await #expect(store.read(provider: "elevenlabs") == "sk_eleven")
        try await #expect(store.read(provider: "openai") == "sk_openai")
        try await store.delete(provider: "elevenlabs")
        try await store.delete(provider: "openai")
    }

    // The delete-and-recreate recovery in `write` only triggers on a real
    // ACL/trust failure (an entry owned by a now-revoked code signature),
    // which can't be reproduced in-process. These cover the error surface
    // it falls back to.

    @Test("osStatus description is stable for the alert path")
    func osStatusDescription() {
        let error = KeychainAPIKeyStore.KeychainError.osStatus(-67820)
        #expect(error.description == "osStatus(-67820)")
        #expect(String(describing: error) == "osStatus(-67820)")
    }

    @Test("orphanedEntry surfaces an actionable message and is Equatable")
    func orphanedEntryMessage() {
        let error = KeychainAPIKeyStore.KeychainError.orphanedEntry(
            updateStatus: -67820,
            deleteStatus: -25300
        )
        #expect(error.description.contains("Keychain Access"))
        #expect(error.errorDescription == error.description)
        #expect(
            error == KeychainAPIKeyStore.KeychainError.orphanedEntry(
                updateStatus: -67820,
                deleteStatus: -25300
            )
        )
        #expect(
            error != KeychainAPIKeyStore.KeychainError.orphanedEntry(
                updateStatus: -67820,
                deleteStatus: -25291
            )
        )
    }
}
#endif
