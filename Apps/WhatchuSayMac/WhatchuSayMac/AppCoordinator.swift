import Foundation
import Audio
import Hotkey
import Injector
import Orchestrator
import PlatformApple
import STTCore
import STTElevenLabs
import Usage

/// MainActor-isolated, observable status backing the menu-bar UI.
@MainActor
@Observable
final class AppState {
    enum Status: Equatable {
        case idle
        case listening
        case startupFailed(String)
    }
    var status: Status = .idle
    var lastTranscript: String?
    var lastError: String?
}

/// Owns every long-lived component and the hotkey wiring. Built once at app
/// launch; the rest of the app talks to `state` (which is `@Observable`).
///
/// Lifecycle:
/// - `init` builds the components but does no I/O.
/// - `start()` spins up the hotkey tap and a status-poll task. Re-entrant
///   calls are no-ops.
/// - `shutdown()` tears down the hotkey tap. Audio + sessions are owned by
///   the orchestrator and stop on their own when `cancelDictation` runs.
actor AppCoordinator {
    let state: AppState
    private let orchestrator: Orchestrator
    private let hotkeySource: HotkeySourceMac
    private var statusPollTask: Task<Void, Never>?
    private var started = false

    init(apiKey: String, state: AppState) {
        self.state = state
        let provider = ElevenLabsProvider(apiKey: apiKey)
        let injector = InjectorMac()
        let stateMachine = ActivationStateMachine()
        let usage = UsageTracker()
        let audio = AVAudioCapture()
        self.orchestrator = Orchestrator(
            provider: provider,
            injector: injector,
            stateMachine: stateMachine,
            usage: usage,
            audioCapture: audio
        )
        self.hotkeySource = HotkeySourceMac()
    }

    func start() async {
        guard !started else { return }
        started = true

        do {
            try await hotkeySource.start { [orchestrator] event in
                await orchestrator.handle(hotkeyEvent: event)
            }
        } catch {
            await setStartupFailure(error.localizedDescription)
            return
        }

        // Poll the orchestrator so the menu-bar icon reflects timer-driven
        // transitions (short-press finalize, hands-free promote) without a
        // dedicated event stream from the orchestrator. 200 ms is well below
        // human notice and trivially cheap.
        statusPollTask = Task { [orchestrator, state] in
            while !Task.isCancelled {
                let capturing = await orchestrator.isCapturing()
                await MainActor.run {
                    if case .startupFailed = state.status { return }
                    state.status = capturing ? .listening : .idle
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    func shutdown() async {
        statusPollTask?.cancel()
        statusPollTask = nil
        await hotkeySource.stop()
        started = false
    }

    @MainActor
    private func setStartupFailure(_ message: String) {
        state.status = .startupFailed(message)
        state.lastError = message
    }
}
