import Foundation

/// Tunables for the error-log buffer. Mirrors `RecentTranscriptsConfig`'s
/// shape so the future settings UI can bind to both with the same pattern.
enum ErrorLogConfig {
    /// Default cap on the error-log buffer. Larger than recent-transcripts
    /// because errors are short, retention here is for debugging not
    /// re-paste, and you usually want history when chasing a flaky issue.
    static let maxCount: Int = 50

    /// How many entries render directly in the main menu before the
    /// remainder are pushed under an "Older…" submenu. Same density choice
    /// as recent-transcripts.
    static let topLevelDisplayCount: Int = 5

    /// UserDefaults override hatch. Setting this key to a positive integer
    /// overrides `maxCount` at next launch.
    static let userDefaultsKey: String = "errorLog.maxCount"

    /// Returns the user-overridden cap if set to a positive value, otherwise
    /// the default `maxCount`.
    static func resolvedMaxCount(defaults: UserDefaults = .standard) -> Int {
        let override = defaults.integer(forKey: userDefaultsKey)
        return override > 0 ? override : maxCount
    }
}
