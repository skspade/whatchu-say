import Testing
import Foundation
@testable import WhatchuSayMac

@Suite("RecentTranscriptsConfig: maxCount resolution")
struct RecentTranscriptsConfigTests {
    private func makeIsolatedDefaults() -> UserDefaults {
        let suiteName = "test-recent-transcripts-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test("returns the default 20 when no override is set")
    func defaultMaxCount() {
        let defaults = makeIsolatedDefaults()
        #expect(RecentTranscriptsConfig.resolvedMaxCount(defaults: defaults) == 20)
    }

    @Test("returns the override when set to a positive integer")
    func positiveOverride() {
        let defaults = makeIsolatedDefaults()
        defaults.set(50, forKey: RecentTranscriptsConfig.userDefaultsKey)
        #expect(RecentTranscriptsConfig.resolvedMaxCount(defaults: defaults) == 50)
    }

    @Test("ignores a zero override and falls back to the default")
    func zeroOverride() {
        let defaults = makeIsolatedDefaults()
        defaults.set(0, forKey: RecentTranscriptsConfig.userDefaultsKey)
        #expect(RecentTranscriptsConfig.resolvedMaxCount(defaults: defaults) == 20)
    }

    @Test("ignores a negative override and falls back to the default")
    func negativeOverride() {
        let defaults = makeIsolatedDefaults()
        defaults.set(-5, forKey: RecentTranscriptsConfig.userDefaultsKey)
        #expect(RecentTranscriptsConfig.resolvedMaxCount(defaults: defaults) == 20)
    }

    @Test("the menu-display cap is smaller than the buffer cap")
    func menuDisplayLessThanBufferCap() {
        #expect(RecentTranscriptsConfig.topLevelDisplayCount < RecentTranscriptsConfig.maxCount)
    }
}
