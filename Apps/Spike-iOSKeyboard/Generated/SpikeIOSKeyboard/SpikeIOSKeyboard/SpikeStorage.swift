import Foundation

/// Tiny shared key-value store for the spike. Lives in both the host app
/// and keyboard extension target folders so each target compiles its own
/// copy — Xcode 16's synchronized folders don't easily share a single file
/// across two targets.
///
/// Behavior:
/// - Tries `UserDefaults(suiteName: appGroup)` first. Only succeeds if the
///   App Group entitlement is configured on the calling target. This is
///   the *intended* path — host app and extension share storage.
/// - Falls back to `UserDefaults.standard` (per-bundle) if the suite is
///   nil. The fallback only "works" inside the host app; the extension
///   reads its own empty `.standard` and surfaces it as "no API key set."
///   `activeSuiteDescription` reports which path is actually in use so
///   the host app can show this in the UI.
enum SpikeStorage {
    static let appGroup = "group.s900mhz.SpikeIOSKeyboard"
    static let key = "spike.elevenlabs.key"

    static func readKey() -> String? {
        defaults().string(forKey: key)
    }

    static func writeKey(_ value: String) {
        defaults().set(value, forKey: key)
    }

    /// "App Group" if the suite is reachable from this bundle, "standard
    /// (no App Group)" otherwise. Render this in the host UI to make the
    /// setup state visible without poking at Settings.
    static var activeSuiteDescription: String {
        UserDefaults(suiteName: appGroup) == nil ? "standard (no App Group)" : "App Group"
    }

    private static func defaults() -> UserDefaults {
        UserDefaults(suiteName: appGroup) ?? .standard
    }
}
