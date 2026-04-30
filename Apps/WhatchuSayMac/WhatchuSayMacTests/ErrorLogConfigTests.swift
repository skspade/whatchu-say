import Testing
import Foundation
@testable import WhatchuSayMac

@Suite("ErrorLogConfig: maxCount resolution")
struct ErrorLogConfigTests {
    private func makeIsolatedDefaults() -> UserDefaults {
        let suiteName = "test-error-log-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test("returns the default 50 when no override is set")
    func defaultMaxCount() {
        let defaults = makeIsolatedDefaults()
        #expect(ErrorLogConfig.resolvedMaxCount(defaults: defaults) == 50)
    }

    @Test("returns the override when set to a positive integer")
    func positiveOverride() {
        let defaults = makeIsolatedDefaults()
        defaults.set(100, forKey: ErrorLogConfig.userDefaultsKey)
        #expect(ErrorLogConfig.resolvedMaxCount(defaults: defaults) == 100)
    }

    @Test("ignores a zero override and falls back to the default")
    func zeroOverride() {
        let defaults = makeIsolatedDefaults()
        defaults.set(0, forKey: ErrorLogConfig.userDefaultsKey)
        #expect(ErrorLogConfig.resolvedMaxCount(defaults: defaults) == 50)
    }

    @Test("ignores a negative override and falls back to the default")
    func negativeOverride() {
        let defaults = makeIsolatedDefaults()
        defaults.set(-5, forKey: ErrorLogConfig.userDefaultsKey)
        #expect(ErrorLogConfig.resolvedMaxCount(defaults: defaults) == 50)
    }

    @Test("the menu-display cap is smaller than the buffer cap")
    func menuDisplayLessThanBufferCap() {
        #expect(ErrorLogConfig.topLevelDisplayCount < ErrorLogConfig.maxCount)
    }
}
