import Foundation

/// Merges two transcribed streams (mic + system) into one chronological
/// transcript. Pure function — no I/O. On a tie at `start`, mic segments
/// come first by convention so "I said X" reads before "they said Y".
public enum TranscriptMerger {
    public static func merge(mic: [Segment], system: [Segment]) -> [Segment] {
        var combined: [(Int, Segment)] = []
        combined.reserveCapacity(mic.count + system.count)
        for s in mic { combined.append((0, s)) }
        for s in system { combined.append((1, s)) }
        combined.sort { lhs, rhs in
            if lhs.1.start != rhs.1.start { return lhs.1.start < rhs.1.start }
            return lhs.0 < rhs.0
        }
        return combined.map(\.1)
    }
}
