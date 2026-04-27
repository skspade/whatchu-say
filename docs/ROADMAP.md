# Roadmap — whatchu-say

| Field | Value |
| --- | --- |
| Version | v2 |
| Status | Pre-implementation, design phase |
| Last updated | 2026-04-27 |
| Companion docs | [PRD.md](./PRD.md), [TECH_SPEC.md](./TECH_SPEC.md) |

---

## Overview

Three phases, ordered by personal-priority:

1. **Phase 1 — macOS MVP** (active focus, **8–12 weeks** of focused effort)
2. **Phase 2 — iOS keyboard extension** (~3–4 weeks after Phase 1, **gated on feasibility spike**)
3. **Phase 3 — Linux/Wayland** (deferred; designed in detail when started)

Effort estimates assume one developer working consistently, not full-time. Phase 1 estimate widened from v1's 6–8 weeks to account for the unknowns surfaced in the v2 design pass: floating overlay UI, usage tracking, sleep/wake handling, and the iOS feasibility spike.

---

## Phase 1 — macOS MVP

**Goal**: a daily-driver dictation app on Mac that replaces Wispr Flow for personal use.

### Milestone 1.1 — Foundation (week 1–2)

**Outcome**: Swift Package compiles, all logical components exist with stubs, mock end-to-end test passes.

- Swift Package skeleton with all targets per `TECH_SPEC.md` §3.
- `Sources/Hotkey/ActivationStateMachine.swift` implemented + exhaustive unit tests, including cancellation paths.
- `Sources/STTCore/` protocols defined (with `EndpointMode`); `STTMockProvider` implemented.
- `Sources/Audio/` interfaces + ring buffer + chunker + `RMSAnalyzer`, with stub `AVAudioCapture`.
- `Sources/Orchestrator/` with fakes — passes basic end-to-end test.
- `Sources/Core/AppConfig.swift` with `schemaVersion = 1` and migration handler stubs.
- CI: GitHub Actions with `swift test` on macOS + Linux smoke compile.

**Exit criteria**: `swift test` passes locally and in CI. `OrchestratorTests` runs a fake utterance through the full chain, including cancellation.

### Milestone 1.2 — macOS dictation core (week 2–4)

**Outcome**: real press-and-hold dictation works against ElevenLabs, in any app, with **paste-default** injection.

- `AVAudioCapture` real implementation.
- `HotkeySourceMac` using `CGEventTap` (with key-repeat filter and modifier-key disambiguation).
- `STTElevenLabs` real adapter with `endpointDetection: .clientControlled` set on session config. Verify provider supports it; if not, document fallback path.
- `InjectorMac` with paste-default strategy + type for short text.
- Minimal `WhatchuSayMac` Xcode project with `MenuBarExtra`, hardcoded hotkey, hardcoded API key (env var for now).
- First real dictation: hold key, talk, release, see text appear. Pauses while holding don't trigger anything.

**Exit criteria**: I can dictate a paragraph into TextEdit. Pausing mid-sentence to think doesn't cause premature finalization. No crashes across 20 attempts.

### Milestone 1.3 — Polish, permissions, overlay, cancel (week 4–6)

**Outcome**: app handles permissions cleanly, has a usable settings UI, has the floating overlay, and supports cancellation.

- First-run onboarding flow with permission status panes.
- Privacy disclosure pane on first run.
- Settings window: provider config, hotkey rebinding, cancel-key rebinding, injection preferences, overlay anchor preference.
- API key entry and Keychain persistence.
- **Floating overlay UI** (`Sources/PlatformApple/Mac/Overlay/`): NSPanel + VU meter view + lifecycle integration.
- **Cancellation flow**: second `CGEventTap` filter for cancel key; consume only during dictation states; orchestrator handles `.cancelDictation`.
- Per-app injection override UI.
- Permission-fix-it deep links to System Settings.

**Exit criteria**: a fresh user account can install, walk through onboarding (including privacy disclosure), and dictate within 5 minutes. Cancellation works in both press-hold and (stub) hands-free.

### Milestone 1.4 — Hands-free, reliability, sleep/wake (week 6–8)

