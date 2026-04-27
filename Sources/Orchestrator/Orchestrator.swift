import Foundation
import Core
import Audio
import STTCore
import Hotkey
import Injector
import Usage

/// Top-level dictation orchestrator. Wires the activation FSM to audio capture,
/// the STT provider, the injector, usage tracking, and a timer scheduler.
///
/// ## Flow
/// 1. External event source (hotkey tap, gesture, test driver) calls
///    `handle(hotkeyEvent:)` with a `HotkeyEvent`.
/// 2. The FSM produces a list of `HotkeyOutput` values.
/// 3. The orchestrator applies each output sequentially, owning side effects:
///    opening/closing STT sessions, scheduling timers, injecting text.
/// 4. Audio frames flow from `AudioCapturing` into the active STT session via
///    a long-lived forwarder Task started lazily on first dictation.
///
/// ## Concurrency
/// Single-actor; all state mutations are serialized. The audio forwarder runs
/// in a background Task and re-enters the actor for every frame to forward.
/// Timer expirations also re-enter via `handle(hotkeyEvent: .timerExpired)`.
public actor Orchestrator {
    private let provider: any SttProvider
    private let injector: any Injector
    private let stateMachine: ActivationStateMachine
    private let usage: UsageTracker
    private let audioCapture: any AudioCapturing
    private let timerScheduler: any TimerScheduler

    private var currentSession: (any SttSession)?
    private var currentMode: ActivationMode = .pressHold
    private var sessionStartedAt: Date?
    private var audioForwarderTask: Task<Void, Never>?
    private var timerToken: TimerToken?

    public init(
        provider: any SttProvider,
        injector: any Injector,
        stateMachine: ActivationStateMachine,
        usage: UsageTracker,
        audioCapture: any AudioCapturing,
        timerScheduler: any TimerScheduler = TaskTimerScheduler()
    ) {
        self.provider = provider
        self.injector = injector
        self.stateMachine = stateMachine
        self.usage = usage
        self.audioCapture = audioCapture
        self.timerScheduler = timerScheduler
    }

    /// Process a hotkey event end-to-end: feed the FSM, apply every resulting
    /// output (synchronously from the caller's perspective — when this returns,
    /// session changes, finalization, and injection are all complete).
    public func handle(hotkeyEvent: HotkeyEvent) async {
        let outputs = await stateMachine.handle(hotkeyEvent)
        for output in outputs {
            await apply(output)
        }
    }

    /// Test/diagnostic: is a dictation session currently active?
    public func isCapturing() -> Bool {
        currentSession != nil
    }

    /// Test/diagnostic: returns the current activation mode if a session is
    /// active, otherwise `nil`.
    public func activeMode() -> ActivationMode? {
        currentSession == nil ? nil : currentMode
    }

    // MARK: - Output dispatch

    private func apply(_ output: HotkeyOutput) async {
        switch output {
        case .startDictation(let mode):
            await startDictation(mode: mode)
        case .stopDictation:
            await finalizeAndInject()
        case .cancelDictation:
            await cancelDictation()
        case .promoteToHandsFree:
            await promoteToHandsFree()
        case .scheduleTimer(let duration):
            await scheduleTimer(after: duration)
        case .cancelTimer:
            await cancelTimer()
        }
    }

    // MARK: - Session lifecycle

    private func startDictation(mode: ActivationMode) async {
        try? await audioCapture.start()
        if audioForwarderTask == nil {
            startAudioForwarder()
        }
        await openSession(mode: mode)
        sessionStartedAt = Date()
    }

    private func openSession(mode: ActivationMode) async {
        do {
            let session = try await provider.open(config: SessionConfig())
            currentSession = session
            currentMode = mode
        } catch {
            // TODO(1.4): surface as a toast and reset the FSM. Logging until
            // we have UI to display this.
            print("[Orchestrator] provider.open failed: \(error)")
        }
    }

    private func finalizeAndInject() async {
        guard let session = currentSession else { return }

        try? await session.endOfStream()

        var injectedText: String?
        for await event in session.events {
            if case .final(let text, _) = event {
                injectedText = text
                break
            }
        }

        await session.close()
        currentSession = nil

        if let text = injectedText, !text.isEmpty {
            try? await injector.inject(text: text, hint: .auto)
        }

        await audioCapture.stop()

        if let started = sessionStartedAt {
            let durationMs = UInt64(max(0, Date().timeIntervalSince(started)) * 1000)
            await usage.recordSession(durationMs: durationMs, provider: provider.name)
        }
        sessionStartedAt = nil
    }

    private func cancelDictation() async {
        if let session = currentSession {
            await session.close()
        }
        currentSession = nil
        await audioCapture.stop()
        sessionStartedAt = nil
    }

    private func promoteToHandsFree() async {
        // Discard the speculative session: close without EOS, no inject.
        // Audio capture continues; we open a fresh hands-free session.
        if let session = currentSession {
            await session.close()
        }
        currentSession = nil
        await openSession(mode: .handsFree)
    }

    // MARK: - Audio forwarding

    private func startAudioForwarder() {
        let frames = audioCapture.frames
        audioForwarderTask = Task { [weak self] in
            for await frame in frames {
                await self?.forwardFrameIfActive(frame)
            }
        }
    }

    private var forwardedFrames: Int = 0

    private func forwardFrameIfActive(_ frame: AudioFrame) async {
        guard let session = currentSession else { return }
        do {
            try await session.pushAudio(frame.samples)
            forwardedFrames += 1
            // Log every ~1 s of audio (50 frames @ 20 ms each).
            if forwardedFrames % 50 == 0 {
                print("[Orchestrator] forwarded \(forwardedFrames) audio frames so far")
            }
        } catch {
            print("[Orchestrator] pushAudio failed: \(error)")
        }
    }

    // MARK: - Timer

    private func scheduleTimer(after duration: Duration) async {
        if let oldToken = timerToken {
            await timerScheduler.cancel(oldToken)
        }
        let token = await timerScheduler.schedule(after: duration) { [weak self] in
            await self?.timerFired()
        }
        timerToken = token
    }

    private func cancelTimer() async {
        if let token = timerToken {
            await timerScheduler.cancel(token)
            timerToken = nil
        }
    }

    private func timerFired() async {
        timerToken = nil
        await handle(hotkeyEvent: .timerExpired)
    }
}
