import Foundation

extension URL {
    /// `~/Library/Application Support/whatchu-say/`, falling back to the
    /// temp directory if Application Support is unreachable. Parent
    /// directories are created lazily by callers on first save.
    static var whatchuSayAppSupport: URL {
        let fm = FileManager.default
        let support = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fm.temporaryDirectory
        return support.appendingPathComponent("whatchu-say", isDirectory: true)
    }

    /// `~/Library/Application Support/whatchu-say/recent-transcripts.json`.
    static var recentTranscriptsDefault: URL {
        whatchuSayAppSupport.appendingPathComponent("recent-transcripts.json")
    }

    /// `~/Library/Application Support/whatchu-say/error-log.json`.
    static var errorLogDefault: URL {
        whatchuSayAppSupport.appendingPathComponent("error-log.json")
    }
}
