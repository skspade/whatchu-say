import Foundation

/// In-memory transcript. Mutable: callers can apply LLM speaker mappings or
/// user manual renames, then re-render to markdown. The on-disk
/// `transcript.json` stores the post-mapping segments; `transcript.md` is
/// the rendered version.
public struct MeetingTranscript: Sendable, Equatable, Codable {
    public private(set) var segments: [Segment]

    public init(segments: [Segment]) {
        self.segments = segments
    }

    /// Replaces `Speaker.anonymous(id)` with `Speaker.tagged(name)` for each
    /// `id → name` entry in the mapping. Other speakers are untouched.
    public mutating func applySpeakerMapping(_ mapping: [Int: String]) {
        segments = segments.map { seg in
            guard case let .anonymous(id) = seg.speaker, let name = mapping[id] else {
                return seg
            }
            var copy = seg
            copy.speaker = .tagged(name)
            return copy
        }
    }

    /// Renames every segment whose speaker matches `from`. Used when the
    /// user right-clicks a speaker label in the transcript window.
    public mutating func renameSpeaker(_ from: Speaker, to name: String) {
        segments = segments.map { seg in
            guard seg.speaker == from else { return seg }
            var copy = seg
            copy.speaker = .tagged(name)
            return copy
        }
    }

    public func renderMarkdown(title: String) -> String {
        var lines: [String] = ["# \(title)", ""]
        for seg in segments {
            let stamp = Self.formatTimestamp(seg.start)
            let speaker = Self.speakerLabel(seg.speaker)
            lines.append("[\(stamp)] **\(speaker):** \(seg.text)")
        }
        return lines.joined(separator: "\n")
    }

    private static func formatTimestamp(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }

    private static func speakerLabel(_ speaker: Speaker) -> String {
        switch speaker {
        case .me: return "Me"
        case .tagged(let n): return n
        case .anonymous(let id): return "Speaker \(id)"
        }
    }
}
