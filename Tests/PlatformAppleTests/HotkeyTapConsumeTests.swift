#if os(macOS)
import Testing
import Foundation
@testable import PlatformApple
@testable import Hotkey

private let now = Date(timeIntervalSinceReferenceDate: 0)

@Suite("HotkeySourceMac: cancel-key consumption gate")
struct HotkeyTapConsumeTests {
    @Test("idle: cancelKey is not consumed (Esc still reaches the focused app)")
    func idleDoesNotConsumeCancel() {
        #expect(shouldConsume(translated: .cancelKey(at: now), isDictating: false) == false)
    }

    @Test("dictating: cancelKey is consumed")
    func dictatingConsumesCancel() {
        #expect(shouldConsume(translated: .cancelKey(at: now), isDictating: true) == true)
    }

    @Test("dictating: keyDown is not consumed (activation key passthrough preserved)")
    func dictatingDoesNotConsumeKeyDown() {
        #expect(shouldConsume(translated: .keyDown(at: now), isDictating: true) == false)
    }

    @Test("dictating: keyUp is not consumed")
    func dictatingDoesNotConsumeKeyUp() {
        #expect(shouldConsume(translated: .keyUp(at: now), isDictating: true) == false)
    }

    @Test("dictating: timerExpired is not consumed (synthetic, not from a real event)")
    func dictatingDoesNotConsumeTimer() {
        #expect(shouldConsume(translated: .timerExpired, isDictating: true) == false)
    }

    @Test("nil translation: never consumed regardless of state")
    func nilTranslationNeverConsumed() {
        #expect(shouldConsume(translated: nil, isDictating: false) == false)
        #expect(shouldConsume(translated: nil, isDictating: true) == false)
    }
}
#endif
