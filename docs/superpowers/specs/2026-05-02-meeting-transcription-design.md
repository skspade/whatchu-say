# Meeting transcription — design

| Field | Value |
| --- | --- |
| Status | Draft — derived from a brainstorming session over [SPIKE_MEETING_TRANSCRIPTION.md](../../SPIKE_MEETING_TRANSCRIPTION.md). Spike has not yet executed; this document records the design we expect the spike to validate. |
| Last updated | 2026-05-02 |
| Related | [PRD.md](../../PRD.md), [TECH_SPEC.md](../../TECH_SPEC.md), [ROADMAP.md](../../ROADMAP.md), [SPIKE_MEETING_TRANSCRIPTION.md](../../SPIKE_MEETING_TRANSCRIPTION.md) |
| Scope | macOS only. v1 behavior — record a Zoom (or any conferencing app) meeting from system audio + mic, produce a diarized transcript post-meeting, surface in a transcript view. No live captions, no calendar OAuth, no detection-based triggers. |

---

## 1. Goals & non-goals

### Goals
- Record a meeting from a Mac running a conferencing app (Zoom, Meet, Teams, WebEx — any app that plays audio through Core Audio) by capturing the mic + that app's system audio.
- Produce a single chronological transcript with `me` for the user's words and per-speaker labels (`Alice`, `Bob`, …) for remote participants, using post-meeting batch transcription with diarization.
- Stay consistent with project principles: no silent automatic behaviors, no telemetry, local-only by default, manual user actions trigger every flow.
- Be additive to the existing dictation product — share `STTCore` providers and `ConfigStore`, but do not modify the dictation `Orchestrator`, `AudioCapture`, or activation state machine.

### Non-goals (v1)
- **Live captions / live notes.** Post-meeting only.
- **Calendar OAuth.** Manual attendee entry replaces this for v1; OAuth deferred indefinitely (revisit only if user demand emerges).
- **Detected-meeting triggers.** Pure manual start/stop; detection-and-prompt deferred to v2.
- **Real-time speaker name attribution.** Diarization labels speakers as `Speaker 1/2/3…` in the raw transcript; LLM post-pass maps to attendee names; user can correct.
- **Streaming providers / WebSocket STT.** Batch-only.
- **Voiceprint enrollment across meetings.** Not built; each meeting diarizes independently.
- **Cross-platform.** macOS only. iOS / Linux out of scope.
- **Any non-Zoom-specific tuning.** Capture is at the audio layer and works app-agnostically.

---

## 2. User-visible behavior

### 2.1 Starting a recording
1. User clicks **Start meeting recording** in the menu bar. (A keyboard shortcut for this action is a deferred decision — see §13.)
2. A modal appears with:
   - A reminder line: *"Recording without consent is illegal in some jurisdictions. Confirm participants are aware."*
   - An optional **Attendees** chip-input field (autocomplete from past meetings). User can type `Alice, Bob` or skip.
   - **Start** and **Cancel** buttons.
3. On Start, recording begins immediately. Menu bar shows a recording indicator (red dot + elapsed timer).
4. The modal does **not** show during subsequent meetings if the user has opted out via "don't show consent reminder again" — the reminder text moves to the menu-bar tooltip in that case. (First-run privacy modal explains the legal context regardless.)

### 2.2 During a recording
- Menu bar shows: red dot, elapsed timer, "Stop" button.
- No live transcript UI.
- No popup or notification activity.
- If audio device changes mid-meeting (existing behavior in `AudioCapture`), the meeting session ends with an error surfaced through the existing recent-errors log.

### 2.3 Stopping
- User clicks **Stop** in the menu bar.
- Recording ends. The two audio files (mic + system) are submitted to ElevenLabs Scribe v2 batch.
- Menu bar shows "Transcribing…" state.
- On success, a transcript window opens automatically.

### 2.4 Transcript view
- Title editable (defaults to "Meeting — 2026-05-02 14:32").
- Attendees field: re-editable chip input. Editing here re-runs the LLM name-mapping pass.
- Transcript: chronological list of `[timestamp] [Speaker label]: text`.
- Speaker labels in the raw transcript are `Me`, `Speaker 1`, `Speaker 2`, …
- After LLM mapping pass, labels become `Me`, `Alice`, `Bob`, … (only if attendees were entered and the LLM was confident about a mapping; otherwise they remain `Speaker N`).
- Right-click on a speaker label → "Rename to…" menu, applies to all instances of that speaker in this transcript.
- **Delete transcript** button. **Keep audio** toggle (default off — audio deleted after transcription completes).

