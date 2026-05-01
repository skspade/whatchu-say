import Testing
import Foundation
@testable import Core

@Suite("ProviderRegistry")
struct ProviderRegistryTests {
    @Test("Registry is non-empty")
    func nonEmpty() {
        #expect(!ProviderRegistry.known.isEmpty)
    }

    @Test("ElevenLabs is registered with the expected identifier and URL")
    func elevenlabsEntry() {
        let info = ProviderRegistry.elevenlabs
        #expect(info.identifier == "elevenlabs")
        #expect(info.displayName == "ElevenLabs")
        #expect(info.dataPolicyURL.scheme == "https")
        #expect(info.dataPolicyURL.host == "elevenlabs.io")
    }

    @Test("Lookup by identifier returns the matching entry")
    func lookupKnown() {
        let info = ProviderRegistry.info(for: "elevenlabs")
        #expect(info == ProviderRegistry.elevenlabs)
    }

    @Test("Lookup of unknown identifier returns nil")
    func lookupUnknown() {
        #expect(ProviderRegistry.info(for: "made-up-provider") == nil)
    }

    @Test("Default ProviderConfig identifier resolves against the registry")
    func defaultConfigResolves() {
        let config = ProviderConfig()
        #expect(ProviderRegistry.info(for: config.providerName) != nil)
    }

    @Test("Identifiers in the registry are unique")
    func identifiersUnique() {
        let ids = ProviderRegistry.known.map(\.identifier)
        #expect(Set(ids).count == ids.count)
    }
}
