# Product Requirements Document — whatchu-say

| Field | Value |
| --- | --- |
| Version | v2 |
| Status | Pre-implementation, design phase |
| Last updated | 2026-04-29 |
| Primary platforms | macOS (priority), iOS (Phase 2) |
| Deferred | Linux/Wayland (Phase 3) |
| Companion docs | [TECH_SPEC.md](./TECH_SPEC.md), [ROADMAP.md](./ROADMAP.md) |

---

## 1. Vision

A push-to-talk voice-to-text dictation tool that feels invisible. Press a key, talk, release, and the text appears at the cursor — anywhere the cursor is, in any app. Same experience on Mac and iOS, with the freedom to swap STT providers as the landscape changes.

## 2. Why build this

- **Wispr Flow alternative** — same ergonomics, but provider-agnostic and under my control.
- **ElevenLabs realtime STT first** — best-in-class quality for the use cases I care about.
- **Future-proof** — provider abstraction lets me swap in Deepgram, AssemblyAI, OpenAI Realtime, or local Whisper without rewriting the app.
- **Hackable** — own the codebase, extend it (LLM cleanup, custom hotkeys, per-app behavior, history search) on my own timeline.

## 3. Goals

### 3.1 Product goals (P0 — required for v1)

- System-wide press-and-hold dictation on macOS, working in any text input.
- Configurable global hotkey (rebindable).
- **Cancellation flow**: cancel a dictation in progress without injecting (default: Esc while holding the hotkey, key configurable).
- Reliable text injection across native fields, browser inputs, terminals, and chat apps.
- ElevenLabs realtime STT integration with clean error handling and reconnection.
- **Provider-side endpoint detection disabled** — `Final` only arrives after our explicit end-of-stream. Pauses while the key is held never trigger early finalization.
- Settings UI in native SwiftUI (menubar app + settings window).
- API key stored in Keychain, never on disk in plaintext.
- **Floating dictation overlay** with live VU meter, anchored near the cursor at activation time.

### 3.2 Product goals (P1 — required for "done", can iterate post-launch)

- Double-tap-to-toggle hands-free mode using the same hotkey.
- Per-app injection strategy overrides (e.g., always-paste in Slack).
- Transcription history (last N sessions, configurable retention).
- Auto-launch at login.
- First-run onboarding that walks through permissions and API key setup.
- **Usage/cost indicator**: minutes-used-this-month visible in settings, with a small indicator in the menubar.
- **Sleep/wake auto-recovery**: WebSocket reconnects automatically on wake; no manual re-arm needed.

### 3.3 Phase 2 goals (iOS)

iOS architecture: **host-app-recording flow with URL-scheme handoff.** The keyboard extension is a thin launcher; the host app is the actual dictation surface. This matches Wispr Flow's published architecture and is forced by an iOS platform restriction — see TECH_SPEC §8.3 for the spike outcome that established this.

- **Keyboard extension** (thin): mic button, recent-transcripts strip, deep-links to host app via custom URL scheme on tap, pastes the returned transcript via `UITextDocumentProxy.insertText` when the user comes back to the keyboard.
- **Host app** (the dictation surface): full press-and-hold mic UI; runs `AVAudioEngine` + `STTElevenLabs` against the same shared Swift core as the Mac app; on finalize writes transcript to the App Group container and follows the return-URL back to the originating app.
- **Shared Swift core** with Mac (provider abstraction, audio capture, orchestration) compiles into the host app, not the extension.
- **Settings, API key entry, and history viewer** live in the host app, persisted via App Group + Keychain Sharing access group.
- **Phase 1.5 feasibility spike outcome (2026-04-28)**: in-extension recording is blocked at the OS level (`CMSUtilities` denies the audio sandbox extension; `AVAudioEngine.start()` returns `'what'` / 2003329396); App Group + `URLSessionWebSocketTask` from extension context both work cleanly. The architecture above is the redesign that resulted; treat it as primary, not contingency.

### 3.4 Non-functional goals

| Property | Target |
| --- | --- |
| Latency | Subjectively snappy as judged by daily-driver use. Instrumented for diagnostic analysis; not enforced as a hard NFR threshold. |
| Resident memory (Mac, headless) | ≤ 80 MB |
| Resident memory (Mac, settings open) | ≤ 200 MB |
| Resident memory (iOS keyboard extension) | ≤ 48 MB (Apple ceiling) |
| Audio glitches under normal load | zero |
| Recovery from transient network blip | session marked lost; user retries (no silent replay) |
| Recovery from sleep/wake | automatic, no user action |
| Telemetry / crash reporting to remote services | none |

