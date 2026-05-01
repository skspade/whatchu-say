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
    private let sessionConfig: SessionConfig

    private var currentSession: (any SttSession)?
    private var currentMode: ActivationMode = .pressHold
    private var sessionStartedAt: Date?
    private var audioForwarderTask: Task<Void, Never>?
    private var sessionEventTask: Task<Void, Never>?
    private var timerToken: TimerToken?

    /// Bumped on every `openSession` and `closeCurrentSession`. Lets the
    /// session-events consumer detect "the events stream finished on its own"
    /// (epoch unchanged → unexpected) vs "we closed it" (epoch bumped → no-op).
    private var sessionEpoch: UInt64 = 0

    /// Accumulator for every `.final` event from the current session. The
    /// streaming provider commits a separate `committed_transcript` per
    /// pause-segment, plus one final commit in response to `endOfStream` —
    /// they must all be concatenated, not overwritten. Cleared on session
    /// swap or after `awaitFinal()` consumes it.
    private var accumulatedFinal: String = ""
    /// Single waiter for `finalizeAndInject` to suspend on while the session's
    /// events stream drains. Resumed by `handleSessionStreamEnded` (server
    /// closed after EOS) or by `closeCurrentSession` (cancel/teardown).
    private var finalizationWaiter: CheckedContinuation<Void, Never>?
    /// Set when `handleSessionStreamEnded` runs, so a late `awaitFinal()`
    /// caller can return the accumulated text synchronously instead of
    /// dangling on a continuation that will never be resumed.
    private var eventsStreamFinished: Bool = false
    /// True from the first line of `finalizeAndInject` until it returns. Lets
    /// `handleSessionStreamEnded` distinguish "expected close after EOS"
    /// (defer to finalize) from "unexpected teardown" (run interrupt+reset).
    private var finalizing: Bool = false
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
        timerScheduler: any TimerScheduler = TaskTimerScheduler(),
        sessionConfig: SessionConfig = SessionConfig()
    ) {
        self.provider = provider
        self.injector = injector
        self.stateMachine = stateMachine
        self.usage = usage
        self.audioCapture = audioCapture
        self.timerScheduler = timerScheduler
        self.sessionConfig = sessionConfig
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
        do {
            try await audioCapture.start()
        } catch AudioCaptureError.permissionDenied {
            // Mic permission denied at the OS level. Abort before opening
            // the provider — no audio means a useless session and a
            // wasted WebSocket. The UI surfaces a fix-it deep-link from
            // the event.
            eventsContinuation.yield(.permissionDenied(kind: .microphone))
            return
        } catch {
            eventsContinuation.yield(
                .error(text: "Audio start failed: \(error.localizedDescription)")
            )
            return
        }
        if audioForwarderTask == nil {
            startAudioForwarder()
        }
        await openSession(mode: mode)
        sessionStartedAt = Date()
    }

    private func openSession(mode: ActivationMode) async {
        do {
            let session = try await provider.open(config: sessionConfig)
            currentSession = session
            currentMode = mode
            sessionEpoch &+= 1
            startSessionEventConsumer(session, epoch: sessionEpoch)
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
        finalizing = true
        defer { finalizing = false }

        // Stop audio capture and wait for the forwarder to drain every
        // captured frame into the session BEFORE committing. Without this,
        // the tail of long transcripts arrives at the server after the
        // commit signal and is excluded from the committed transcript.
        await stopAndDrainAudio()
        // After every suspension below, the session may have been torn down
        // by `handleSessionStreamEnded` (server-side error etc.), which has
        // already emitted `.sessionEnded(nil)` and reset the FSM. Bail out
        // quietly to avoid a duplicate `.sessionEnded` and a doomed `awaitFinal`.
        if currentSession == nil { return }

        try? await session.endOfStream()
        if currentSession == nil { return }
        eventsContinuation.yield(.finalizing)

        let finalText = await awaitFinal()
        if currentSession == nil { return }

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

    /// Force-reset everything in response to a system-level interruption
    /// (currently: `NSWorkspace.willSleepNotification` on Mac).
    ///
    /// Closes the current session if any, stops audio capture, cancels any
    /// pending FSM timer, and resets the activation state machine. If a
    /// session was live, emits one `.sessionEnded(injectedText: nil)` so the
    /// HUD/menu/cancel-key gate clear via the existing event-consumer
    /// plumbing. Idempotent — safe to call when already idle.
    ///
    /// We do **not** record usage for the interrupted session: the user
    /// didn't release the key, and the audio they spoke pre-sleep was lost
    /// when the OS suspended the WebSocket. Treating it like a cancel.
    public func handleSystemSleep() async {
        await interruptAndReset()
    }

    /// Handle a runtime audio-engine configuration change — typically the
    /// default input device switched (headphones plugged/unplugged, BT
    /// headset went away, AirPods kept-but-Bluetooth-dropped). The active
    /// session's audio stream is now bound to a stale device, so the
    /// safest path is to abort the session, surface a clear error, and
    /// let the user re-press the hotkey against the new device.
    ///
    /// Emits a `.error` event BEFORE tearing down so consumers see the
    /// "audio device changed" message land on `lastError` and the
    /// menubar icon flips yellow. The trailing `.sessionEnded(nil)` from
    /// `interruptAndReset` doesn't clear `lastError` (cancel/empty isn't
    /// recovery), so the error sticks until the next successful inject.
    /// No-op if no session is live.
    public func handleAudioInterruption() async {
        guard currentSession != nil else { return }
        eventsContinuation.yield(
            .error(text: "Audio device changed — please retry your dictation.")
        )
        await interruptAndReset()
    }

    /// Shared teardown for "something killed the active session out from under
    /// us" — system sleep, server-side WebSocket close, etc. Closes the
    /// session (which resumes any pending finalize waiters with `nil`), stops
    /// audio, cancels the FSM timer, resets the FSM, and emits a single
    /// `.sessionEnded(nil)` if a session was live.
    private func interruptAndReset() async {
        await cancelDictation()
        if let token = timerToken {
            await timerScheduler.cancel(token)
            timerToken = nil
        }
        await stateMachine.reset()
    }

    private func promoteToHandsFree() async {
        // Discard the speculative session: close without EOS, no inject.
        // Audio capture continues; we open a fresh hands-free session.
        await closeCurrentSession()
        await openSession(mode: .handsFree)
    }

    /// Tear down the current session: cancel its event consumer, close the
    /// session, drop captured-final state, and resume any waiter so it
    /// doesn't dangle.
    private func closeCurrentSession() async {
        // Bump the epoch BEFORE the consumer's events stream finishes so the
        // post-loop `handleSessionStreamEnded` sees a stale epoch and skips
        // the unexpected-teardown path.
        sessionEpoch &+= 1
        sessionEventTask?.cancel()
        sessionEventTask = nil
        if let session = currentSession {
            await session.close()
        }
        currentSession = nil
        accumulatedFinal = ""
        eventsStreamFinished = false
        if let waiter = finalizationWaiter {
            finalizationWaiter = nil
            waiter.resume()
        }
    }

    // MARK: - Session event consumer

    private func startSessionEventConsumer(_ session: any SttSession, epoch: UInt64) {
        sessionEventTask = Task { [weak self] in
            for await event in session.events {
                if Task.isCancelled { return }
                await self?.handleSessionEvent(event)
            }
            // Stream finished. If the orchestrator still owns this session
            // (epoch unchanged), the session died on its own — interrupt and
            // reset so we don't deadlock a subsequent finalize.
            await self?.handleSessionStreamEnded(epoch: epoch)
        }
    }

    /// Called when a session's events stream finishes. Three cases:
    /// 1. We already initiated the close (epoch bumped) — no-op.
    /// 2. `finalizeAndInject` is waiting on the events stream to drain (the
    ///    expected EOS-then-WS-close path) — wake it so it can collect the
    ///    accumulated transcript and own the cleanup.
    /// 3. Unexpected teardown (server error, network drop) — run the same
    ///    recovery flow as `handleSystemSleep`.
    private func handleSessionStreamEnded(epoch: UInt64) async {
        guard epoch == sessionEpoch else { return }
        eventsStreamFinished = true
        if let waiter = finalizationWaiter {
            finalizationWaiter = nil
            waiter.resume()
            return
        }
        if finalizing {
            // Race: stream finished after `endOfStream` but before `awaitFinal`
            // installed its waiter. The flag we just set lets `awaitFinal`
            // return the accumulated text synchronously without dangling.
            return
        }
        await interruptAndReset()
    }

    private func handleSessionEvent(_ event: SttEvent) {
        switch event {
        case .partial(let text, _):
            eventsContinuation.yield(.partial(text: text))
        case .final(let text, _):
            // Accumulate every commit. The streaming provider sends one per
            // pause-segment plus one for the EOS commit; overwriting here
            // would lose every segment except the last to arrive.
            guard !text.isEmpty else { return }
            if accumulatedFinal.isEmpty {
                accumulatedFinal = text
            } else {
                accumulatedFinal += " " + text
            }
        case .warning(let message):
            eventsContinuation.yield(.error(text: message))
        case .providerInfo:
            break
        }
    }

    /// Suspend until the session's events stream finishes (server closes the
    /// connection after the EOS commit), then return the accumulated transcript.
    /// Returns `nil` if no `.final` events ever arrived, or if the session was
    /// torn down before any commit.
    private func awaitFinal() async -> String? {
        if !eventsStreamFinished {
            await withCheckedContinuation { continuation in
                finalizationWaiter = continuation
            }
        }
        let text = accumulatedFinal
        accumulatedFinal = ""
        eventsStreamFinished = false
        return text.isEmpty ? nil : text
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
