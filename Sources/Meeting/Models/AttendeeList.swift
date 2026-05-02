import Foundation

public struct AttendeeList: Sendable, Equatable, Codable {
    public let names: [String]

    public init(names: [String]) {
        self.names = names
    }

    public init(parsing input: String) {
        var seen = Set<String>()
        var result: [String] = []
        for raw in input.split(separator: ",") {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            if seen.insert(key).inserted {
                result.append(trimmed)
            }
        }
        self.names = result
    }

    public var isEmpty: Bool { names.isEmpty }
}
