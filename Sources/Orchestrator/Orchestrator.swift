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
    /// Lifecycle event stream consumed by UI (HUD, menu bar). See
    /// `OrchestratorEvent` for what's emitted and when.
    public nonisolated let events: AsyncStream<OrchestratorEvent>
    private nonisolated let eventsContinuation: AsyncStream<OrchestratorEvent>.Continuation

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
    private var sessionEventTask: Task<Void, Never>?
    private var timerToken: TimerToken?

    /// Captured final transcript text when it arrives ahead of the
    /// `awaitFinal()` caller. Cleared on consumption or session swap.
    private var pendingFinal: String?
    private var finalWaiters: [CheckedContinuation<String?, Never>] = []
    /// Resumed by the audio forwarder when it consumes the end-of-session
    /// sentinel frame yielded by `audioCapture.stop()`. Used by
    /// `stopAndDrainAudio` to know all captured frames have been forwarded
    /// to the session before we send `endOfStream`.
    private var audioDrainWaiter: CheckedContinuation<Void, Never>?

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
        let (stream, continuation) = AsyncStream<OrchestratorEvent>.makeStream()
        self.events = stream
        self.eventsContinuation = continuation
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
            startSessionEventConsumer(session)
            eventsContinuation.yield(.sessionStarted(mode: mode))
        } catch {
            // TODO(1.4): surface as a toast and reset the FSM. Logging until
            // we have UI to display this.
            print("[Orchestrator] provider.open failed: \(error)")
            eventsContinuation.yield(.error(text: "Failed to open session: \(error.localizedDescription)"))
        }
    }

    private func finalizeAndInject() async {
        guard let session = currentSession else { return }

        // Stop audio capture and wait for the forwarder to drain every
        // captured frame into the session BEFORE committing. Without this,
        // the tail of long transcripts arrives at the server after the
        // commit signal and is excluded from the committed transcript.
        await stopAndDrainAudio()

        try? await session.endOfStream()
        eventsContinuation.yield(.finalizing)

        let finalText = await awaitFinal()

        await closeCurrentSession()

        let injected: String?
        if let text = finalText, !text.isEmpty {
            try? await injector.inject(text: text, hint: .auto)
            injected = text
        } else {
            injected = nil
        }

        if let started = sessionStartedAt {
            let durationMs = UInt64(max(0, Date().timeIntervalSince(started)) * 1000)
            await usage.recordSession(durationMs: durationMs, provider: provider.name)
        }
        sessionStartedAt = nil
        eventsContinuation.yield(.sessionEnded(injectedText: injected))
    }

    /// Stop audio capture and suspend until the forwarder has consumed every
    /// frame yielded for this session, including the end-of-session sentinel.
    /// Safe to call when no frames are buffered — the sentinel still flows
    /// through and resumes us immediately.
    private func stopAndDrainAudio() async {
        await audioCapture.stop()
        await withCheckedContinuation { cont in
            audioDrainWaiter = cont
        }
    }

    private func cancelDictation() async {
        let hadSession = currentSession != nil
        await closeCurrentSession()
        await audioCapture.stop()
        sessionStartedAt = nil
        if hadSession {
            eventsContinuation.yield(.sessionEnded(injectedText: nil))
        }
    }

    private func promoteToHandsFree() async {
        // Discard the speculative session: close without EOS, no inject.
        // Audio capture continues; we open a fresh hands-free session.
        await closeCurrentSession()
        await openSession(mode: .handsFree)
    }

    /// Tear down the current session: cancel its event consumer, close the
    /// session, drop captured-final state, and resume any waiters with `nil`
    /// so they don't dangle.
    private func closeCurrentSession() async {
        sessionEventTask?.cancel()
        sessionEventTask = nil
        if let session = currentSession {
            await session.close()
        }
        currentSession = nil
        pendingFinal = nil
        let waiters = finalWaiters
        finalWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: nil)
        }
    }

    // MARK: - Session event consumer

    private func startSessionEventConsumer(_ session: any SttSession) {
        sessionEventTask = Task { [weak self] in
            for await event in session.events {
                if Task.isCancelled { return }
                await self?.handleSessionEvent(event)
            }
        }
    }

    private func handleSessionEvent(_ event: SttEvent) {
        switch event {
        case .partial(let text, _):
            eventsContinuation.yield(.partial(text: text))
        case .final(let text, _):
            if let waiter = finalWaiters.first {
                finalWaiters.removeFirst()
                waiter.resume(returning: text)
            } else {
                pendingFinal = text
            }
        case .warning(let message):
            eventsContinuation.yield(.error(text: message))
        case .providerInfo:
            break
        }
    }

    /// Suspend until the current session's `.final` arrives. Resumes with
    /// `nil` if the session is torn down before a final lands.
    private func awaitFinal() async -> String? {
        if let text = pendingFinal {
            pendingFinal = nil
            return text
        }
        return await withCheckedContinuation { continuation in
            finalWaiters.append(continuation)
        }
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
        // End-of-session sentinel from `audioCapture.stop()`: all captured
        // frames for the session have been yielded by the time we see this.
        // Resume any drain waiter; do NOT push to the session.
        if frame.samples.isEmpty {
            if let cont = audioDrainWaiter {
                audioDrainWaiter = nil
                cont.resume()
            }
            return
        }
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
