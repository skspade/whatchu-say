import Testing
import Foundation
@testable import WhatchuSayMac
import Orchestrator

@Suite("AppCoordinator: permissionDenied → AppState routing")
@MainActor
struct AppCoordinatorPermissionTests {

    @Test("permissionDenied(.microphone) sets permissionIssue and lastError")
    func micPermissionEventPopulatesState() {
        let state = AppState()
        AppCoordinator.applyToAppState(
            .permissionDenied(kind: .microphone),
            state: state
        )
        #expect(state.permissionIssue == .microphone)
        #expect(state.lastError == PermissionDeepLink.microphone.errorMessage)
        // Status is unchanged — permission denial is a notification overlay
        // like .error, not a status transition.
        #expect(state.status == .idle)
    }

    @Test("successful inject after permission denial clears permissionIssue (recovery)")
    func successfulInjectClearsPermissionIssue() {
        let state = AppState()
        state.permissionIssue = .microphone
        state.lastError = "Microphone access required"
        AppCoordinator.applyToAppState(
            .sessionEnded(injectedText: "hello world"),
            state: state
        )
        #expect(state.permissionIssue == nil)
        #expect(state.lastError == nil)
    }

    @Test("sessionEnded with nil text preserves permissionIssue (cancel/empty isn't recovery)")
    func nilSessionEndedPreservesPermissionIssue() {
        let state = AppState()
        state.permissionIssue = .microphone
        state.lastError = "Microphone access required"
        AppCoordinator.applyToAppState(
            .sessionEnded(injectedText: nil),
            state: state
        )
        #expect(state.permissionIssue == .microphone)
        #expect(state.lastError == "Microphone access required")
    }

    @Test("startupFailed status is sticky for permissionDenied events too")
    func startupFailedBlocksPermissionEvents() {
        let state = AppState()
        state.status = .startupFailed("Accessibility access required for the dictation hotkey")
        state.permissionIssue = .accessibility
        AppCoordinator.applyToAppState(
            .permissionDenied(kind: .microphone),
            state: state
        )
        // Pre-existing accessibility issue is not overwritten by a later
        // mic event during a startup-failed session.
        #expect(state.permissionIssue == .accessibility)
    }
}

@Suite("PermissionDeepLink: URLs and labels")
struct PermissionDeepLinkTests {

    @Test("accessibility deep-link points at the Privacy_Accessibility anchor")
    func accessibilityURL() {
        #expect(
            PermissionDeepLink.accessibility.settingsURL.absoluteString ==
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        )
    }

    @Test("microphone deep-link points at the Privacy_Microphone anchor")
    func microphoneURL() {
        #expect(
            PermissionDeepLink.microphone.settingsURL.absoluteString ==
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        )
    }

    @Test("each link has a non-empty button label and error message")
    func nonEmptyStrings() {
        for link in [PermissionDeepLink.accessibility, .microphone] {
            #expect(!link.buttonLabel.isEmpty)
            #expect(!link.errorMessage.isEmpty)
        }
    }
}
