import Foundation

extension URL {
    /// Default location of the recent-transcripts JSON file:
    /// `~/Library/Application Support/whatchu-say/recent-transcripts.json`.
    ///
    /// The path is computed; the parent directory is created lazily by the
    /// store on first save. If the user's Application Support directory is
    /// somehow unreachable, falls back to a temp-directory path so the app
    /// still launches (writes will succeed there too, just non-persistent
    /// across reboots).
    static var recentTranscriptsDefault: URL {
        let fm = FileManager.default
        let support = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fm.temporaryDirectory
        return support
            .appendingPathComponent("whatchu-say", isDirectory: true)
            .appendingPathComponent("recent-transcripts.json")
    }
}
