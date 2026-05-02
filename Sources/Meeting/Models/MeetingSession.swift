import Foundation

public struct MeetingSession: Sendable, Equatable, Codable {
    public enum Status: Sendable, Equatable, Codable {
        case recording
        case transcribing
        case completed
        case failed(String)
    }

    public let id: UUID
    public var title: String
    public let startedAt: Date
    public var endedAt: Date?
    public var attendees: AttendeeList
    public var keepAudio: Bool
    public var status: Status

    public init(
        id: UUID,
        title: String?,
        startedAt: Date,
        attendees: AttendeeList,
        keepAudio: Bool
    ) {
        self.id = id
        self.title = title ?? Self.defaultTitle(for: startedAt)
        self.startedAt = startedAt
        self.endedAt = nil
        self.attendees = attendees
        self.keepAudio = keepAudio
        self.status = .recording
    }

    public mutating func markStopped(at date: Date) {
        endedAt = date
        status = .transcribing
    }

    public mutating func markCompleted() { status = .completed }

    public mutating func markFailed(reason: String) { status = .failed(reason) }

    private static func defaultTitle(for date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return "Meeting — \(f.string(from: date))"
    }
}