## 4. Non-goals

Explicitly **out of scope** for v1 to keep the build focused:

- **Windows.** Not a target platform.
- **X11 on Linux.** Wayland-only when Linux is built (Phase 3).
- **Local on-device STT.** Architecture supports it via the provider trait, but bundling Whisper models is deferred.
- **LLM post-processing** ("clean up my dictation"). Easy to add later as another provider-style abstraction; not v1.
- **Multi-user accounts, sync, team features.** Single-user, local-only.
- **Real-time captioning UI.** No on-screen transcript bubble during dictation. The floating overlay shows a VU meter only, not transcript text.
- **Transcript editing UI.** History is read-only for v1.
- **Auto-exit on silence or duration.** Hands-free mode exits *only* on explicit user action (single hotkey press, or double-tap again). No VAD, no silence timeout, no max-session duration. Cost/usage indicator is the safety surface for forgotten sessions.
- **Reconnect-with-replay.** A mid-utterance connection drop fails the session. The user retries. We do not buffer audio across reconnections to avoid duplicate-transcript bugs.

## 5. Target user

Single primary user: a power-user developer who dictates frequently across native apps, browsers, and terminals on macOS, with secondary use on iOS. Comfortable granting accessibility permissions; sensitive about telemetry; values latency and reliability over features. Pauses while dictating to think — and explicitly does not want pauses to trigger any automatic behavior.

## 6. User flows

### 6.1 macOS first run

1. User mounts `.dmg`, drags app to Applications.
2. Launches app → menu bar icon appears (no Dock icon).
3. Click icon → "Welcome" panel offers a 4-step setup.
4. **Step 1 — Microphone**: button triggers TCC prompt; status flips to ✓ on grant.
5. **Step 2 — Accessibility**: button opens System Settings → Privacy & Security → Accessibility with the app pre-selected. User flips the toggle. App polls for permission state and advances when granted.
6. **Step 3 — Hotkey**: user picks a key (default suggestion: Right Option). Live capture lets them press to confirm.
7. **Step 4 — Provider key**: paste ElevenLabs API key; app validates with a test connection, stores in Keychain.
8. Final screen: "Hold {hotkey} and say something." Live mic indicator + transcribed result.
9. Done. Tray icon goes grey (idle).

### 6.2 macOS press-and-hold dictation (primary flow)

```
[idle, tray dot grey]
  ↓ user holds bound hotkey
[t+0ms]      audio capture starts
[t+30ms]     WebSocket to provider opens (parallel)
[t+50ms]     floating overlay appears near cursor with VU meter; tray dot turns red
[t+...]      audio chunks stream as they arrive (20ms frames)
             VU meter animates with audio level (RMS)
             pauses while talking are fine — provider-side endpointing is disabled,
             nothing finalizes until release
  ↓ user releases hotkey
[t+release]  stop capture, send EOS marker
             overlay shows "transcribing..."
[~+200-400ms] receive Final transcript from provider
             inject text at current cursor
             overlay fades out, tray dot returns to grey
```

Cancellation branch (anywhere during dictation):

```
↓ user presses Esc while still holding the hotkey
   close session, discard any pending text
   overlay shows "cancelled" briefly, then fades
   tray dot returns to grey
   user can release the hotkey at their leisure; no further action taken
```

### 6.3 macOS double-tap-to-toggle (hands-free)

```
[idle]
  ↓ user double-taps the same hotkey within 350 ms
[hands-free entered] tray dot pulses red
                     floating overlay appears with VU meter (persistent)
                     audio streams continuously
                     transcripts inject incrementally as Finals arrive
                       (each Final corresponds to one user-bounded utterance —
                        we control utterance boundaries, not the provider)
  ↓ user presses hotkey once to exit
[finalize, return to idle]
```

**No auto-exit.** Hands-free runs until the user explicitly exits. Pauses, silence, and inactivity do not trigger finalization. The cost/usage indicator surfaces ongoing usage so the user notices a forgotten session via menubar/settings, not via an automatic cutoff.