### 2.5 Settings → Meetings pane (new)
- **Permission status:** Microphone, Screen & System Audio Recording. Each row links out to System Settings if not granted (mirroring existing fix-it deep-links).
- **Default attendee list behavior:** "Show attendee field at start" (toggle, default on).
- **Consent reminder:** "Show consent reminder before each recording" (toggle, default on). Toggling off corresponds to the opt-out described in §2.1; toggling back on restores the per-recording reminder.
- **Audio retention:** "Delete recorded audio after transcription" (toggle, default on).
- **Storage location:** path to local meeting library, with a "Reveal in Finder" button. No "sync to cloud" option — there is no cloud.

---

## 3. Capture layer

### 3.1 macOS support floor
**macOS 15+** for meeting mode. (Dictation's existing floor is unchanged by this design.) This unlocks `CATapDescription` / Process Tap as the primary capture API and avoids the heavyweight Screen Recording prompt that ScreenCaptureKit would require.

### 3.2 System audio capture
Core Audio Process Tap (`AudioHardwareCreateProcessTap` / `CATapDescription`).

- Tap is created against the **default-output device** with no process restrictions for v1 (captures everything routed through the speakers, which is what the user expects when they say "record this Zoom call"). Per-process tap (Zoom-only) is a v2 refinement; in v1 the user's responsibility is to silence other apps before recording.
- Tap output goes to an `AVAudioFile` writer using **Opus in Ogg container** at 16 kHz mono — the format Scribe v2 accepts and what Granola records to disk.
- TCC permission: `NSScreenCaptureUsageDescription` covers the system-audio bucket on macOS 15+. The Info.plist string explains "to record meeting audio from other apps so it can be transcribed."

### 3.3 Mic capture
A `MicCapture` parallel to existing `AudioCapture`. Same `AVAudioEngine` shape; different lifecycle (long-running, not push-to-talk). Output: separate Opus/Ogg file, 16 kHz mono.

**Implementation note:** the existing `AudioCapture` is push-to-talk and tightly coupled to the dictation `Orchestrator`'s state machine. We do **not** reuse it. `MicCapture` is a sibling type in `Sources/Meeting/`. They may share lower-level helpers (format constants, file writer wrapper) extracted to `Sources/Audio/Common/` if it falls out naturally, but no shared mutable state or lifecycle.

### 3.4 File layout
Per-meeting directory under `~/Library/Application Support/whatchu-say/meetings/<uuid>/`:
- `meta.json` — id, title, started_at, ended_at, attendees, attendee_history_version
- `mic.opus` — user's voice
- `system.opus` — everything that played through default output
- `transcript.json` — Scribe v2 raw output (preserved for debugging / re-mapping)
- `transcript.md` — rendered transcript with current speaker labels

After transcription completes successfully, `mic.opus` and `system.opus` are deleted unless **Keep audio** is toggled on.

---

## 4. Transcription pipeline

```
              ┌──────────────────────────────────────────────────┐
              │              MeetingOrchestrator                 │
              │                                                  │
   Start ──▶  │  1. open MicCapture + SystemAudioCapture         │
              │  2. write to mic.opus + system.opus              │
              │  3. update menu bar state                        │
   Stop  ──▶  │  4. close writers                                │
              │  5. POST mic.opus  → Scribe v2 (single-speaker)  │
              │     POST system.opus → Scribe v2 (diarized)      │
              │  6. merge by timestamp                           │
              │  7. (optional) LLM name-mapping pass             │
              │  8. write transcript.json + transcript.md        │
              │  9. open transcript window                       │
              └──────────────────────────────────────────────────┘
```

### 4.1 Scribe v2 batch — provider integration
- New capability flag on `STTProvider`: `batchTranscription: BatchTranscriptionCapability?`
- `BatchTranscriptionCapability` exposes:
  ```swift
  func transcribe(
      audioFileURL: URL,
      diarize: Bool,
      languageHint: String?
  ) async throws -> BatchTranscriptionResult
  ```
- `BatchTranscriptionResult` contains: `[Segment]` where `Segment = (start: TimeInterval, end: TimeInterval, speaker: String?, text: String)`.
- ElevenLabs is the first provider implementing this. The realtime ElevenLabs provider used for dictation is unchanged.
- API: `POST /v1/speech-to-text` with `model_id=scribe_v2`. Two calls per meeting:
  - `mic.opus`: `diarize=false`. Result segments all relabeled `me`.
  - `system.opus`: `diarize=true`, `num_speakers` left unspecified (let Scribe auto-detect). Result segments retain `Speaker N` labels for downstream mapping.

### 4.2 Stream merge
Two `[Segment]` lists arrive — one from mic (single speaker, all relabeled `me`), one from system (diarized, speakers `Speaker 1..N`). Merged by interleaving on `start` timestamp into a single chronological list.

Edge case: simultaneous talking. Both streams produce overlapping segments. Merge preserves both — UI renders them as adjacent entries with the same timestamp; the `me` segment displays first by convention.

### 4.3 LLM name-mapping pass (optional)
Runs only if user supplied attendees. Single LLM call:
```
Input: transcript with Speaker 1/2/3 labels + attendee list [Alice, Bob, Carol]
Task: return a JSON map { "Speaker 1": "Alice" | null, "Speaker 2": "Bob" | null, ... }
Constraint: only map a speaker to an attendee when the transcript content provides clear evidence (self-introduction, addressed by name, etc.). Otherwise return null.
```
- Provider: same provider abstraction as transcription (extends ElevenLabs first, but provider-agnostic).
- Failed mappings stay as `Speaker N`. User can manually rename in the transcript view.
- The mapping is stored in `meta.json` so re-rendering `transcript.md` is deterministic. Re-editing attendees in the transcript view (per §2.4) re-runs this pass and overwrites the stored mapping; manual renames performed via the right-click menu take precedence over LLM mappings and persist across re-runs.

---

## 5. Architecture & module boundaries

### 5.1 New modules
```
Sources/
  Meeting/
    MeetingOrchestrator.swift     // session lifecycle
    MeetingSession.swift          // model: id, files, attendees, status
    MeetingTranscript.swift       // Segment[], merge, render
    MeetingLibrary.swift          // disk persistence, list/load/delete
    Capture/
      SystemAudioCapture.swift    // Process Tap wrapper
      MicCapture.swift            // long-running mic
      OpusFileWriter.swift        // shared writer for both
    UI/
      MeetingMenuBarItem.swift
      StartMeetingModal.swift
      TranscriptWindow.swift
      MeetingsSettingsPane.swift
```

### 5.2 Touchpoints in existing code
- **`STTCore`**: add `BatchTranscriptionCapability` protocol + extend `STTProvider` to declare it. ElevenLabs provider implements it. No changes to existing realtime path.
- **`ConfigStore` / `AppConfig`**: add `MeetingSettings` (audio retention, attendee field default, etc.). Existing schema unchanged otherwise.
- **`ProviderRegistry`**: registers the batch capability for ElevenLabs. No new provider type.
- **First-run privacy modal** (`fa9b8e2`): add a new section "Meetings (optional)" — user can defer the Screen & System Audio Recording prompt without blocking the rest of first-run.
- **Settings window** (`f468f5b`): add the "Meetings" pane as a 7th pane alongside the existing six.

### 5.3 Untouched
- Dictation `Orchestrator`, `AudioCapture`, hotkey tap, paste-on-MainActor logic, FSM. The whole dictation path is unaffected.
- Existing five Settings panes other than Privacy.

---

## 6. Privacy, consent, retention

- **Consent disclosure**: text in the Start modal, in the first-run privacy onboarding section, and in the Meetings settings pane. Identical wording across surfaces.
- **No audio injection**: we do not play an "I am being recorded" announcement into the meeting. Out of scope; user-initiated.
- **Retention default**: audio deleted after transcription completes. Transcript kept until user deletes. **Exception**: if transcription fails, audio is retained so the user can retry (see §9). The retention default applies once a transcript has been successfully produced.
- **No telemetry**: we do not transmit metadata about meetings (count, duration, attendee names) to any service other than Scribe v2 / the LLM provider during the transcription itself. Audio is uploaded to ElevenLabs for transcription and per ElevenLabs's policy is not retained; we trust their stance for the same reason we already trust them for dictation. This is documented in the privacy pane.
- **No cloud sync**: transcript library is local-only. (If the user wants iCloud Drive sync, they can put the storage path under `~/Library/Mobile Documents/...` themselves; we don't ship a UI for it in v1.)

---

## 7. Permissions

- **Microphone** — already granted for dictation; reused.
- **Screen & System Audio Recording** — new for meeting mode. macOS 15+ TCC bucket gating `CATapDescription`. Requested at the moment the user first clicks Start meeting recording (lazy prompt), not at first launch — consistent with how the existing app handles Accessibility.
- **No new permissions**: no Calendar, no Contacts, no Accessibility additions.

The Settings → Privacy pane gets a new row for Screen & System Audio Recording that mirrors the existing fix-it deep-link pattern (`9d88ad7`).

---

## 8. Memory & disk budget

- **PRD §3.4 dictation cap**: ≤ 80 MB. Unchanged.
- **Meeting mode active cap**: ≤ 120 MB. Components: Process Tap + AVAudioEngine ~30 MB, two Opus writers ~5 MB, app baseline ~80 MB.
- **Idle (no meeting)**: returns to dictation cap.
- **Disk**: ~1 MB/min of recorded audio (Opus mono 16 kHz × 2 streams). 60-min meeting ≈ 60 MB on disk pre-deletion. Transcript JSON ≈ 100 KB. Long-term: only transcripts retained, ~MB-scale even for hundreds of meetings.

---

## 9. Error handling

- **Permission denied at Start**: modal stays open with a "Grant permission" button that deep-links to System Settings. No partial recording.
- **Process Tap creation fails**: Start fails fast with an error in the recent-errors log; no recording begins.
- **Mid-meeting failure** (audio device unplugged, app crash): on next launch, a half-written meeting directory is detected. Transcript window offers "Try transcribing what we have" or "Discard." Audio buffers on disk are flushed periodically (every ~10 s) so the loss window is bounded.
- **Scribe v2 API failure post-recording**: audio files retained (overriding the retention default for this case); transcript view shows "Transcription failed — retry" button. User can retry or discard.
- **LLM name-mapping failure**: silently skipped. Transcript still renders with `Speaker N` labels. Not surfaced as an error to the user.

All errors funnel through the existing recent-errors log surface (`c25a86a`).

---

## 10. Open questions for the spike to verify

The spike's job is to **validate** these design choices, not invent them. Specifically:

1. **Process Tap behavior on macOS 15+**: confirm the `kTCCServiceScreenCapture` prompt is the right one and that the prompt copy (`NSScreenCaptureUsageDescription`) is shown as expected. Confirm tap survives audio device changes (or document it as a known limitation).
2. **Scribe v2 batch quality on Zoom-band audio**: real-meeting test — submit a 30-min recording with 3+ remote speakers and verify diarization quality matches the spec sheet. If quality is poor on phone-band audio, we may need to revisit (channel-trick + pyannote alternative noted in the original research as the fallback).
3. **Scribe v2 batch cost** at our expected usage: the spike must produce a real number, not a guess. (Current ElevenLabs STT pricing is on their pricing page; spike pulls actual numbers and computes per-meeting cost.)
4. **LLM name-mapping accuracy**: smoke-test the prompt against 5 real meeting transcripts with known attendees; aim for ≥ 70% correct mappings on speakers who are explicitly addressed by name at least once. Below that, simplify by leaving everything as `Speaker N` and skipping the mapping pass.
5. **`AVAudioFile` Opus encoder availability**: confirm we can write Opus from `AVAudioFile` directly, or whether we need a separate encoder hop. Affects `OpusFileWriter` complexity.
6. **Two-engine vs. one-engine for mic + Process Tap**: §3.3 assumes `MicCapture` runs its own `AVAudioEngine` separate from any engine used for Process Tap. Spike confirms this is the right shape (vs. attaching Process Tap as a second input node on a single engine), based on whichever is simpler and more robust under audio device changes.

A throwaway proof-of-capture (per the spike's `Apps/Spike-MeetingCapture/`) demonstrates 1, 5, and 6 in a single ~100-line target.

---

## 11. Effort estimate

- **Spike**: 2–3 days (down from 3–5 in the original spike doc, since most product decisions are now resolved). Validates §10 questions, confirms GO.
- **Implementation, post-spike**: 8–12 engineering days for v1 as scoped above. Dominant costs: capture layer (Process Tap is new territory), transcript window (new UI), stream merge & LLM name-mapping (new code paths in `STTCore`).
- **Roadmap placement**: New milestone post-Phase-1, ahead of any Phase-2 cross-platform work.

---

## 12. Decision after the spike

The spike concludes with one of:
- **GO** — confirmed feasibility, schedule as new Phase 4 milestone.
- **DEFER** — feasibility holds but priorities push it out; record under "What's not on the roadmap" with this design doc linked.
- **NO** — fundamental blocker found in §10. Most likely blocker: Scribe v2 diarization quality on phone-band Zoom audio is unusable, in which case we either (a) accept Me/Them only and ship that, or (b) build the channel-trick + pyannote fallback, which is materially more work.

**Current leaning: GO.** No structural blocker has surfaced in design.

---

## 13. Deferred decisions

Decisions intentionally not made in this design, to be resolved during implementation or in a later iteration:

- **Keyboard shortcut for Start meeting recording.** Whether to add a global hotkey (and which key combo) is left to the implementation phase to align with whatever shortcut conventions the rest of the menu bar surface settles on. Menu bar click is the v1 baseline.
- **Per-process Process Tap (Zoom-only) vs. default-output tap.** v1 uses default-output (everything routed to speakers). v2 may move to per-process if user complaints about other-app audio bleed materialize.
- **Detection-based trigger** (notification when Zoom is in a meeting). v2.
- **Live transcript / live notes UI.** v2 polish.
- **Calendar OAuth integration.** Indefinite — revisit only if user demand emerges. Manual attendee entry is the v1 path.
- **Voiceprint enrollment across meetings** for cross-meeting speaker identity. Out of scope.

