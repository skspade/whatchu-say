# Spike — Zoom / meeting transcription via Mac system audio

| Field | Value |
| --- | --- |
| Status | Drafted; not yet scheduled |
| Last updated | 2026-05-02 |
| Related | [PRD.md](./PRD.md), [TECH_SPEC.md](./TECH_SPEC.md), [ROADMAP.md](./ROADMAP.md) |
| Scope | macOS only. Investigate feasibility, surface design choices, output a recommendation on whether/when to build. No implementation in this spike beyond a throwaway proof-of-capture. |
| Reference apps | Granola, mem, Otter, Cleft — all capture mic + system audio on macOS for meeting transcription. |

---

## 1. Why this exists

I want to record entire Zoom meetings from my Mac (both my mic and the other participants via system audio) and get a transcript / summary the way Granola and mem do. This is a fundamentally different shape from the current app:

| Dimension | Current dictation | Meeting transcription |
| --- | --- | --- |
| Trigger | Push-to-talk / double-tap toggle | Long-running session, manual or detected |
| Audio sources | Single mic stream | Mic **+** system audio (other participants) |
| Duration | Seconds to minutes | 30–90 minutes typical |
| Speakers | One (me) | Many; diarization wanted |
| Output | Inject at cursor | Transcript + summary surface |
| STT economics | Short utterances over WebSocket | Hours of streaming; cost matters |
| Privacy posture | I'm dictating my own words | Recording other people — consent / disclosure required |

This spike answers: *can the existing Swift core absorb this, or is it a separate orchestrator? What are the platform / provider / UX gates?* It does **not** decide product placement on the roadmap — that comes after the spike outputs.

## 2. Open research questions

### 2.1 System audio capture on macOS

What's the right API in 2026? Three candidates, each with tradeoffs:

- **Core Audio Process Tap** (`AudioHardwareCreateProcessTap`, macOS 14.2+). Per-process tap; can target Zoom alone and ignore other audio. This is what Granola moved to. Open: minimum supported macOS, permission model (does TCC gate it? what prompt does the user see?), behavior when target process changes audio device, behavior across Zoom restarts mid-meeting.
- **ScreenCaptureKit audio** (`SCStream` with audio, macOS 13+). Mature, well-documented, but requires Screen Recording permission — heavyweight prompt for a feature that doesn't capture the screen. Open: can we filter to a single process or is it system-wide? Latency? Sample-rate handling?
- **Virtual audio device** (BlackHole, Loopback). Old approach; requires user-side setup. Reject unless the above two are both blocked, but worth noting as a fallback.

Spike output should be a one-paragraph recommendation per option with a concrete pick.

### 2.2 Mic + system audio combination

Two streams need to become one transcript with speaker attribution. Choices:

- **Two parallel STT sessions**, tag transcripts with `source: mic | system`, merge by timestamp. Simple; loses cross-stream diarization.
- **Mix to single channel, single STT**, rely on provider diarization (Deepgram, AssemblyAI). Cheaper streams; depends on provider quality with mixed audio.
- **Two-channel single stream** (mic on L, system on R). Some providers honor channel-as-speaker hints; cleanest if supported.

Open: what does Granola actually do — separate streams or mixed? (Worth ~30 min of decompiling-network-traffic sleuthing or reading their public posts.) What does ElevenLabs realtime support for diarization / multi-channel? If ElevenLabs is a non-starter for this use case, that's a real input to the provider abstraction story.

### 2.3 STT economics & provider fit

ElevenLabs realtime is priced for short bursts. A 60-minute meeting at current rates may be expensive; a 4-hour all-hands is definitely expensive. Open:

