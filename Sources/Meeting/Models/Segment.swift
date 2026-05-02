import Foundation

/// Who said something in a meeting transcript. `me` is the local user;
/// `tagged` is a name (typed by the user or mapped by the LLM); `anonymous`
/// is an unmapped diarized speaker.
public enum Speaker: Sendable, Equatable, Hashable, Codable {
    case me
    case tagged(String)
    case anonymous(Int)
}

/// A contiguous transcribed utterance. Times are seconds since recording start.
public struct Segment: Sendable, Equatable, Codable {
    public let start: TimeInterval
    public let end: TimeInterval
    public var speaker: Speaker
    public let text: String

    public init(start: TimeInterval, end: TimeInterval, speaker: Speaker, text: String) {
        self.start = start
        self.end = end
        self.speaker = speaker
        self.text = text
    }

    public var duration: TimeInterval { end - start }
}
