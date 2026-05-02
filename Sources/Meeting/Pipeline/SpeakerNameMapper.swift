import Foundation

/// Maps anonymous diarized speaker IDs (`Speaker.anonymous(N)`) to names from
/// the attendee list. The protocol is async + throwing so an LLM-backed
/// implementation can drop in later without breaking the pipeline.
public protocol SpeakerNameMapper: Sendable {
    /// Returns a partial mapping `[anonymousId: name]`. IDs absent from the
    /// returned dict are intentionally left as `Speaker.anonymous(...)` —
    /// the user can manually rename them.
    func map(
        transcript: MeetingTranscript,
        attendees: AttendeeList
    ) async throws -> [Int: String]
}

/// Default mapper: scans transcript for self-introductions of the form
/// "I'm <Name>" or "I am <Name>" or "this is <Name>" where `<Name>` is in
/// the attendee list. First match wins per anonymous speaker id.
public struct ContentBasedSpeakerNameMapper: SpeakerNameMapper {
    public init() {}

    public func map(
        transcript: MeetingTranscript,
        attendees: AttendeeList
    ) async throws -> [Int: String] {
        guard !attendees.isEmpty else { return [:] }

        let nameSet = Dictionary(uniqueKeysWithValues: attendees.names.map { ($0.lowercased(), $0) })
        var result: [Int: String] = [:]

        for seg in transcript.segments {
            guard case let .anonymous(id) = seg.speaker, result[id] == nil else { continue }
            for prefix in ["i'm ", "i am ", "this is "] {
                if let range = seg.text.range(of: prefix, options: [.caseInsensitive]) {
                    let after = seg.text[range.upperBound...]
                    let candidate = after
                        .prefix { $0.isLetter || $0 == "-" }
                        .trimmingCharacters(in: .whitespaces)
                    if !candidate.isEmpty, let canonical = nameSet[candidate.lowercased()] {
                        result[id] = canonical
                        break
                    }
                }
            }
        }
        return result
    }
}