- Run the math: per-meeting cost for ElevenLabs vs. Deepgram Nova vs. AssemblyAI Streaming vs. local Whisper (Whisper.cpp / WhisperKit on Apple Silicon).
- Does diarization quality differ enough between providers to outweigh cost? (Deepgram and AssemblyAI both ship diarization; ElevenLabs's story is unclear.)
- Local Whisper is explicitly deferred per [PRD.md](./PRD.md) §4 — but for hours of audio, it may be the only sane economic choice. Spike should re-test that assumption for *this* feature without re-opening it for the dictation flow.

### 2.4 Trigger model

Cross-cutting against the project principle "**No silent automatic behaviors**" ([ROADMAP.md](./ROADMAP.md) cross-phase principles).

- **Manual**: user clicks "Start recording" in menubar / overlay. Predictable, principle-clean, more friction.
- **Detected**: app notices Zoom is in a meeting (CoreAudio process activity + frontmost app, or Zoom's own status if it exposes one) and offers to start. Lower friction, but the offer itself is a notification — is that an acceptable form of "automatic"? Granola does this with a prominent prompt rather than silent capture.
- **Hybrid**: detect + prompt; never start without an explicit confirm.

Spike should propose a concrete trigger UX consistent with the principle. The hybrid pattern is the expected answer; spike validates it.

### 2.5 Live surface vs. post-meeting

Granola shows live notes during the meeting; mem shows transcript after. What surface makes sense here given we already have a floating overlay?

- Live captions in an expanded overlay?
- Live notes window (separate from the overlay)?
- Post-meeting transcript window only — no live UI?

This is mostly a product question, but it has a tech consequence: live UI requires sub-second partial-transcript updates, which constrains provider choice (some batch-only providers are out).

### 2.6 Privacy, consent, and disclosure

Recording other meeting participants raises real legal and ethical issues. Two-party-consent jurisdictions exist. Spike must:

- Identify what disclosure language Granola / mem / Otter use, and what their behavior is in two-party states.
- Decide our v1 stance: is the user responsible for getting consent (with strong in-app reminder), or does the app inject an "I am being recorded" announcement, or is auto-recording in two-party states blocked entirely?
- Confirm what storage / retention policy we want for meeting recordings (current dictation flow doesn't persist audio; this feature presumably does, at least transiently).
- Check whether any of this conflicts with the "no telemetry, local-only" stance in [PRD.md](./PRD.md) §3.4.

### 2.7 Permissions & onboarding

Already have Microphone + Accessibility. Process tap or ScreenCaptureKit will add at least one more permission prompt. Spike should:

- Enumerate the prompts each capture API requires and the exact System Settings panes they live in.
- Sketch how this fits into existing first-run / Settings → Privacy flow — does meeting transcription warrant its own onboarding pane?

### 2.8 Architecture fit

Does this share the existing `Orchestrator` / `STTCore` / `Audio` stack, or is it a parallel `MeetingOrchestrator`?

- Existing `AudioCapture` is single-source, push-to-talk. Multi-source long-running capture is a different lifecycle.
- `STTCore.SessionConfig` assumes one stream per session. Multi-stream would either fan out to N sessions or extend the protocol.
- The activation state machine is built around a single user action; meeting flow has a meeting-start / meeting-end model.

Strong prior: this is a sibling subsystem (`Sources/Meeting/`) that *uses* `STTCore` providers but has its own orchestrator. Spike validates by sketching the type signatures and noting any forced changes to shared code.

### 2.9 Memory & resource budget

PRD §3.4 caps headless Mac at ≤ 80 MB. A live meeting captures 60+ minutes of audio with a partial transcript buffer. Spike should:

- Estimate steady-state RSS for capture + STT WS + transcript buffer.
- Decide whether the existing budget applies to this mode or whether meeting mode gets its own (higher) cap with documented justification.

## 3. Out of scope for the spike

- Final product UX (notes vs. transcript vs. both, summary AI prompt, etc.).
- Calendar integration / meeting auto-detection beyond the trigger-mechanism question.
- Non-Zoom meeting platforms (Meet, Teams, WebEx) — capture approach is app-agnostic at the audio layer, so once it works for one it works for all; no per-app tuning in the spike.
- Implementation of the chosen approach beyond a throwaway proof-of-capture (~50 lines, captures 30 seconds of mic + system audio to a file, confirms both are usable).
- Roadmap placement / scheduling.

## 4. Deliverables

1. **Update to [TECH_SPEC.md](./TECH_SPEC.md)** with a new section (e.g., §13 Meeting transcription) capturing:
   - Chosen system-audio API and rationale.
   - Stream-combination strategy.
   - Provider recommendation for long-form + diarization.
   - Trigger UX.
   - Architecture diagram showing how `Sources/Meeting/` (or whatever it ends up as) sits next to the existing dictation orchestrator.
   - Privacy / consent posture.
2. **Throwaway proof-of-capture** at `Apps/Spike-MeetingCapture/` — same pattern as `Apps/Spike-iOSKeyboard/`. Captures mic + system audio for 30 s, dumps to two `.wav` files, verifies both contain real audio when a Zoom call is active.
3. **Roadmap recommendation** — new milestone, deferred to post-Phase-1, or rejected as out-of-scope. Recorded as a short addition to [ROADMAP.md](./ROADMAP.md) "What's not on the roadmap" or as a new phase entry.

## 5. Effort estimate

3–5 focused days:

- Day 1: API survey (process tap vs. ScreenCaptureKit vs. virtual device), throwaway capture experiments.
- Day 2: Provider survey + cost math + ElevenLabs / Deepgram / AssemblyAI / WhisperKit short tests with sample meeting audio.
- Day 3: Architecture sketch, privacy/consent research (read Granola/mem/Otter terms + a quick legal-blog skim).
- Day 4–5 (buffer): write up TECH_SPEC section + roadmap recommendation.

## 6. Risks / known unknowns

| Risk | Why it matters | Spike mitigation |
| --- | --- | --- |
| Process Tap requires a macOS version newer than my support floor | Forces fallback to ScreenCaptureKit + screen recording prompt | Resolve "what is our support floor" as part of the spike — current Phase 1 docs don't pin one. |
| Provider abstraction doesn't actually fit long-form + diarization | Forces invasive changes to `STTCore` | Spike's architecture sketch must explicitly call out what changes to shared code, even if minor. |
| "No silent automatic behaviors" principle conflicts with detected-meeting trigger | Could push us to manual-only, hurting product feel | Trigger-model section above must produce a concrete answer the principle endorses. |
| Legal disclosure burden in two-party-consent states is heavier than expected | Could make this a non-shippable feature | Privacy section is mandatory output of the spike, not optional. |
| Meeting-mode RSS blows past the 80 MB cap | Either we raise the cap or we get smarter about buffering | Budget estimate is a required deliverable. |

## 7. Decision after the spike

Spike concludes with one of:

- **GO — schedule as new milestone** (with phase placement and rough effort).
- **DEFER — well-scoped but not-now**, recorded under "What's not on the roadmap" with the spike doc linked.
- **NO — fundamental blocker found** (e.g., no viable system-audio API for our support floor, or provider economics make it untenable). Document the blocker so future-me doesn't re-spike it cold.
