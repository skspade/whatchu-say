import Testing
import Foundation
@testable import Injector
@testable import Core

@Suite("StrategySelector: resolution order")
struct StrategySelectorTests {
    @Test("Per-app override wins over everything")
    func perAppOverrideWins() {
        let selector = StrategySelector(
            defaultStrategy: .paste,
            typeMaxChars: 8,
            terminalAllowlist: ["com.apple.Terminal"],
            perAppOverrides: ["com.apple.Terminal": .type]
        )
        // Despite Terminal being on the allowlist AND default forced to paste,
        // the explicit override (.type) wins.
        let result = selector.resolve(text: "ls", frontmostBundleID: "com.apple.Terminal")
        #expect(result == .type)
    }

    @Test("defaultStrategy=.paste forces paste even for short ASCII text")
    func defaultPasteForcesPaste() {
        let selector = StrategySelector(defaultStrategy: .paste)
        let result = selector.resolve(text: "hi", frontmostBundleID: nil)
        #expect(result == .paste)
    }

    @Test("defaultStrategy=.type forces type even for long Unicode")
    func defaultTypeForcesType() {
        let selector = StrategySelector(defaultStrategy: .type)
        let longUnicode = String(repeating: "café ", count: 30)
        let result = selector.resolve(text: longUnicode, frontmostBundleID: nil)
        #expect(result == .type)
    }

    @Test("defaultStrategy=.auto + terminal app → paste")
    func autoTerminalPastes() {
        let selector = StrategySelector(
            defaultStrategy: .auto,
            terminalAllowlist: ["com.apple.Terminal"]
        )
        let result = selector.resolve(text: "ls", frontmostBundleID: "com.apple.Terminal")
        #expect(result == .paste)
    }

    @Test("defaultStrategy=.auto + short ASCII non-terminal → type")
    func autoShortAsciiTypes() {
        let selector = StrategySelector(defaultStrategy: .auto, typeMaxChars: 8)
        let result = selector.resolve(text: "hello", frontmostBundleID: "com.apple.Notes")
        #expect(result == .type)
    }

    @Test("defaultStrategy=.auto + long ASCII → paste")
    func autoLongAsciiPastes() {
        let selector = StrategySelector(defaultStrategy: .auto, typeMaxChars: 8)
        let result = selector.resolve(text: "this is too long", frontmostBundleID: nil)
        #expect(result == .paste)
    }

    @Test("defaultStrategy=.auto + non-ASCII → paste")
    func autoUnicodePastes() {
        let selector = StrategySelector(defaultStrategy: .auto, typeMaxChars: 8)
        let result = selector.resolve(text: "café", frontmostBundleID: nil)
        #expect(result == .paste)
    }

    @Test("defaultStrategy=.auto + short text with newline → paste")
    func autoNewlinePastes() {
        let selector = StrategySelector(defaultStrategy: .auto, typeMaxChars: 8)
        let result = selector.resolve(text: "a\nb", frontmostBundleID: nil)
        #expect(result == .paste)
    }

    @Test("defaultStrategy default is .auto (back-compat)")
    func backCompatDefault() {
        let selector = StrategySelector()
        #expect(selector.defaultStrategy == .auto)
    }
}
