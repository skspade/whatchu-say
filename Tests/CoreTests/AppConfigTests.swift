import Testing
import Foundation
@testable import Core

@Suite("AppConfig: defaults")
struct AppConfigDefaultsTests {
    @Test("Fresh AppConfig matches the spec'd defaults")
    func freshDefaults() {
        let config = AppConfig()

        #expect(config.schemaVersion == 3)

        #expect(config.provider.providerName == "elevenlabs")
        #expect(config.provider.model == nil)
        #expect(config.provider.language == nil)
        #expect(config.provider.hints == [])
        #expect(config.provider.noVerbatim == false)

        #expect(config.hotkey.keyCode == 0x3D)              // right Option
        #expect(config.hotkey.modifiers == [])
        #expect(config.hotkey.cancelKeyCode == 0x35)        // Escape
        #expect(config.hotkey.cancelModifiers == [])
        #expect(config.hotkey.pressHoldThresholdMs == 250)
        #expect(config.hotkey.doubleTapWindowMs == 300)

        #expect(config.injection.defaultStrategy == .auto)
        #expect(config.injection.typeMaxCharsForAuto == 8)
        #expect(config.injection.terminalAllowlist == [])
        #expect(config.injection.perAppOverrides == [:])
        #expect(config.injection.leaveOnClipboard == false)

        #expect(config.startup.launchAtLogin == false)

        #expect(config.history.enabled == true)
        #expect(config.history.retentionDays == 30)
        #expect(config.history.maxEntries == 1000)

        #expect(config.usage.menubarIndicator == .off)
        #expect(config.usage.monthlyAlertThresholdMinutes == nil)

        #expect(config.overlay.enabled == true)
        #expect(config.overlay.anchor == .nearCursor)
        #expect(config.overlay.screenAnchorScreen == nil)

        #expect(config.privacy.hasReadDisclosure == false)
        #expect(config.privacy.disclosureAcknowledgedAt == nil)

        #expect(config.meetings.showAttendeeFieldAtStart == true)
        #expect(config.meetings.showConsentReminder == true)
        #expect(config.meetings.deleteAudioAfterTranscription == true)
    }
}

@Suite("AppConfig: codable round-trip")
struct AppConfigCodableTests {
    @Test("Default config round-trips losslessly")
    func defaultsRoundTrip() throws {
        let original = AppConfig()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded == original)
    }

    @Test("Heavily customised config round-trips losslessly")
    func customRoundTrip() throws {
        let original = AppConfig(
            provider: ProviderConfig(
                providerName: "deepgram",
                model: "nova-2",
                language: "en-US",
                hints: ["whatchu", "say"]
            ),
            hotkey: HotkeyConfig(
                keyCode: 0x66,
                modifiers: [.command, .shift],
                cancelKeyCode: 0x35,
                cancelModifiers: [.option],
                pressHoldThresholdMs: 200,
                doubleTapWindowMs: 350
            ),
            injection: InjectionConfig(
                defaultStrategy: .paste,
                typeMaxCharsForAuto: 12,
                terminalAllowlist: ["com.example.term"],
                perAppOverrides: [
                    "com.apple.Terminal": .paste,
                    "com.apple.Notes": .type,
                ],
                leaveOnClipboard: true
            ),
            startup: StartupConfig(launchAtLogin: true),
            history: HistoryConfig(enabled: false, retentionDays: 7, maxEntries: 100),
            usage: UsageConfig(menubarIndicator: .cost, monthlyAlertThresholdMinutes: 600),
            overlay: OverlayConfig(
                enabled: false,
                anchor: .screenBottom,
                screenAnchorScreen: "ABCD-1234"
            ),
            privacy: PrivacyConfig(
                hasReadDisclosure: true,
                disclosureAcknowledgedAt: Date(timeIntervalSinceReferenceDate: 12_345_678)
            )
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded == original)
    }

    @Test("Encoded JSON contains schemaVersion at the top level")
    func schemaVersionInJSON() throws {
        let data = try JSONEncoder().encode(AppConfig())
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["schemaVersion"] as? UInt32 == 3)
    }
}

@Suite("ModifierSet: OptionSet semantics")
struct ModifierSetTests {
    @Test("Empty set has rawValue 0")
    func emptyRaw() {
        #expect(ModifierSet().rawValue == 0)
        #expect(ModifierSet([]).rawValue == 0)
    }

    @Test("Combined modifiers OR their bits")
    func combinedRaw() {
        let combo: ModifierSet = [.command, .shift]
        #expect(combo.contains(.command))
        #expect(combo.contains(.shift))
        #expect(!combo.contains(.option))
        #expect(combo.rawValue == ModifierSet.command.rawValue | ModifierSet.shift.rawValue)
    }

    @Test("Codable round-trip preserves bits")
    func codableRoundTrip() throws {
        let original: ModifierSet = [.control, .option, .function]
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ModifierSet.self, from: data)
        #expect(decoded == original)
    }
}
