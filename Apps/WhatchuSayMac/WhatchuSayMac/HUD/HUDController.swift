import AppKit
import SwiftUI
import Orchestrator

/// Owns the HUD panel and drives its state from orchestrator events + the
/// audio capture's RMS stream. Lives on the main actor since it touches
/// AppKit and SwiftUI.
@MainActor
final class HUDController {
    let state = HUDState()

    private var panel: HUDPanel?
    private var hostingController: NSHostingController<HUDView>?
    private var rmsTask: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?

    private static let panelWidth: CGFloat = 440
    private static let panelHeight: CGFloat = 56
    private static let bottomMargin: CGFloat = 80
    private static let sessionEndedDismissDelay: Duration = .milliseconds(150)
    private static let errorDismissDelay: Duration = .seconds(2)
    private static let fadeDuration: TimeInterval = 0.18

    /// Subscribe to the audio capture's RMS stream so the level meter
    /// updates while a session is active. Idempotent: a second call replaces
    /// the previous subscription. Orchestrator events are dispatched via
    /// `handle(event:)` so the caller can fan out a single subscription to
    /// multiple consumers.
    func attachAudio(rms: AsyncStream<Float>) {
        rmsTask?.cancel()
        rmsTask = Task { [weak self] in
            for await level in rms {
                self?.handle(level: level)
            }
        }
    }

    func detach() {
        rmsTask?.cancel()
        dismissTask?.cancel()
        rmsTask = nil
        dismissTask = nil
        hidePanel()
    }

    // MARK: - Event handling

    func handle(event: OrchestratorEvent) {
        cancelPendingDismiss()
        switch event {
        case .sessionStarted:
            state.status = .listening
            showPanel()
        case .partial(let text):
            let level = currentLevel()
            state.status = .active(partial: text, level: level)
        case .finalizing:
            let last = currentPartial()
            state.status = .finalizing(lastPartial: last)
        case .sessionEnded:
            scheduleDismiss(after: Self.sessionEndedDismissDelay)
        case .error(let text):
            state.status = .error(text: text)
            showPanel()
            scheduleDismiss(after: Self.errorDismissDelay)
        }
    }

    private func handle(level: Float) {
        guard case .active(let partial, _) = state.status else { return }
        state.status = .active(partial: partial, level: level)
    }

    private func currentPartial() -> String {
        if case .active(let partial, _) = state.status { return partial }
        return ""
    }

    private func currentLevel() -> Float {
        if case .active(_, let level) = state.status { return level }
        return 0
    }

    // MARK: - Panel lifecycle

    private func showPanel() {
        let frame = computeFrame()
        if let panel {
            panel.setFrame(frame, display: true)
            fadeIn(panel)
            return
        }
        let view = HUDView(state: state)
        let host = NSHostingController(rootView: view)
        host.view.wantsLayer = true
        let panel = HUDPanel(contentRect: frame)
        panel.contentViewController = host
        panel.setFrame(frame, display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        self.panel = panel
        self.hostingController = host
        fadeIn(panel)
    }

    private func fadeIn(_ panel: HUDPanel) {
        if !panel.isVisible { panel.orderFrontRegardless() }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.fadeDuration
            ctx.allowsImplicitAnimation = true
            panel.animator().alphaValue = 1
        }
    }

    private func hidePanel() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.fadeDuration
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak panel] in
            panel?.orderOut(nil)
        })
    }

    private func scheduleDismiss(after delay: Duration) {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.state.status = .hidden
            self?.hidePanel()
        }
    }

    private func cancelPendingDismiss() {
        dismissTask?.cancel()
        dismissTask = nil
    }

    /// Bottom-center of the screen containing the mouse cursor (proxy for
    /// "screen the user is on"), falling back to the main screen.
    private func computeFrame() -> NSRect {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x = visible.midX - Self.panelWidth / 2
        let y = visible.minY + Self.bottomMargin
        return NSRect(x: x, y: y, width: Self.panelWidth, height: Self.panelHeight)
    }
}
