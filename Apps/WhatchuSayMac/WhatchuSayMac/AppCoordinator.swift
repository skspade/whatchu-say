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
/// - `start()` spins up the hotkey tap and the orchestrator-event consumer.
///   Re-entrant calls are no-ops.
/// - `shutdown()` tears down the hotkey tap and HUD subscriptions.
@MainActor
final class AppCoordinator {
    let state: AppState
    private let orchestrator: Orchestrator
    private let hotkeySource: HotkeySourceMac
    private let audio: AVAudioCapture
    private let hud: HUDController
    private var eventTask: Task<Void, Never>?
    private var started = false

    init(apiKey: String, state: AppState) {
        self.state = state
        let provider = ElevenLabsProvider(apiKey: apiKey)
        let injector = InjectorMac()
        let stateMachine = ActivationStateMachine()
        let usage = UsageTracker()
        let audio = AVAudioCapture()
        self.audio = audio
        self.orchestrator = Orchestrator(
            provider: provider,
            injector: injector,
            stateMachine: stateMachine,
            usage: usage,
            audioCapture: audio
        )
        self.hotkeySource = HotkeySourceMac()
        self.hud = HUDController()
    }

    func start() async {
        guard !started else { return }
        started = true

        do {
            try await hotkeySource.start { [orchestrator] event in
                await orchestrator.handle(hotkeyEvent: event)
            }
        } catch {
            state.status = .startupFailed(error.localizedDescription)
            state.lastError = error.localizedDescription
            return
        }

        hud.attachAudio(rms: audio.rmsLevels)

        eventTask = Task { [orchestrator, state, hud] in
            for await event in orchestrator.events {
                hud.handle(event: event)
                Self.applyToAppState(event, state: state)
            }
        }
    }

    func shutdown() async {
        eventTask?.cancel()
        eventTask = nil
        hud.detach()
        await hotkeySource.stop()
        started = false
    }

    /// Drive `AppState` from orchestrator lifecycle events instead of polling.
    /// Static so the consumer Task doesn't need to capture self.
    private static func applyToAppState(_ event: OrchestratorEvent, state: AppState) {
        if case .startupFailed = state.status { return }
        switch event {
        case .sessionStarted:
            state.status = .listening
        case .sessionEnded(let injectedText):
            state.status = .idle
            if let text = injectedText, !text.isEmpty {
                state.lastTranscript = text
            }
        case .error(let text):
            state.lastError = text
        case .partial, .finalizing:
            break
        }
    }
}
