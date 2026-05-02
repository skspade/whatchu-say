import Foundation

public protocol MeetingLibraryProtocol: Sendable {
    func create(session: MeetingSession) throws -> URL
    func load(id: UUID) throws -> MeetingSession
    func update(session: MeetingSession) throws
    func directory(for id: UUID) throws -> URL
    func micFile(for id: UUID) throws -> URL
    func systemFile(for id: UUID) throws -> URL
    func writeTranscript(_ transcript: MeetingTranscript, for id: UUID, title: String) throws
    func deleteAudio(for id: UUID) throws
    func listAll() throws -> [MeetingSession]
    func findIncomplete() throws -> [MeetingSession]
    func delete(id: UUID) throws
}

public struct MeetingLibrary: MeetingLibraryProtocol {
    private let rootDirectory: URL

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
    }

    public static func defaultRoot() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = support.appendingPathComponent("whatchu-say/meetings", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public func directory(for id: UUID) throws -> URL {
        rootDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    public func micFile(for id: UUID) throws -> URL {
        try directory(for: id).appendingPathComponent("mic.opus")
    }

    public func systemFile(for id: UUID) throws -> URL {
        try directory(for: id).appendingPathComponent("system.opus")
    }

    public func create(session: MeetingSession) throws -> URL {
        let dir = try directory(for: session.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try writeMeta(session, to: dir)
        return dir
    }

    public func load(id: UUID) throws -> MeetingSession {
        let url = try directory(for: id).appendingPathComponent("meta.json")
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MeetingSession.self, from: data)
    }

    public func update(session: MeetingSession) throws {
        let dir = try directory(for: session.id)
        try writeMeta(session, to: dir)
    }

    public func writeTranscript(_ transcript: MeetingTranscript, for id: UUID, title: String) throws {
        let dir = try directory(for: id)
        let json = try JSONEncoder().encode(transcript)
        try json.write(to: dir.appendingPathComponent("transcript.json"))
        let md = transcript.renderMarkdown(title: title)
        try md.data(using: .utf8)!.write(to: dir.appendingPathComponent("transcript.md"))
    }

    public func deleteAudio(for id: UUID) throws {
        let dir = try directory(for: id)
        for name in ["mic.opus", "system.opus"] {
            let url = dir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    public func listAll() throws -> [MeetingSession] {
        let entries = try FileManager.default.contentsOfDirectory(at: rootDirectory, includingPropertiesForKeys: nil)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var result: [MeetingSession] = []
        for entry in entries {
            guard UUID(uuidString: entry.lastPathComponent) != nil else { continue }
            let metaURL = entry.appendingPathComponent("meta.json")
            guard let data = try? Data(contentsOf: metaURL),
                  let session = try? decoder.decode(MeetingSession.self, from: data) else { continue }
            result.append(session)
        }
        return result.sorted { $0.startedAt > $1.startedAt }
    }

    public func findIncomplete() throws -> [MeetingSession] {
        try listAll().filter { session in
            switch session.status {
            case .recording, .transcribing: return true
            case .completed, .failed: return false
            }
        }
    }

    public func delete(id: UUID) throws {
        try FileManager.default.removeItem(at: try directory(for: id))
    }

    private func writeMeta(_ session: MeetingSession, to dir: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(session)
        try data.write(to: dir.appendingPathComponent("meta.json"))
    }
}
