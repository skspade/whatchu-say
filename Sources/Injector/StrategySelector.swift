import Foundation
import Core

/// Resolves the runtime injection strategy from config + context.
///
/// Resolution order (first match wins):
/// 1. **Per-app override** — explicit user choice for the frontmost app.
/// 2. **`defaultStrategy != .auto`** — user globally forced a strategy.
/// 3. **Terminal allowlist** — frontmost app is a known terminal → paste.
/// 4. **Auto heuristic** — type for short ASCII text, paste otherwise.
public struct StrategySelector: Sendable {
    public let defaultStrategy: InjectionStrategy
    public let typeMaxChars: Int
    public let terminalAllowlist: Set<String>
    public let perAppOverrides: [String: InjectionStrategy]

    public init(
        defaultStrategy: InjectionStrategy = .auto,
        typeMaxChars: Int = 8,
        terminalAllowlist: Set<String> = TerminalAllowlist.defaults,
        perAppOverrides: [String: InjectionStrategy] = [:]
    ) {
        self.defaultStrategy = defaultStrategy
        self.typeMaxChars = typeMaxChars
        self.terminalAllowlist = terminalAllowlist
        self.perAppOverrides = perAppOverrides
    }

    public func resolve(text: String, frontmostBundleID: String?) -> InjectionStrategy {
        if let bundleID = frontmostBundleID, let override = perAppOverrides[bundleID] {
            return override
        }
        if defaultStrategy != .auto {
            return defaultStrategy
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
