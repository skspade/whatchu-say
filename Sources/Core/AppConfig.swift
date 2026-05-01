import Foundation

/// Top-level user configuration for whatchu-say.
///
/// Mirrors the schema defined in `docs/TECH_SPEC.md` §9.2. The schema is
/// versioned (`schemaVersion`) so persisted configs can be migrated across
/// releases via `ConfigMigration`.
///
/// Conventions:
/// - Every field has a sensible default supplied by the type's `init`, so a
///   fresh user gets a working config on first launch.
/// - All persisted enums are raw-string-backed for human-readable JSON.
/// - The synthesized `Codable` requires every field to be present on decode.
///   When v2 lands, migration handlers run *before* `JSONDecoder` to inject
///   defaults for new fields.
public struct AppConfig: Codable, Sendable, Equatable {
    public static let currentSchemaVersion: UInt32 = 1

    public var schemaVersion: UInt32
    public var provider: ProviderConfig
    public var hotkey: HotkeyConfig
    public var injection: InjectionConfig
    public var startup: StartupConfig
    public var history: HistoryConfig
    public var usage: UsageConfig
    public var overlay: OverlayConfig
    public var privacy: PrivacyConfig

    public init(
        schemaVersion: UInt32 = AppConfig.currentSchemaVersion,
        provider: ProviderConfig = ProviderConfig(),
        hotkey: HotkeyConfig = HotkeyConfig(),
        injection: InjectionConfig = InjectionConfig(),
        startup: StartupConfig = StartupConfig(),
        history: HistoryConfig = HistoryConfig(),
        usage: UsageConfig = UsageConfig(),
        overlay: OverlayConfig = OverlayConfig(),
        privacy: PrivacyConfig = PrivacyConfig()
    ) {
        self.schemaVersion = schemaVersion
        self.provider = provider
        self.hotkey = hotkey
        self.injection = injection
        self.startup = startup
        self.history = history
        self.usage = usage
        self.overlay = overlay
        self.privacy = privacy
    }
}

// MARK: - Provider

public struct ProviderConfig: Codable, Sendable, Equatable {
    /// Provider identifier — keyed against `ProviderRegistry`. Default: ElevenLabs.
    public var providerName: String
    public var model: String?
    public var language: String?
    public var hints: [String]

    public init(
        providerName: String = "elevenlabs",
        model: String? = nil,
        language: String? = nil,
        hints: [String] = []
    ) {
        self.providerName = providerName
        self.model = model
        self.language = language
        self.hints = hints
    }
}

// MARK: - Hotkey

/// Persisted hotkey configuration.
///
/// Named `HotkeyConfig` (not `HotkeyBinding` as in TECH_SPEC §9.2) to avoid
/// colliding with the platform-layer `HotkeyBinding` type in
/// `PlatformApple/Mac/HotkeyBinding.swift`, and to match the `*Config`
/// pattern used by every other sub-struct in this file.
///
/// For modifier-only activations (right Option, fn, etc.), `keyCode` is the
/// modifier key's own key code and `modifiers` is empty. The Mac translator
/// recognises known modifier key codes and supplies the appropriate
/// device-specific `CGEventFlags` bit.
public struct HotkeyConfig: Codable, Sendable, Equatable {
    /// Default activation key code: right Option (`0x3D`).
    public static let defaultKeyCode: UInt16 = 0x3D
    /// Default cancel key code: Escape (`0x35`).
    public static let defaultCancelKeyCode: UInt16 = 0x35

    public var keyCode: UInt16
    public var modifiers: ModifierSet
    public var cancelKeyCode: UInt16
    public var cancelModifiers: ModifierSet
    public var pressHoldThresholdMs: UInt32
    public var doubleTapWindowMs: UInt32

    public init(
        keyCode: UInt16 = HotkeyConfig.defaultKeyCode,
        modifiers: ModifierSet = [],
        cancelKeyCode: UInt16 = HotkeyConfig.defaultCancelKeyCode,
        cancelModifiers: ModifierSet = [],
        pressHoldThresholdMs: UInt32 = 250,
        doubleTapWindowMs: UInt32 = 300
    ) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.cancelKeyCode = cancelKeyCode
        self.cancelModifiers = cancelModifiers
        self.pressHoldThresholdMs = pressHoldThresholdMs
        self.doubleTapWindowMs = doubleTapWindowMs
    }
}