**Outcome**: double-tap-toggle works; provider failures surface cleanly; sleep/wake handled.

- Double-tap toggle activation mode with full state machine integration.
- **Hands-free per-utterance boundary signal**: implement candidate (a) — quick double-tap inside hands-free flushes current utterance and continues. Validate via dogfood; switch to (b) or (c) if (a) feels wrong.
- **Reconnect policy**: fail-fast — no audio replay, mid-utterance drops surface as toast, user retries manually.
- Error toasts and degraded-state UI (yellow tray icon, fix-it links).
- Audio device disconnect recovery.
- **Sleep/wake observer**: graceful close on sleep; transparent reconnect on next activation.
- Empty result handling (silent — no notification, no inject).

**Exit criteria**: kill Wi-Fi mid-utterance — gets a clear "lost" toast, no crash, no garbled output. Mac sleeps for 30+ minutes — first dictation post-wake works without manual intervention. Hands-free tested across a 30-minute writing session.

### Milestone 1.5 — Daily-driver polish + iOS feasibility spike (week 8–11)

**Outcome**: shippable v1 — code-signed, notarized, distributable, with history, usage tracking, autostart. iOS architecture validated.

- Transcription history view (chronological list, copy-to-clipboard).
- **Usage tracking implementation**: `Sources/Usage/`, settings pane, menubar indicator (configurable).
- `SMAppService` autostart integration.
- Notarization script and packaging.
- README + landing page (or GitHub release page) with screenshots.
- **Second-provider mock validation**: implement `STTMockProvider` end-to-end with Orchestrator to confirm provider abstraction holds. Bonus: skeletal `STTDeepgram` adapter.
- **iOS feasibility spike** (1–2 weeks within this milestone): standalone keyboard extension prototype to verify mic + WebSocket + memory budget. Document findings; decide Phase 2 architecture before Phase 1 closes.
- Personal dogfood: 2 weeks of replacing Wispr Flow exclusively.

**Exit criteria**: PRD §10 success criteria met. Memory under 200 MB across 8-hour workday. 100 dictations with zero data loss (cancellations and connection-lost-with-clear-error counted as not-data-loss). Feasibility spike has a concrete answer for Phase 2.

### Phase 1 risks

| Risk | Mitigation |
| --- | --- |
| ElevenLabs WebSocket protocol doesn't support client-controlled endpointing | Verify in early Milestone 1.2; document fallback (provider endpointing + buffer-and-concat in our orchestrator) |
| `CGEventTap` permission UX worse than expected | Test on a fresh user account early in 1.3 |
| Type-strategy injection fails in many apps | Already mitigated by paste-default policy; type only for ≤8 chars |
| Floating overlay positioning via AXUIElement is fragile | Fall back to mouse pointer position + screen-anchored option |
| Cancel-key consumption confuses tap behavior | Carefully scope the consumption to dictation-active states only; test in vim, terminal, password fields |
| Hands-free per-utterance signal feels wrong in dogfood | (a)/(b)/(c) candidates documented; switch easily |
| Sleep/wake breaks WebSocket in non-obvious ways | Treat reconnect as fresh session always; don't try to maintain across sleep |
| iOS feasibility spike fails | Phase 2 redesign well-understood (host-app-recording flow); not a project-killer |

---

## Phase 2 — iOS keyboard extension

**Goal**: same dictation experience adapted to iOS via custom keyboard.

**Gated on**: Phase 1.5 feasibility spike outcome. If mic + WebSocket + 48 MB budget all pass in extension context, proceeds as designed below. If not, redesign to host-app-recording flow before Milestone 2.1.

Starts after Phase 1 hits exit criteria and stabilizes for ~1 week of real use.

### Milestone 2.1 — iOS host app (week 1)

**Outcome**: host app compiles, settings work, App Group + Keychain Sharing wired.

- `WhatchuSayiOS` Xcode project with host app + extension target.
- App Group container + Keychain Sharing access group configured.
- Settings UI ported from Mac.
- Privacy disclosure pane.
- Onboarding flow including keyboard-install instructions.
- API key entry + test connection from host app.

**Exit criteria**: host app installs from Xcode, settings persist, API key reads successfully from a stub extension.

