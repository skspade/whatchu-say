import Foundation
import os
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
/// Hotkey events and timer expirations take a FIFO command gate, so one is
/// fully applied before the next starts even though applying it suspends.
public actor Orchestrator {
    /// Lifecycle event stream consumed by UI (HUD, menu bar). See
    /// `OrchestratorEvent` for what's emitted and when.
    public nonisolated let events: AsyncStream<OrchestratorEvent>
    private nonisolated let eventsContinuation: AsyncStream<OrchestratorEvent>.Continuation

    private static let log = AppLogger.logger(for: .orchestrator)

    private let provider: any SttProvider
    private let injector: any Injector
    private let stateMachine: ActivationStateMachine
    private let usage: UsageTracker
    private let audioCapture: any AudioCapturing
    private let timerScheduler: any TimerScheduler
    private let sessionConfig: SessionConfig
    /// Hard cap on how long `awaitFinal()` will block after EOS waiting for
    /// the server's committed transcript. The real provider occasionally
    /// drops the WebSocket without sending a close frame, in which case the
    /// OS TCP layer can take 10–15 s to surface the failure. Bounding the
    /// wait here keeps the HUD responsive; on timeout we inject whatever
    /// text we've already received (committed segments + the last
    /// in-progress partial) rather than dropping the transcription.
    private let finalizeTimeout: Duration

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
    /// Single waiter for `finalizeAndInject` to suspend on while waiting for
    /// the committed transcript. Resumed by `handleSessionEvent` (post-commit
    /// `.final` arrived), `handleSessionStreamEnded` (server closed after EOS),
    /// or `closeCurrentSession` (cancel/teardown).
    private var finalizationWaiter: CheckedContinuation<Void, Never>?
    /// Set when `handleSessionStreamEnded` runs, so a late `awaitFinal()`
    /// caller can return the accumulated text synchronously instead of
    /// dangling on a continuation that will never be resumed.
    private var eventsStreamFinished: Bool = false
    /// Set when a `.final` event arrives while `finalizing` is true — i.e.
    /// the committed transcript in response to our EOS commit. Lets
    /// `awaitFinal()` return immediately without waiting for the events
    /// stream to finish (WebSocket close), which can be delayed.
    private var postCommitFinalReceived: Bool = false
    /// Set when any `.partial` event arrives on the current session. Used by
    /// `finalizeAndInject` to short-circuit when the server never recognized
    /// any speech: in that case sending EOS would just stall awaiting an
    /// `insufficient_audio_activity` error (~10 s on ElevenLabs), so we tear
    /// the session down immediately instead. Cleared on session swap.
    private var partialsReceived: Bool = false
    /// Text of the most recent `.partial` event on the current session.
    /// Overwritten on each new partial; cleared when a `.final` consumes
    /// the in-progress segment, and on session swap. Used as the fallback
    /// commit text when `awaitFinal()` times out before the server sends
    /// a `committed_transcript` — the user saw this text in the HUD and
    /// expects it to be pasted.
    private var currentPartial: String = ""
    /// True from the first line of `finalizeAndInject` until it returns. Lets
    /// `handleSessionStreamEnded` distinguish "expected close after EOS"
    /// (defer to finalize) from "unexpected teardown" (run interrupt+reset).
    private var finalizing: Bool = false
    /// Resumed by the audio forwarder when it consumes the end-of-session
    /// sentinel frame yielded by `audioCapture.stop()`. Used by
    /// `stopAndDrainAudio` to know all captured frames have been forwarded
    /// to the session before we send `endOfStream`.
    private var audioDrainWaiter: CheckedContinuation<Void, Never>?
    /// True while `stopAndDrainAudio()` is between calling `audioCapture.stop()`
    /// and observing the end-of-session sentinel or another teardown signal.
    private var stoppingAndDrainingAudio = false
    /// Latched when the drain-complete signal arrives before
    /// `audioDrainWaiter` is installed. Prevents losing the sentinel during
    /// actor reentrancy while awaiting `audioCapture.stop()`.
    private var audioDrainComplete = false
    /// FIFO gate for hotkey events and timer expirations. Applying an event
    /// suspends (opening a session, draining audio, awaiting the committed
    /// transcript), and without the gate actor reentrancy let a key press
    /// start a session mid-finalize — the finalize then closed it. Session
    /// events and teardown signals don't take the gate: finalize waits on them.
    private var commandInFlight = false
    private var commandWaiters: [CheckedContinuation<Void, Never>] = []
    /// Bumped whenever the FSM timer is scheduled or cancelled. A timer whose
    /// sleep finished just as it was cancelled may already be queued on the
    /// command gate; a stale generation drops that expiry instead of feeding
    /// the FSM a `timerExpired` it no longer expects.
    private var timerGeneration: UInt64 = 0

    public init(
        provider: any SttProvider,
        injector: any Injector,
        stateMachine: ActivationStateMachine,
        usage: UsageTracker,
        audioCapture: any AudioCapturing,
        timerScheduler: any TimerScheduler = TaskTimerScheduler(),
        sessionConfig: SessionConfig = SessionConfig(),
        finalizeTimeout: Duration = .seconds(3)
    ) {
        self.provider = provider
        self.injector = injector
        self.stateMachine = stateMachine
        self.usage = usage
        self.audioCapture = audioCapture
        self.timerScheduler = timerScheduler
        self.sessionConfig = sessionConfig
        self.finalizeTimeout = finalizeTimeout
        let (stream, continuation) = AsyncStream<OrchestratorEvent>.makeStream()
        self.events = stream
        self.eventsContinuation = continuation
    }

    /// Process a hotkey event end-to-end: feed the FSM, apply every resulting
    /// output (synchronously from the caller's perspective — when this returns,
    /// session changes, finalization, and injection are all complete).
    public func handle(hotkeyEvent: HotkeyEvent) async {
        await beginCommand()
        defer { endCommand() }
        await process(hotkeyEvent)
    }

    private func process(_ hotkeyEvent: HotkeyEvent) async {
        Self.log.debug("handle hotkeyEvent: \(String(describing: hotkeyEvent), privacy: .public)")
        let outputs = await stateMachine.handle(hotkeyEvent)
        for output in outputs {
            await apply(output)
        }
    }

    private func beginCommand() async {
        guard commandInFlight else {
            commandInFlight = true
            return
        }
        await withCheckedContinuation { commandWaiters.append($0) }
    }

    /// Hand the gate straight to the next waiter, so no new caller can barge
    /// in ahead of it, or release it.
    private func endCommand() {
        if commandWaiters.isEmpty {
            commandInFlight = false
        } else {
            commandWaiters.removeFirst().resume()
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
        Self.log.debug("apply \(String(describing: output), privacy: .public)")
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
            Self.log.error("provider.open failed: \(error.localizedDescription, privacy: .public)")
            eventsContinuation.yield(.error(text: "Failed to open session: \(error.localizedDescription)"))
        }
    }

    private func finalizeAndInject() async {
        guard let session = currentSession else {
            Self.log.debug("finalizeAndInject: no current session, bailing")
            return
        }
        Self.log.debug("finalizeAndInject ENTER (epoch=\(self.sessionEpoch))")
        finalizing = true
        defer {
            finalizing = false
            Self.log.debug("finalizeAndInject EXIT")
        }

        // Stop audio capture and wait for the forwarder to drain every
        // captured frame into the session BEFORE committing. Without this,
        // the tail of long transcripts arrives at the server after the
        // commit signal and is excluded from the committed transcript.
        await stopAndDrainAudio()
        // After every suspension below, the session may have been torn down
        // by `handleSessionStreamEnded` (server-side error etc.), which has
        // already emitted `.sessionEnded(nil)` and reset the FSM. Bail out
        // quietly to avoid a duplicate `.sessionEnded` and a doomed `awaitFinal`.
        if currentSession == nil {
            Self.log.debug("finalizeAndInject: session gone after drain, bailing")
            return
        }

        // Fast path: the server emitted neither a `partial_transcript` nor
        // a `committed_transcript`, so it never recognized any speech.
        // Sending EOS here would block `awaitFinal` until the server's
        // `insufficient_audio_activity` error arrives, which ElevenLabs
        // takes ~10 s to emit. Skip EOS and tear down immediately so the
        // next hotkey press isn't gated on that wait. `accumulatedFinal`
        // covers the multi-segment auto-VAD case where a pause-segment
        // commit arrived without any preceding partial — still worth
        // sending EOS to flush.
        if !partialsReceived && accumulatedFinal.isEmpty {
            Self.log.debug("finalizeAndInject: no server activity, skipping EOS")
            await closeCurrentSession()
            if let started = sessionStartedAt {
                let durationMs = UInt64(max(0, Date().timeIntervalSince(started)) * 1000)
                await usage.recordSession(durationMs: durationMs, provider: provider.name)
            }
            sessionStartedAt = nil
            eventsContinuation.yield(.sessionEnded(injectedText: nil))
            return
        }

        try? await session.endOfStream()
        if currentSession == nil {
            Self.log.debug("finalizeAndInject: session gone after EOS, bailing")
            return
        }
        eventsContinuation.yield(.finalizing)

        let finalText = await awaitFinal()
        Self.log.debug("finalizeAndInject: awaitFinal returned \(finalText == nil ? "nil" : "<text>", privacy: .public)")
        if currentSession == nil {
            Self.log.debug("finalizeAndInject: session gone after awaitFinal, bailing")
            return
        }

        await closeCurrentSession()

        let injected: String?
        if let text = finalText, !text.isEmpty {
            Self.log.debug("finalizeAndInject INJECTING (\(text.count) chars)")
            try? await injector.inject(text: text, hint: .auto)
            Self.log.debug("finalizeAndInject: injection complete")
            injected = text
        } else {
            Self.log.debug("finalizeAndInject: nothing to inject")
            injected = nil
        }

        if let started = sessionStartedAt {
            let durationMs = UInt64(max(0, Date().timeIntervalSince(started)) * 1000)
            await usage.recordSession(durationMs: durationMs, provider: provider.name)
        }
        sessionStartedAt = nil
        Self.log.debug("finalizeAndInject yielding .sessionEnded")
        eventsContinuation.yield(.sessionEnded(injectedText: injected))
    }

    /// Stop audio capture and suspend until the forwarder has consumed every
    /// frame yielded for this session, including the end-of-session sentinel.
    /// Safe to call when no frames are buffered — the sentinel still flows
    /// through and resumes us immediately.
    private func stopAndDrainAudio() async {
        stoppingAndDrainingAudio = true
        audioDrainComplete = false
        defer {
            stoppingAndDrainingAudio = false
            audioDrainComplete = false
        }
        await audioCapture.stop()
        if audioDrainComplete { return }
        await withCheckedContinuation { cont in
            if audioDrainComplete {
                cont.resume()
            } else {
                audioDrainWaiter = cont
            }
        }
    }

    private func completeAudioDrainWait() {
        guard let waiter = audioDrainWaiter else {
            if stoppingAndDrainingAudio {
                audioDrainComplete = true
            }
            return
        }
        audioDrainWaiter = nil
        audioDrainComplete = true
        waiter.resume()
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
        await cancelTimer()
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
        postCommitFinalReceived = false
        partialsReceived = false
        currentPartial = ""
        completeAudioDrainWait()
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
        guard epoch == sessionEpoch else {
            Self.log.debug("streamEnded: stale epoch \(epoch) vs \(self.sessionEpoch), skipping")
            return
        }
        Self.log.debug("streamEnded epoch=\(epoch) finalizing=\(self.finalizing) waiter=\(self.finalizationWaiter != nil)")
        eventsStreamFinished = true
        if let waiter = finalizationWaiter {
            finalizationWaiter = nil
            Self.log.debug("streamEnded: resuming finalization waiter")
            waiter.resume()
            return
        }
        if finalizing {
            Self.log.debug("streamEnded: finalizing in progress, resuming drain waiter if present")
            completeAudioDrainWait()
            return
        }
        Self.log.warning("streamEnded: unexpected teardown — running interruptAndReset")
        await interruptAndReset()
    }

    private func handleSessionEvent(_ event: SttEvent) {
        switch event {
        case .partial(let text, _):
            partialsReceived = true
            currentPartial = text
            eventsContinuation.yield(.partial(text: text))
        case .final(let text, _):
            guard !text.isEmpty else { return }
            Self.log.debug(".final received (\(text.count) chars, finalizing=\(self.finalizing))")
            if accumulatedFinal.isEmpty {
                accumulatedFinal = text
            } else {
                accumulatedFinal += " " + text
            }
            // The in-progress partial just got committed into accumulatedFinal —
            // drop it so the timeout-fallback path can't double-emit it on top
            // of the committed text.
            currentPartial = ""
            if finalizing {
                postCommitFinalReceived = true
                if let waiter = finalizationWaiter {
                    finalizationWaiter = nil
                    Self.log.debug(".final: resuming finalization waiter")
                    waiter.resume()
                } else {
                    Self.log.debug(".final: no waiter, flag set for sync pickup")
                }
            }
        case .warning(let message):
            eventsContinuation.yield(.error(text: message))
        case .providerInfo:
            break
        }
    }

    /// Suspend until the committed transcript arrives (post-commit `.final`)
    /// or the session's events stream finishes, then return the accumulated
    /// transcript. Returns `nil` if no `.final` events ever arrived AND no
    /// partial was in flight when the session was torn down.
    ///
    /// On timeout the suspension also resumes — `awaitFinal` then falls back
    /// to whatever text is in hand: committed segments first, plus the most
    /// recent in-progress partial. This is the recovery path for the
    /// pathological "server stopped responding mid-finalize" case where the
    /// TCP layer takes 10–15 s to notice the WebSocket is dead; without the
    /// fallback the user would lose a transcript they could already see on
    /// screen.
    private func awaitFinal() async -> String? {
        Self.log.debug("awaitFinal postCommit=\(self.postCommitFinalReceived) streamFinished=\(self.eventsStreamFinished)")
        if !eventsStreamFinished && !postCommitFinalReceived {
            let timeoutToken = await timerScheduler.schedule(after: finalizeTimeout) { [weak self] in
                await self?.fireFinalizeTimeout()
            }
            if !eventsStreamFinished && !postCommitFinalReceived {
                Self.log.debug("awaitFinal: suspending on continuation")
                await withCheckedContinuation { continuation in
                    if eventsStreamFinished || postCommitFinalReceived {
                        continuation.resume()
                    } else {
                        finalizationWaiter = continuation
                    }
                }
            }
            await timerScheduler.cancel(timeoutToken)
            Self.log.debug("awaitFinal resumed postCommit=\(self.postCommitFinalReceived) streamFinished=\(self.eventsStreamFinished)")
        }
        let combined: String
        if !accumulatedFinal.isEmpty && !currentPartial.isEmpty {
            combined = accumulatedFinal + " " + currentPartial
        } else if !accumulatedFinal.isEmpty {
            combined = accumulatedFinal
        } else {
            combined = currentPartial
        }
        accumulatedFinal = ""
        currentPartial = ""
        eventsStreamFinished = false
        postCommitFinalReceived = false
        return combined.isEmpty ? nil : combined
    }

    /// Timer callback for the finalize-after-EOS timeout. Resumes the
    /// finalization waiter if it's still pending so `awaitFinal()` can
    /// return whatever text is in hand instead of blocking indefinitely
    /// on a half-dead WebSocket. No-op if the waiter was already resumed
    /// by a `.final` event or the session's stream finishing first.
    private func fireFinalizeTimeout() async {
        if let waiter = finalizationWaiter {
            finalizationWaiter = nil
            Self.log.warning("finalize timed out after \(String(describing: self.finalizeTimeout)) — falling back to accumulated/partial text")
            waiter.resume()
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
            completeAudioDrainWait()
            return
        }
        guard let session = currentSession else { return }
        do {
            try await session.pushAudio(frame.samples)
            forwardedFrames += 1
            // Log every ~1 s of audio (50 frames @ 20 ms each).
            if forwardedFrames % 50 == 0 {
                Self.log.debug("forwarded \(self.forwardedFrames) audio frames so far")
            }
        } catch SttError.cancelled {
            // Expected during normal teardown — the session was closed
            // out from under the forwarder (cancel, finalize, promote).
            // The close path owns emitting `.sessionEnded`.
        } catch {
            Self.log.error("pushAudio failed: \(error.localizedDescription, privacy: .public)")
            // A non-cancelled send failure means the session's transport
            // is dead. The provider's receive loop may be stuck in
            // `receive()` and never surface this via its events stream,
            // which would leave the app wedged in listening mode until
            // restart. Tear the session down proactively so the existing
            // recovery flow resets listening state. Skipped during
            // finalize: the forwarder is draining into a half-dead
            // session and `finalizeTimeout` already recovers that path;
            // resetting here would race `finalizeAndInject`.
            if !finalizing {
                eventsContinuation.yield(
                    .error(text: "Connection lost: \(error.localizedDescription)")
                )
                await interruptAndReset()
            }
        }
    }

    // MARK: - Timer

    private func scheduleTimer(after duration: Duration) async {
        await cancelTimer()
        let generation = timerGeneration
        timerToken = await timerScheduler.schedule(after: duration) { [weak self] in
            await self?.timerFired(generation: generation)
        }
    }

    private func cancelTimer() async {
        timerGeneration &+= 1
        if let token = timerToken {
            await timerScheduler.cancel(token)
            timerToken = nil
        }
    }

    private func timerFired(generation: UInt64) async {
        await beginCommand()
        defer { endCommand() }
        guard generation == timerGeneration else {
            Self.log.debug("timerFired: stale generation \(generation), dropping")
            return
        }
        timerToken = nil
        await process(.timerExpired)
    }
}
