import Foundation
import UIKit

/// Wires `SpikeAudioCapture` and `SpikeWebSocketClient` to the keyboard's
/// state model and the host text proxy. One coordinator per keyboard
/// presentation; tear down on `viewWillDisappear`.
///
/// All state writes happen on the main actor (the SpikeState observable
/// drives the SwiftUI view). Audio + WebSocket work hops back to MainActor
/// on each update — fine at 50 frames/sec for the spike.
@MainActor
final class SpikeCoordinator {
    private let apiKey: String
    private let state: SpikeState
    private let onInsert: (String) -> Void

    private var capture: SpikeAudioCapture?
    private var ws: SpikeWebSocketClient?
    private var audioPump: Task<Void, Never>?
    private var finalsPump: Task<Void, Never>?

    init(apiKey: String, state: SpikeState, onInsert: @escaping (String) -> Void) {
        self.apiKey = apiKey
        self.state = state
        self.onInsert = onInsert
    }

    func pressBegan() {
        guard !state.listening else { return }
        guard !apiKey.isEmpty else {
            state.error = "no API key — set it in the host app"
            return
        }
        state.listening = true
        state.connection = "connecting"
        state.framesSent = 0
        state.error = nil
        Task { await openSession() }
    }

    func pressEnded() {
        guard state.listening else { return }
        state.listening = false
        state.connection = "finalizing"
        Task { await finalizeSession() }
    }

    func pressCancelled() {
        guard state.listening else { return }
        state.listening = false
        state.connection = "cancelled"
        Task { await tearDownSession() }
    }

    func tearDown() {
        Task { await tearDownSession() }
    }

    // MARK: - Session

    private func openSession() async {
        let capture = SpikeAudioCapture()
        let ws = SpikeWebSocketClient(apiKey: apiKey)
        self.capture = capture
        self.ws = ws

        do {
            try await ws.open()
        } catch {
            state.connection = "failed"
            state.error = "ws.open: \(error)"
            state.listening = false
            return
        }
        state.connection = "open"

        finalsPump = Task { [weak self, ws] in
            for await text in ws.finals {
                guard let self else { return }
                await MainActor.run {
                    self.state.lastFinal = text
                    self.onInsert(text)
                    self.state.connection = "open"
                }
            }
        }

        audioPump = Task { [weak self, capture, ws] in
            for await frame in capture.frames {
                if Task.isCancelled { return }
                do {
                    try await ws.sendAudioChunk(samples: frame, commit: false)
                    await MainActor.run { self?.state.framesSent += 1 }
                } catch {
                    await MainActor.run { self?.state.error = "send: \(error)" }
                    return
                }
            }
        }

        do {
            try await capture.start()
        } catch {
            state.error = "capture.start: \(error)"
            await tearDownSession()
        }
    }

    private func finalizeSession() async {
        guard let capture, let ws else { return }
        await capture.stop()
        // Brief pause to let the last in-flight frames flush before commit.
        // Production code uses an explicit drain handshake; spike accepts
        // the occasional lost trailing word.
        try? await Task.sleep(for: .milliseconds(120))
        try? await ws.commit()
        // Receive loop on ws will yield the committed_transcript into
        // `finals`; finalsPump handles insertion and updates state.
    }

    private func tearDownSession() async {
        audioPump?.cancel()
        finalsPump?.cancel()
        audioPump = nil
        finalsPump = nil
        await capture?.stop()
        await ws?.close()
        capture = nil
        ws = nil
    }
}
