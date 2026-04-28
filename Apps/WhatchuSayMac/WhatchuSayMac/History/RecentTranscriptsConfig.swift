import Foundation

/// Tunables for the recent-transcripts buffer. Exposed as a single namespace
/// so callers (store, menu view, future settings UI) reach the same source of
/// truth. Graduates to `AppConfig.history` when the Milestone 1.5 SQLite
/// store lands.
enum RecentTranscriptsConfig {
    /// Default cap on the recent-transcripts buffer.
    static let maxCount: Int = 20

    /// How many entries render directly in the main menu before the
    /// remainder are pushed under an "Older…" submenu.
    static let topLevelDisplayCount: Int = 5

    /// UserDefaults override hatch. Setting this key to a positive integer
    /// overrides `maxCount` at next launch — lets the 1.3 settings UI bind
    /// to a key without the constant becoming a moving target.
    static let userDefaultsKey: String = "recentTranscripts.maxCount"

    /// Returns the user-overridden cap if set to a positive value, otherwise
    /// the default `maxCount`.
    static func resolvedMaxCount(defaults: UserDefaults = .standard) -> Int {
        let override = defaults.integer(forKey: userDefaultsKey)
        return override > 0 ? override : maxCount
    }
}
