import Testing
import AppKit
@testable import WhatchuSayMac
import Orchestrator
import Hotkey

// MARK: - HUDPanel configuration

@Suite("HUDPanel: window configuration")
@MainActor
struct HUDPanelTests {
    private func makePanel() -> HUDPanel {
        HUDPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 100))
    }

    @Test("refuses key status so the focused app stays active")
    func cannotBecomeKey() {
        #expect(makePanel().canBecomeKey == false)
    }

    @Test("refuses main status")
    func cannotBecomeMain() {
        #expect(makePanel().canBecomeMain == false)
    }

    @Test("floats at statusBar level")
    func windowLevel() {
        let panel = makePanel()
        #expect(panel.isFloatingPanel == true)
        #expect(panel.level == .statusBar)
    }

    @Test("ignores mouse events (click-through)")
    func ignoresMouse() {
        #expect(makePanel().ignoresMouseEvents == true)
    }

    @Test("transparent with clear background for rounded-rect mask")
    func transparent() {
        let panel = makePanel()
        #expect(panel.isOpaque == false)
        #expect(panel.backgroundColor == .clear)
    }

    @Test("visible on all spaces and in fullscreen")
    func collectionBehavior() {
        let panel = makePanel()
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
    }

    @Test("does not hide when app deactivates")
    func doesNotHideOnDeactivate() {
        #expect(makePanel().hidesOnDeactivate == false)
    }
}

// MARK: - HUDController state transitions

@Suite("HUDController: orchestrator event → state")
@MainActor
struct HUDControllerStateTests {

    @Test("sessionStarted sets status to listening")
    func sessionStarted() {
        let controller = HUDController()
        controller.handle(event: .sessionStarted(mode: .pressHold))
        #expect(controller.state.status == .listening)
    }

    @Test("partial sets active status with transcript text")
    func partial() {
        let controller = HUDController()
        controller.handle(event: .sessionStarted(mode: .pressHold))
        controller.handle(event: .partial(text: "hello"))
        #expect(controller.state.status == .active(partial: "hello", level: 0))
    }

    @Test("sequential partials update the transcript")
    func sequentialPartials() {
        let controller = HUDController()
        controller.handle(event: .sessionStarted(mode: .pressHold))
        controller.handle(event: .partial(text: "he"))
        controller.handle(event: .partial(text: "hello"))
        controller.handle(event: .partial(text: "hello world"))
        #expect(controller.state.status == .active(partial: "hello world", level: 0))
    }

    @Test("finalizing captures the last partial text")
    func finalizing() {
        let controller = HUDController()
        controller.handle(event: .sessionStarted(mode: .pressHold))
        controller.handle(event: .partial(text: "hello world"))
        controller.handle(event: .finalizing)
        #expect(controller.state.status == .finalizing(lastPartial: "hello world"))
    }

    @Test("finalizing with no prior partial uses empty string")
    func finalizingNoPrior() {
        let controller = HUDController()
        controller.handle(event: .sessionStarted(mode: .pressHold))
        controller.handle(event: .finalizing)
        #expect(controller.state.status == .finalizing(lastPartial: ""))
    }

    @Test("error sets error status")
    func error() {
        let controller = HUDController()
        controller.handle(event: .error(text: "connection lost"))
        #expect(controller.state.status == .error(text: "connection lost"))
    }

    @Test("sessionEnded schedules dismissal to hidden")
    func sessionEndedDismisses() async throws {
        let controller = HUDController()
        controller.handle(event: .sessionStarted(mode: .pressHold))
        controller.handle(event: .sessionEnded(injectedText: "hello"))
        try await Task.sleep(for: .milliseconds(300))
        #expect(controller.state.status == .hidden)
    }

    @Test("new sessionStarted cancels a pending dismiss")
    func newSessionCancelsDismiss() async throws {
        let controller = HUDController()
        controller.handle(event: .sessionStarted(mode: .pressHold))
        controller.handle(event: .sessionEnded(injectedText: "first"))
        controller.handle(event: .sessionStarted(mode: .pressHold))
        try await Task.sleep(for: .milliseconds(300))
        #expect(controller.state.status == .listening)
    }

    @Test("full lifecycle: start → partial → finalizing → ended → hidden")
    func fullLifecycle() async throws {
        let controller = HUDController()

        controller.handle(event: .sessionStarted(mode: .pressHold))
        #expect(controller.state.status == .listening)

        controller.handle(event: .partial(text: "hello"))
        #expect(controller.state.status == .active(partial: "hello", level: 0))

        controller.handle(event: .finalizing)
        #expect(controller.state.status == .finalizing(lastPartial: "hello"))

        controller.handle(event: .sessionEnded(injectedText: "hello"))
        try await Task.sleep(for: .milliseconds(300))
        #expect(controller.state.status == .hidden)
    }

    @Test("error during active session replaces the partial")
    func errorDuringSession() {
        let controller = HUDController()
        controller.handle(event: .sessionStarted(mode: .pressHold))
        controller.handle(event: .partial(text: "hello"))
        controller.handle(event: .error(text: "timeout"))
        #expect(controller.state.status == .error(text: "timeout"))
    }

    @Test("hands-free mode sessionStarted sets listening")
    func handsFreeStart() {
        let controller = HUDController()
        controller.handle(event: .sessionStarted(mode: .handsFree))
        #expect(controller.state.status == .listening)
    }
}