In hands-free mode, "utterance boundary" is a small subtlety: with provider endpointing disabled, we'd never get Finals. So in hands-free mode specifically, we can either (a) re-enable provider endpointing for hands-free *only*, accepting auto-finalization on speech pauses (this contradicts the user's stated preference), or (b) require an explicit per-utterance boundary signal — e.g., a quick double-tap inside hands-free mode to "send what's been captured so far" — see TECH_SPEC §16.

### 6.4 macOS hotkey disambiguation (same key for both modes)

State machine:

```
IDLE
  │ KeyDown → start audio capture (speculative), → PRESSED
PRESSED
  │ KeyUp within 250 ms → → TAP_PENDING (300 ms window)
  │   │ KeyDown within 300 ms → DOUBLE_TAP: drop speculative buffer, → HANDS_FREE
  │   │ window expires → SHORT_PRESS: emit short utterance, → IDLE
  │ Held > 250 ms → PRESS_HOLD: continue dictating
PRESS_HOLD
  │ KeyUp → finalize, → IDLE
  │ Esc → cancel session, → IDLE (still in PRESS_HOLD until KeyUp; Esc discards)
HANDS_FREE
  │ KeyDown (single press) → finalize, → IDLE
  │ Esc → cancel session (no inject), → IDLE
```

Audio capture starts immediately on KeyDown so press-and-hold has zero perceived latency. If it turns out to be a double-tap, ~200 ms of audio is discarded.

Timing values (250 ms / 300 ms) are configurable in advanced settings.

### 6.5 macOS cancellation flow

- Cancel key (default: Esc; configurable) is consumed *only* while we hold the dictation lock — i.e., during PRESS_HOLD or HANDS_FREE state. Outside of these states, Esc passes through normally to whatever app is focused.
- On cancel: close the STT session, discard any pending Final text, fade the overlay with "cancelled", return tray dot to grey.
- In PRESS_HOLD, the user may still be holding the hotkey when they cancel; that's fine — the FSM stays in PRESS_HOLD until the actual KeyUp, but no further action is taken (audio is no longer streamed, session is closed).

### 6.6 iOS first run (Phase 2)

1. Install app from App Store.
2. Open host app → onboarding explains it's a keyboard.
3. Host app guides user to: Settings → General → Keyboards → Add New Keyboard → whatchu-say.
4. Host app guides user to enable **"Allow Full Access"** with clear explanation: "needed for microphone and network connection to your STT provider."
5. Return to host app: paste ElevenLabs API key (stored in shared Keychain access group).
6. "Try it now" — opens a sandbox text field and walks through the keyboard switch + press-and-hold.

### 6.7 iOS keyboard extension dictation (Phase 2)

iOS uses the host-app-recording flow. The keyboard never records; it launches the host app, which records, then returns control to the originating app with the transcript on the App Group clipboard for the keyboard to paste.

```
[in some app's text field]
  ↓ user switches to whatchu-say keyboard via globe key
[whatchu-say keyboard presented]
  ↓ user taps mic button (single tap, not press-hold)
[host app launches via custom URL scheme:
   whatchusay://record?return={originating-app-url}]
[host app: full press-and-hold dictation UI, VU meter, overlay equivalent]
  ↓ user holds, talks, releases
[host streams to ElevenLabs, gets Final transcript]
  ↓ writes transcript to App Group pasteboard + history SQLite
  ↓ host opens the return URL → user returns to originating app
[whatchu-say keyboard regains focus]
  ↓ keyboard observes the App Group pasteboard, sees the new transcript
  ↓ inserts via UITextDocumentProxy.insertText at the cursor
[done — tray-equivalent indicator briefly confirms paste; keyboard idle]
```

Cancellation is per-stage:
- Inside the host app (during recording): same Esc-equivalent cancel as Mac.
- After return (clipboard ready, before paste): the keyboard surfaces a small "Discard" affordance alongside the auto-paste, so the user can suppress the insert if they changed their mind on the way back.

Notes:

- **Press-and-hold lives in the host app**, not the keyboard. The keyboard's mic button is a single-tap launcher; the host's mic surface is where the gesture happens. This avoids the "long-press in a 240px-tall view" UX that would otherwise be cramped.
- **Auto-paste on return** is the natural completion of the user's "I tapped the mic" intent — not a violation of the no-auto-anything firm decision. The user's explicit action chains: tap mic → speak → release → return → paste. Each link is in service of the same originating action, not a side effect.
- **Hands-free mode is not viable.** The keyboard is dismissed when the originating app's text field loses focus, so even if the host could maintain a session, the paste-back target disappears. For v1 iOS: not offered.
- **Permission model**: mic permission is granted to the host app's bundle ID, not the extension's. Since the extension never records, the extension does not need `NSMicrophoneUsageDescription`. It does need `RequestsOpenAccess` to be allowed to launch URL schemes and read the App Group pasteboard.

### 6.8 Failure modes (what the user sees)

| Failure | User experience |
| --- | --- |
| Mic permission missing | Tray icon yellow; clicking opens settings with fix-it button |
| Accessibility permission missing | Tray icon yellow; injection silently falls back to clipboard with a single notification "copied to clipboard — grant Accessibility for direct insertion" |
| Provider connection failed at session start | Toast: "Couldn't reach ElevenLabs"; audio is dropped; user can retry from settings |
| Provider connection drops mid-utterance | **Session marked lost**. Toast: "Connection lost — try again." Captured audio is discarded. No silent retry, no audio replay. |
| Provider auth failed | Toast + open settings to re-enter key |
| Audio device disconnected mid-session | Switch to default device, brief notification |
| Mac wakes from sleep with WebSocket dead | Auto-reconnect on next activation; no user-visible action needed |
| App killed (iOS) | State restored on next activation; in-flight audio is lost |
| User cancels (Esc) | Overlay shows "cancelled" briefly; no toast, no log entry |

## 7. Platform requirements

### 7.1 macOS

- **Minimum OS**: macOS 14 Sonoma (for `MenuBarExtra` refinements, `SMAppService.LoginItem`, modern `AVAudioApplication`)
- **Architecture**: Universal binary (arm64 + x86_64)
- **Permissions required**:
  - Microphone (`NSMicrophoneUsageDescription`)
  - Accessibility (`AXIsProcessTrustedWithOptions`)
  - Input Monitoring (some `CGEventTap` filter modes)
- **Distribution**: Developer ID notarized `.dmg`. Sparkle auto-update in Phase 1.5. Homebrew tap as a stretch.
- **Sandboxing**: NOT sandboxed. Sandboxed apps cannot use system-wide `CGEventTap` or post events to other apps.

### 7.2 iOS (Phase 2)

- **Minimum OS**: iOS 17 (for keyboard extension async APIs and modern SwiftUI)
- **Devices**: iPhone + iPad (universal)
- **Permissions required**:
  - Microphone (`NSMicrophoneUsageDescription`)
  - "Allow Full Access" enabled by user for the keyboard extension
- **Entitlements**:
  - App Group (host app ↔ extension data sharing)
  - Keychain Sharing (API key access from extension)
  - `RequestsOpenAccess` (keyboard extension full access)
- **Distribution**: App Store. TestFlight beta first.
- **App Review considerations**: explicit, well-justified explanation for "Allow Full Access" — mic + STT API endpoint connection.
- **Phase 2 architecture**: host-app-recording flow with URL-scheme handoff (see §3.3 and TECH_SPEC §8.3). Decided by Phase 1.5 spike (2026-04-28); not provisional.

### 7.3 Linux / Wayland (Phase 3, deferred)

Not specced in detail until Phase 3 begins. High-level placeholder:

- Wayland-only (X11 not supported)
- xdg-desktop-portal 1.18+ required
- GTK4 frontend (likely via swift-cross-ui or direct Swift→GTK bindings)
- Distribution: AppImage + `.deb`

Phase 3 prerequisites: Phase 1 + 2 stable; validated Swift D-Bus story for portal proxies; validated UI toolchain.

## 8. Functional requirements

