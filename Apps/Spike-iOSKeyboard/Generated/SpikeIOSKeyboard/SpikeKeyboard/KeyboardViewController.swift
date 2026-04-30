import UIKit
import SwiftUI
import Foundation

/// Spike keyboard. Hosts a SwiftUI view containing a mic button + on-screen
/// readouts (RSS, WS state, frame count, last final). The view's gesture
/// drives `SpikeCoordinator` which pumps audio over the WebSocket.
///
/// Lifecycle:
/// - `viewDidLoad` — install hosting controller, start memory probe.
/// - `viewWillDisappear` — tear down audio + WebSocket; stop memory probe.
final class KeyboardViewController: UIInputViewController {
    private let state = SpikeState()
    private var coordinator: SpikeCoordinator?

    override func viewDidLoad() {
        super.viewDidLoad()

        let apiKey = SpikeStorage.readKey() ?? ""
        coordinator = SpikeCoordinator(
            apiKey: apiKey,
            state: state,
            onInsert: { [weak self] text in
                self?.textDocumentProxy.insertText(text)
            }
        )

        let view = SpikeKeyboardView(
            state: state,
            onPressBegan: { [weak self] in self?.coordinator?.pressBegan() },
            onPressEnded: { [weak self] in self?.coordinator?.pressEnded() },
            onPressCancelled: { [weak self] in self?.coordinator?.pressCancelled() },
            onSwitchKeyboard: { [weak self] in self?.advanceToNextInputMode() }
        )
        let host = UIHostingController(rootView: view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.backgroundColor = .clear
        addChild(host)
        self.view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: self.view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: self.view.bottomAnchor),
        ])
        host.didMove(toParent: self)

        state.startMemoryProbe()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        coordinator?.tearDown()
        state.stopMemoryProbe()
    }
}

/// Observable model for the spike keyboard view. MainActor-isolated so the
/// coordinator's state writes don't cross-thread the UI.
@MainActor
@Observable
final class SpikeState {
    var rssMB: Double = 0
    var rssPeakMB: Double = 0
    var connection: String = "idle"
    var framesSent: Int = 0
    var lastFinal: String = ""
    var listening: Bool = false
    var error: String?

    private var probeTask: Task<Void, Never>?

    func startMemoryProbe() {
        probeTask?.cancel()
        probeTask = Task { [weak self] in
            while !Task.isCancelled {
                if let mb = MemoryProbe.residentMB() {
                    await MainActor.run {
                        guard let self else { return }
                        self.rssMB = mb
                        if mb > self.rssPeakMB { self.rssPeakMB = mb }
                    }
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    func stopMemoryProbe() {
        probeTask?.cancel()
        probeTask = nil
    }
}

private struct SpikeKeyboardView: View {
    let state: SpikeState
    let onPressBegan: () -> Void
    let onPressEnded: () -> Void
    let onPressCancelled: () -> Void
    let onSwitchKeyboard: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Button(action: onSwitchKeyboard) {
                    Image(systemName: "globe").padding(6)
                }
                Spacer()
                Text(String(format: "RSS %.1f / peak %.1f MB", state.rssMB, state.rssPeakMB))
                    .font(.caption.monospacedDigit())
                Spacer()
                Text("WS: \(state.connection)")
                    .font(.caption.monospacedDigit())
            }

            HStack {
                Text("frames: \(state.framesSent)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(state.lastFinal.isEmpty ? "—" : state.lastFinal)
                    .font(.caption)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }

            // Diagnostic line: shows whether the keyboard sees the App
            // Group container and whether the API key is readable from it.
            // If "suite: standard", the entitlement isn't attached at
            // runtime even though it's in the project. If "key: 0 chars",
            // the host app saved to a different store.
            Text("suite: \(SpikeStorage.activeSuiteDescription) · key: \(SpikeStorage.readKey()?.count ?? 0) chars")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let err = state.error {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            MicButton(
                listening: state.listening,
                onPressBegan: onPressBegan,
                onPressEnded: onPressEnded,
                onPressCancelled: onPressCancelled
            )
        }
        .padding(12)
        .frame(height: 240)
    }
}

/// Press-and-hold mic button. Drag distance > 60pt at release counts as
/// "drag-off-button" cancellation, mirroring the touch-up-outside behavior
/// PRD §6.7 calls for in the production extension.
private struct MicButton: View {
    let listening: Bool
    let onPressBegan: () -> Void
    let onPressEnded: () -> Void
    let onPressCancelled: () -> Void

    @State private var isPressed = false

    var body: some View {
        ZStack {
            Circle()
                .fill(listening ? Color.red : Color.accentColor)
                .frame(width: 88, height: 88)
            Image(systemName: listening ? "waveform" : "mic.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.white)
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !isPressed {
                        isPressed = true
                        onPressBegan()
                    }
                }
                .onEnded { value in
                    isPressed = false
                    let dx = value.translation.width
                    let dy = value.translation.height
                    let distance = (dx * dx + dy * dy).squareRoot()
                    if distance > 60 {
                        onPressCancelled()
                    } else {
                        onPressEnded()
                    }
                }
        )
    }
}
