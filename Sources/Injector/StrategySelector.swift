import Foundation

/// Resolves the runtime injection strategy from config + context.
/// Default policy: paste for everything except short ASCII text.
public struct StrategySelector: Sendable {
    public let typeMaxChars: Int
    public let terminalAllowlist: Set<String>
    public let perAppOverrides: [String: InjectionStrategy]

    public init(
        typeMaxChars: Int = 8,
        terminalAllowlist: Set<String> = TerminalAllowlist.defaults,
        perAppOverrides: [String: InjectionStrategy] = [:]
    ) {
        self.typeMaxChars = typeMaxChars
        self.terminalAllowlist = terminalAllowlist
        self.perAppOverrides = perAppOverrides
    }

    public func resolve(text: String, frontmostBundleID: String?) -> InjectionStrategy {
        if let bundleID = frontmostBundleID, let override = perAppOverrides[bundleID] {
            return override
        }
        if let bundleID = frontmostBundleID, terminalAllowlist.contains(bundleID) {
            return .paste
        }
        let isShortAscii = text.count <= typeMaxChars
            && !text.contains("\n")
            && !text.contains("\t")
            && text.allSatisfy(\.isASCII)
        return isShortAscii ? .type : .paste
    }
}