/// Codable `OptionSet` over the standard chord modifiers. Raw values match
/// the bit positions used by NSEvent's modifier flags so platform code can
/// translate without a lookup.
public struct ModifierSet: OptionSet, Codable, Sendable, Equatable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let shift     = ModifierSet(rawValue: 1 << 0)
    public static let control   = ModifierSet(rawValue: 1 << 1)
    public static let option    = ModifierSet(rawValue: 1 << 2)
    public static let command   = ModifierSet(rawValue: 1 << 3)
    public static let function  = ModifierSet(rawValue: 1 << 4)
    public static let capsLock  = ModifierSet(rawValue: 1 << 5)
}

// MARK: - Injection

public struct InjectionConfig: Codable, Sendable, Equatable {
    public var defaultStrategy: InjectionStrategy
    public var typeMaxCharsForAuto: UInt32
    /// User-added bundle IDs to treat as terminals. Unioned at runtime with
    /// the platform's built-in defaults (`TerminalAllowlist.defaults` on Mac).
    public var terminalAllowlist: [String]
    public var perAppOverrides: [String: InjectionStrategy]
    public var leaveOnClipboard: Bool

    public init(
        defaultStrategy: InjectionStrategy = .auto,
        typeMaxCharsForAuto: UInt32 = 8,
        terminalAllowlist: [String] = [],
        perAppOverrides: [String: InjectionStrategy] = [:],
        leaveOnClipboard: Bool = false
    ) {
        self.defaultStrategy = defaultStrategy
        self.typeMaxCharsForAuto = typeMaxCharsForAuto
        self.terminalAllowlist = terminalAllowlist
        self.perAppOverrides = perAppOverrides
        self.leaveOnClipboard = leaveOnClipboard
    }
}

// MARK: - Startup

public struct StartupConfig: Codable, Sendable, Equatable {
    public var launchAtLogin: Bool

    public init(launchAtLogin: Bool = false) {
        self.launchAtLogin = launchAtLogin
    }
}

// MARK: - History

public struct HistoryConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var retentionDays: UInt32
    public var maxEntries: UInt32

    public init(
        enabled: Bool = true,
        retentionDays: UInt32 = 30,
        maxEntries: UInt32 = 1000
    ) {
        self.enabled = enabled
        self.retentionDays = retentionDays
        self.maxEntries = maxEntries
    }
}

// MARK: - Usage

public struct UsageConfig: Codable, Sendable, Equatable {
    public var menubarIndicator: MenubarIndicator
    public var monthlyAlertThresholdMinutes: UInt32?

    public init(
        menubarIndicator: MenubarIndicator = .off,
        monthlyAlertThresholdMinutes: UInt32? = nil
    ) {
        self.menubarIndicator = menubarIndicator
        self.monthlyAlertThresholdMinutes = monthlyAlertThresholdMinutes
    }
}

public enum MenubarIndicator: String, Codable, Sendable, Equatable {
    case off
    case minutes
    case cost
}

// MARK: - Overlay

public struct OverlayConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var anchor: OverlayAnchor
    /// `displayUUID` of the screen to anchor against when `anchor == .screenBottom`.
    /// `nil` means "active screen at session start".
    public var screenAnchorScreen: String?

    public init(
        enabled: Bool = true,
        anchor: OverlayAnchor = .nearCursor,
        screenAnchorScreen: String? = nil
    ) {
        self.enabled = enabled
        self.anchor = anchor
        self.screenAnchorScreen = screenAnchorScreen
    }
}

public enum OverlayAnchor: String, Codable, Sendable, Equatable {
    case nearCursor
    case screenBottom
}

// MARK: - Privacy

public struct PrivacyConfig: Codable, Sendable, Equatable {
    public var hasReadDisclosure: Bool
    /// Wall-clock time the disclosure was acknowledged. `nil` until `hasReadDisclosure` flips true.
    public var disclosureAcknowledgedAt: Date?

    public init(
        hasReadDisclosure: Bool = false,
        disclosureAcknowledgedAt: Date? = nil
    ) {
        self.hasReadDisclosure = hasReadDisclosure
        self.disclosureAcknowledgedAt = disclosureAcknowledgedAt
    }
}
