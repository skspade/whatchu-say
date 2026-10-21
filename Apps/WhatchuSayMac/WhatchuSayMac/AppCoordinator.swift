import Foundation
import AppKit
import Audio
import Core
import Hotkey
import Injector
import Meeting
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
        case needsSetup
        case startupFailed(String)
    }
    var status: Status = .idle
    var lastError: String?
    /// Set when whatchu-say can't proceed because the OS denied a
    /// permission. The menu surfaces a "Fix in System Settings…" button
    /// pointing at the relevant Privacy pane. Cleared on the next
    /// successful inject (proves recovery) or via manual dismiss.
    var permissionIssue: PermissionDeepLink?
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
    let recentTranscripts: RecentTranscriptsStore
    let errorLog: ErrorLogStore
    let meetingsCoordinator: MeetingsCoordinator?
    private let orchestrator: Orchestrator
    private let hotkeySource: HotkeySourceMac
    private let audio: AVAudioCapture
    private let hud: HUDController
    private let sleepWake: SleepWakeObserver
    private let audioConfig: AudioConfigurationObserver
    private var eventTask: Task<Void, Never>?
    private var started = false

    init(
        apiKey: String,
        state: AppState,
        configStore: ConfigStore,
        recentTranscripts: RecentTranscriptsStore,
        errorLog: ErrorLogStore
    ) {
        self.state = state
        self.recentTranscripts = recentTranscripts
        self.errorLog = errorLog

        // Snapshot the current config — these subsystems consume plain values,
        // not the store itself. Live-reconfig wiring lands when the Settings
        // panes ship (per docs/PLAN_SETTINGS.md §6 step 9 onward).
        let appConfig = configStore.config

        let provider = ElevenLabsProvider(apiKey: apiKey, noVerbatim: appConfig.provider.noVerbatim)
        let selector = StrategySelector(
            defaultStrategy: appConfig.injection.defaultStrategy,
            typeMaxChars: Int(appConfig.injection.typeMaxCharsForAuto),
            terminalAllowlist: TerminalAllowlist.defaults
                .union(appConfig.injection.terminalAllowlist),
            perAppOverrides: appConfig.injection.perAppOverrides
        )
        let injector = InjectorMac(
            selector: selector,
            restoreClipboard: !appConfig.injection.leaveOnClipboard
        )
        let stateMachine = ActivationStateMachine()
        let usage = UsageTracker()
        let audio = AVAudioCapture()
        self.audio = audio
        self.orchestrator = Orchestrator(
            provider: provider,
            injector: injector,
            stateMachine: stateMachine,
            usage: usage,
            audioCapture: audio,
            sessionConfig: SessionConfig(
                language: appConfig.provider.language,
                model: appConfig.provider.model,
                hints: appConfig.provider.hints,
                noVerbatim: appConfig.provider.noVerbatim
            )
        )
        let bindings = HotkeyConfigTranslator.bindings(from: appConfig.hotkey)
        self.hotkeySource = HotkeySourceMac(
            activation: bindings.activation,
            cancel: bindings.cancel
        )
        self.hud = HUDController()
        let orchestrator = self.orchestrator
        self.sleepWake = SleepWakeObserver { [orchestrator] in
            await orchestrator.handleSystemSleep()
        }
        self.audioConfig = AudioConfigurationObserver { [orchestrator, audio] engineID in
            // Only the dictation engine matters; a meeting recording's
            // engines changing must not abort a dictation.
            guard let engineID, await audio.isCurrentEngine(engineID) else { return }
            await orchestrator.handleAudioInterruption()
        }

        do {
            self.meetingsCoordinator = try MeetingsCoordinator(apiKey: apiKey, configStore: configStore)
        } catch {
            self.meetingsCoordinator = nil
            state.lastError = "Meeting transcription unavailable: \(error)"
        }
    }

    func start() async {
        guard !started else { return }
        started = true

        do {
            try await hotkeySource.start { [orchestrator] event in
                await orchestrator.handle(hotkeyEvent: event)
            }
        } catch HotkeySourceError.accessibilityDenied {
            let permission = PermissionDeepLink.accessibility
            state.status = .startupFailed(permission.errorMessage)
            state.lastError = permission.errorMessage
            state.permissionIssue = permission
            errorLog.record(text: "Startup failed: \(permission.errorMessage)")
            return
        } catch {
            let message = error.localizedDescription
            state.status = .startupFailed(message)
            state.lastError = message
            errorLog.record(text: "Startup failed: \(message)")
            return
        }

        hud.attachAudio(rms: audio.rmsLevels)
        sleepWake.start()
        audioConfig.start()

        eventTask = Task { [orchestrator, state, hud, recentTranscripts, errorLog, hotkeySource] in
            for await event in orchestrator.events {
                hud.handle(event: event)
                Self.applyToAppState(event, state: state)
                Self.applyToRecentTranscripts(event, store: recentTranscripts)
                Self.applyToErrorLog(event, store: errorLog)
                await Self.applyToHotkeyGate(event, source: hotkeySource)
            }
        }
    }

    /// Toggle the hotkey source's cancel-key consumption gate so Esc is
    /// swallowed only while a session is live. Driven from orchestrator
    /// lifecycle events so cancellation paths (which also emit
    /// `.sessionEnded`) close the gate without extra plumbing.
    private static func applyToHotkeyGate(
        _ event: OrchestratorEvent,
        source: HotkeySourceMac
    ) async {
        switch event {
        case .sessionStarted:
            await source.setDictating(true)
        case .sessionEnded:
            await source.setDictating(false)
        case .partial, .finalizing, .error, .permissionDenied:
            break
        }
    }

    /// Copy a transcript's text to the system clipboard so the user can
    /// paste it manually with `Cmd+V`. Replaces clipboard contents
    /// without restoring (the user explicitly chose to put this on the
    /// clipboard — different intent from the live-injection paste flow).
    /// Static because it depends on no instance state and the menu must
    /// be able to copy regardless of coordinator state (e.g., during
    /// `.needsSetup` when no coordinator exists).
    static func copyToPasteboard(_ entry: TranscriptEntry) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(entry.text, forType: .string)
    }

    /// Copy an error-log entry's text to the system clipboard. Same shape
    /// as `copyToPasteboard(TranscriptEntry)` so menu wiring is symmetric.
    static func copyToPasteboard(_ entry: ErrorLogEntry) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(entry.text, forType: .string)
    }

    func shutdown() async {
        eventTask?.cancel()
        eventTask = nil
        hud.detach()
        sleepWake.stop()
        audioConfig.stop()
        await hotkeySource.stop()
        started = false
    }

    /// Drive `AppState` from orchestrator lifecycle events instead of polling.
    /// Static so the consumer Task doesn't need to capture self. Internal
    /// (not private) so tests can drive it without standing up the
    /// orchestrator.
    ///
    /// `lastError` lifecycle: an `.error` event sets it; the next
    /// `.sessionEnded` carrying injected text clears it (the user
    /// successfully recovered). Cancellations and empty finals
    /// (`.sessionEnded(injectedText: nil)`) do **not** clear it — those don't
    /// prove the system is healthy. Manual dismiss is wired separately
    /// through the menu.
    static func applyToAppState(_ event: OrchestratorEvent, state: AppState) {
        switch state.status {
        case .startupFailed, .needsSetup: return
        default: break
        }
        switch event {
        case .sessionStarted:
            state.status = .listening
        case .sessionEnded(let text):
            state.status = .idle
            if text != nil {
                state.lastError = nil
                state.permissionIssue = nil
            }
        case .error(let text):
            state.lastError = text
        case .permissionDenied(let kind):
            let permission = Self.deepLink(for: kind)
            state.permissionIssue = permission
            state.lastError = permission.errorMessage
        case .partial, .finalizing:
            break
        }
    }

    private static func deepLink(for kind: PermissionKind) -> PermissionDeepLink {
        switch kind {
        case .microphone: return .microphone
        }
    }

    /// Record an injected transcript to the recent-transcripts store.
    /// Internal (not private) so the store-recording contract is unit-
    /// testable. The orchestrator already filters empty finals
    /// (`Orchestrator.swift:135-160`), so a non-nil `injectedText` is
    /// guaranteed non-empty.
    static func applyToRecentTranscripts(
        _ event: OrchestratorEvent,
        store: RecentTranscriptsStore
    ) {
        if case .sessionEnded(let text?) = event {
            store.record(text: text)
        }
    }

    /// Record runtime errors to the error-log store. Only `.error` events
    /// are persisted; other lifecycle events are no-ops. Startup-time
    /// errors (hotkey tap install failure, keychain write failure) bypass
    /// the orchestrator and call `errorLog.record(text:)` directly.
    static func applyToErrorLog(
        _ event: OrchestratorEvent,
        store: ErrorLogStore
    ) {
        if case .error(let text) = event {
            store.record(text: text)
        }
    }
}