### Milestone 2.2 — Keyboard extension (week 1–3)

**Outcome**: dictation works inside the extension, end-to-end.

- Extension target with `RequestsOpenAccess`.
- Mic button UI with `UILongPressGestureRecognizer`.
- Audio capture in the extension (or host app, per spike outcome).
- Provider integration via shared `Sources/STTElevenLabs/`.
- Insert via `UITextDocumentProxy.insertText`.
- Touch-up-outside cancellation.
- Memory profiling — under 48 MB ceiling continuously.
- State save/restore for when extension is killed.
- Recent transcripts UI (read from shared SQLite).

**Exit criteria**: dictation works in 5 different host apps. RSS stays under 45 MB across 20 dictations.

### Milestone 2.3 — Polish & ship (week 3–4)

**Outcome**: TestFlight beta, then App Store submission.

- Onboarding polish — keyboard install instructions are the trickiest part of iOS UX.
- "Allow Full Access" justification copy.
- TestFlight beta — solo first, then small cohort.
- App Store submission with privacy policy and Full Access justification.

**Exit criteria**: PRD §10 Phase 2 success criteria met. App Store approves on first or second submission.

### Phase 2 risks

| Risk | Mitigation |
| --- | --- |
| Spike outcome forces architecture change | Already planned; redesign known |
| 48 MB ceiling violated in real use | Profile from start of 2.2; aggressive frame discarding if needed |
| App Review rejects "Allow Full Access" justification | Pre-research approved patterns from competing dictation apps |
| State recovery is awkward when extension is killed | Embrace it: lose in-flight audio gracefully |

---

## Phase 3 — Linux / Wayland (deferred)

**Status**: not designed in detail. Placeholder for full design at Phase 3 kickoff.

### Outline

- GTK4 frontend (likely via `swift-cross-ui`, fallback to direct Swift→GTK bindings).
- xdg-desktop-portal `GlobalShortcuts` (hotkey) and `RemoteDesktop` (injection) via Swift D-Bus.
- AVAudioEngine equivalent via PipeWire C interop.
- AppImage + `.deb` distribution.
- Estimated 8–12 weeks from kickoff.

### Phase 3 prerequisites

- Phase 1 + 2 stable for 1+ months.
- Validated `swift-cross-ui` (or chosen UI toolkit) can render the settings window we need.
- Validated Swift D-Bus story works for `xdg-desktop-portal` proxies.
- Validated PipeWire capture from Swift (likely via thin C wrapper).

### Phase 3 acceptance scope

- Wayland-only (no X11 compatibility).
- Tested on Ubuntu 24.04 + Fedora 40 + one wlroots compositor (Hyprland).
- RemoteDesktop portal as primary injection path; `zwp_virtual_keyboard_v1` as fallback for wlroots.
- Modifier-only hotkeys deprioritized (function-key bindings only at v1).
- Floating overlay equivalent: TBD — likely a small GTK4 window with the same VU meter.

---

## Cross-phase principles

- **No phase starts before its predecessor is stable.** Stability defined as: 1 week of personal use without a critical bug, exit criteria met.
- **Phase 3 doesn't bottleneck the cross-platform Swift Package.** Shared targets compile on Linux from Phase 1 onwards (CI smoke build).
- **Provider abstraction proven by a second adapter before declaring Phase 1 done.**
- **Memory budgets enforced from week one of each phase**, not at the end.
- **No silent automatic behaviors.** Auto-exit, audio replay, and other "helpful" automatic flows are explicitly out — every transition the user cares about is triggered by an explicit user action or a transparent transient-error message.

---

## What's not on the roadmap

Explicitly deferred beyond v1:

- Local Whisper / on-device STT.
- LLM post-processing.
- Multi-user accounts, sync, team features.
- Windows.
- X11 support on Linux.
- Real-time captioning UI / transcript text in overlay.
- Transcript editing.
- Voice commands ("scratch that", "new paragraph").
- Auto-exit on silence or duration (explicitly designed out).
- Audio replay on reconnect (explicitly designed out).

If any of these become important after v1, they get a fresh design pass and a new phase.