- Configure a global hotkey via the settings UI.
- Configure a cancellation key (default Esc) via the settings UI.
- Activate dictation in press-and-hold mode while the hotkey is held.
- Activate hands-free mode by double-tapping the hotkey; deactivate by single press of the hotkey.
- Cancel an in-progress dictation by pressing the cancel key (consumed only while dictating).
- Disambiguate press-and-hold from double-tap on the same key by timing (configurable thresholds).
- Stream audio to the configured STT provider in real time, with provider-side endpoint detection disabled.
- Display a floating overlay with a live VU meter near the cursor during dictation.
- Inject the final transcript at the current cursor position upon explicit end-of-utterance (key release in press-hold; per-utterance signal in hands-free).
- Support both type and paste injection strategies, with paste as the default and type used only for short, simple text.
- Allow users to override the injection strategy per application (Mac).
- Persist the API key in Keychain (Mac) or shared Keychain access group (iOS host ↔ extension).
- Provide a transcription history view (default 30-day retention, configurable).
- Auto-launch at login (Mac, opt-in).
- Allow users to pause/disable dictation without quitting the app.
- Track usage (minutes per session, monthly aggregate) and surface in menubar + settings.
- Auto-reconnect WebSocket on Mac wake from sleep.

## 9. Non-functional requirements

- **Latency**: subjectively snappy as judged by daily-driver dogfood. Instrumented for diagnostic analysis. Not enforced as a hard threshold; we tune by feel.
- **Memory**:
  - Mac headless steady state ≤ 80 MB.
  - Mac peak (settings window or overlay open) ≤ 200 MB.
  - iOS keyboard extension ≤ 48 MB.
- **Reliability**: zero data loss across 100 dictations — every utterance results in either text inserted, an explicit user cancellation, or a clear, actionable error. No silent loss.
- **Audio quality**: no glitches or dropouts during normal load; backpressure handled by frame-dropping at the chunker, not by blocking the audio thread.
- **Resilience**: sleep/wake recovers automatically. Mid-utterance network drops surface a clear "lost — retry" message; no audio replay across reconnects.
- **Privacy**: API keys never logged or sent anywhere except the configured provider endpoint. No remote telemetry. Local logs rotate weekly and contain no transcript content. Settings includes a clear disclosure of what data leaves the machine and where it goes.
- **Offline behavior**: clear, fast error if provider is unreachable; no hanging, no partial state.

## 10. Success criteria for v1

- I personally use whatchu-say as my daily-driver dictation tool on Mac, replacing Wispr Flow, for 2 consecutive weeks without falling back.
- Latency feels comparable to Wispr Flow on the same network (subjective, dogfood-tuned).
- Memory stays under 200 MB across an 8-hour workday.
- Provider abstraction validated by a second adapter implementation (mock or thin Deepgram WebSocket adapter) — proves the trait is the right shape.
- Phase 2 success: dictation works reliably in 5 different iOS apps (Notes, Messages, Safari, Slack, a code editor like Working Copy) over 1 week of personal use, via the host-app-recording handoff.

## 11. Resolved decisions (2026-04-27)

| # | Question | Decision |
| --- | --- | --- |
| 1 | Visual feedback during dictation | Floating mic overlay near cursor with live VU meter (no transcript text) |
| 2 | Cancellation flow | Default Esc-while-holding; key configurable in settings |
| 3 | Final-before-EOS handling | Disable provider-side endpoint detection; Final only after our EOS |
| 4 | Latency NFR | No numerical target. "Subjectively snappy" + dogfood judgment |
| 5 | Cost/usage surface | Yes — settings stats + menubar indicator |
| 6 | iOS feasibility spike | Completed 2026-04-28: in-extension recording is OS-blocked. Phase 2 uses host-app-recording flow (TECH_SPEC §8.3) |
| 7 | Sleep/wake behavior | Auto-reconnect on wake |
| 8 | VAD / auto-exit | Drop WebRTC VAD entirely. Use RMS for VU meter. **Drop all auto-exit** — hands-free runs until user explicitly exits |

## 12. Remaining open decisions

- **Hands-free per-utterance boundary signal** (introduced in §6.3): with provider endpointing disabled, hands-free needs an explicit signal to commit a chunk of text without exiting. Candidates: a quick double-tap to "flush", a chunked timer (e.g., commit every 30s), or accept that hands-free only injects on exit. Decide before Milestone 1.4.
- **History retention default**: 30 days proposed; revisit after dogfood.
- **Auto-update mechanism**: Sparkle in Phase 1.5; manual `.dmg` downloads only at v1 launch.
- **Hotkey timing thresholds (250 ms / 300 ms)**: hidden in advanced settings; defaults stand unless dogfood shows otherwise.
- **Overlay position default**: cursor-anchored vs. screen-anchored. Currently planning cursor-anchored with a setting to switch.
