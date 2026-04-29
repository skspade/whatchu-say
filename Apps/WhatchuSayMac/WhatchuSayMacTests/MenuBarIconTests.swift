import Testing
import SwiftUI
@testable import WhatchuSayMac

@Suite("MenuBarIcon: icon name and tint reflect status + lastError")
@MainActor
struct MenuBarIconTests {

    private func make(status: AppState.Status, lastError: String? = nil) -> AppState {
        let state = AppState()
        state.status = status
        state.lastError = lastError
        return state
    }

    // MARK: - icon name

    @Test("idle, no error: mic.slash")
    func idleNoError() {
        #expect(iconName(for: make(status: .idle)) == "mic.slash")
    }

    @Test("idle with error: warning triangle")
    func idleWithError() {
        let state = make(status: .idle, lastError: "boom")
        #expect(iconName(for: state) == "exclamationmark.triangle.fill")
    }

    @Test("listening, no error: mic.fill")
    func listeningNoError() {
        #expect(iconName(for: make(status: .listening)) == "mic.fill")
    }

    @Test("listening with error: stays mic.fill (active session takes precedence in name)")
    func listeningWithErrorKeepsMicIcon() {
        // While actively dictating we don't swap the icon shape — the tint
        // change is the signal. Swapping the shape mid-session would be
        // jarring.
        let state = make(status: .listening, lastError: "boom")
        #expect(iconName(for: state) == "mic.fill")
    }

    @Test("needsSetup: key icon")
    func needsSetupIcon() {
        #expect(iconName(for: make(status: .needsSetup)) == "key.fill")
    }

    @Test("startupFailed: warning triangle")
    func startupFailedIcon() {
        let state = make(status: .startupFailed("boom"))
        #expect(iconName(for: state) == "exclamationmark.triangle.fill")
    }

    // MARK: - icon tint

    @Test("idle, no error: primary tint")
    func idleNoErrorTint() {
        #expect(iconTint(for: make(status: .idle)) == .primary)
    }

    @Test("idle with error: yellow tint")
    func idleWithErrorTint() {
        let state = make(status: .idle, lastError: "boom")
        #expect(iconTint(for: state) == .yellow)
    }

    @Test("listening, no error: primary tint")
    func listeningNoErrorTint() {
        #expect(iconTint(for: make(status: .listening)) == .primary)
    }

    @Test("listening with error: yellow tint (the visible signal)")
    func listeningWithErrorTint() {
        let state = make(status: .listening, lastError: "boom")
        #expect(iconTint(for: state) == .yellow)
    }

    @Test("needsSetup: yellow")
    func needsSetupTint() {
        #expect(iconTint(for: make(status: .needsSetup)) == .yellow)
    }

    @Test("startupFailed: yellow")
    func startupFailedTint() {
        let state = make(status: .startupFailed("boom"))
        #expect(iconTint(for: state) == .yellow)
    }
}
