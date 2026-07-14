import Testing
import Foundation
@testable import WhatchuSayMac
import Orchestrator
import Hotkey

@Suite("AppCoordinator: orchestrator → AppState error wiring")
@MainActor
struct AppCoordinatorErrorTests {

    @Test(".error event populates lastError")
    func errorEventSetsLastError() {
        let state = AppState()
        AppCoordinator.applyToAppState(.error(text: "connection lost"), state: state)
        #expect(state.lastError == "connection lost")
        // Status itself is unchanged by error events — the session is still
        // whatever it was. Errors are notification overlays, not state.
        #expect(state.status == .idle)
    }

    @Test("sessionEnded with injected text clears a prior lastError (recovery)")
    func successfulInjectClearsError() {
        let state = AppState()
        state.lastError = "earlier hiccup"
        AppCoordinator.applyToAppState(
            .sessionEnded(injectedText: "hello world"),
            state: state
        )
        #expect(state.lastError == nil)
        #expect(state.status == .idle)
    }

    @Test("sessionEnded with nil text preserves lastError (cancel/empty isn't recovery)")
    func nilSessionEndedPreservesError() {
        let state = AppState()
        state.lastError = "earlier hiccup"
        AppCoordinator.applyToAppState(
            .sessionEnded(injectedText: nil),
            state: state
        )
        #expect(state.lastError == "earlier hiccup")
        #expect(state.status == .idle)
    }

    @Test("sessionStarted does not touch lastError")
    func sessionStartedPreservesError() {
        let state = AppState()
        state.lastError = "earlier hiccup"
        AppCoordinator.applyToAppState(
            .sessionStarted(mode: .pressHold),
            state: state
        )
        #expect(state.lastError == "earlier hiccup")
        #expect(state.status == .listening)
    }

    @Test("startupFailed status is sticky — events do not overwrite it")
    func startupFailedIsSticky() {
        let state = AppState()
        state.status = .startupFailed("permission denied")
        AppCoordinator.applyToAppState(
            .sessionEnded(injectedText: "hello"),
            state: state
        )
        #expect(state.status == .startupFailed("permission denied"))
    }

    @Test("needsSetup status is sticky — events do not overwrite it")
    func needsSetupIsSticky() {
        let state = AppState()
        state.status = .needsSetup
        AppCoordinator.applyToAppState(
            .sessionStarted(mode: .pressHold),
            state: state
        )
        #expect(state.status == .needsSetup)
    }

    @Test("preparingProvider status is sticky while the provider initializes")
    func preparingProviderIsSticky() {
        let state = AppState()
        state.status = .preparingProvider
        AppCoordinator.applyToAppState(
            .sessionStarted(mode: .pressHold),
            state: state
        )
        #expect(state.status == .preparingProvider)
    }

    @Test("partial and finalizing events do not touch lastError or status")
    func partialAndFinalizingNoOp() {
        let state = AppState()
        state.lastError = "earlier hiccup"
        state.status = .listening
        AppCoordinator.applyToAppState(.partial(text: "hi"), state: state)
        AppCoordinator.applyToAppState(.finalizing, state: state)
        #expect(state.lastError == "earlier hiccup")
        #expect(state.status == .listening)
    }
}
