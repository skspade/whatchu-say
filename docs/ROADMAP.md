# Roadmap — whatchu-say

| Field | Value |
| --- | --- |
| Version | v2 |
| Status | Phase 1 in implementation — Mac engine done, shell incomplete (~55% overall) |
| Last updated | 2026-04-30 |
| Companion docs | [PRD.md](./PRD.md), [TECH_SPEC.md](./TECH_SPEC.md) |

> **Status legend** (used in milestone bullets below): ✅ done · ⚠️ partial / shim · ❌ not done · ⏳ pending validation

---

## Overview

Three phases, ordered by personal-priority:

1. **Phase 1 — macOS MVP** (active focus, **8–12 weeks** of focused effort)
2. **Phase 2 — iOS keyboard extension** (~4–5 weeks after Phase 1; architecture decided by Phase 1.5 spike — host-app-recording flow)
3. **Phase 3 — Linux/Wayland** (deferred; designed in detail when started)

Effort estimates assume one developer working consistently, not full-time. Phase 1 estimate widened from v1's 6–8 weeks to account for the unknowns surfaced in the v2 design pass: floating overlay UI, usage tracking, sleep/wake handling, and the iOS feasibility spike.

---

## Phase 1 — macOS MVP

**Goal**: a daily-driver dictation app on Mac that replaces Wispr Flow for personal use.

### Milestone 1.1 — Foundation (week 1–2)

**Outcome**: Swift Package compiles, all logical components exist with stubs, mock end-to-end test passes.

**Status (2026-04-29)**: ~85% — code-side done; CI not set up; `AppConfig` migration scaffolding still a stub.

- ✅ Swift Package skeleton with all targets per `TECH_SPEC.md` §3.
- ✅ `Sources/Hotkey/ActivationStateMachine.swift` implemented + exhaustive unit tests, including cancellation paths.
- ✅ `Sources/STTCore/` protocols defined (with `EndpointMode`); `STTMockProvider` implemented.
- ✅ `Sources/Audio/` interfaces + ring buffer + chunker + `RMSAnalyzer`, with stub `AVAudioCapture`.
- ✅ `Sources/Orchestrator/` with fakes — passes basic end-to-end test.
- ⚠️ `Sources/Core/AppConfig.swift` with `schemaVersion = 1` and migration handler stubs. *(`schemaVersion` exists; no `ConfigMigration` type or migration stubs yet.)*
- ❌ CI: GitHub Actions with `swift test` on macOS + Linux smoke compile. *(No `.github/` directory.)*

**Exit criteria**: `swift test` passes locally and in CI. `OrchestratorTests` runs a fake utterance through the full chain, including cancellation.

### Milestone 1.2 — macOS dictation core (week 2–4)

**Outcome**: real press-and-hold dictation works in any app with **paste-default** injection.

**Status (2026-04-29)**: ✅ complete. Bonus: API-key handling moved to Keychain (was originally scoped as env-var-only).

- ✅ `AVAudioCapture` real implementation.
- ✅ `HotkeySourceMac` using `CGEventTap` (with key-repeat filter and modifier-key disambiguation).
- ✅ `STTElevenLabs` real adapter with `endpointDetection: .clientControlled` set on session config. Verify provider supports it; if not, document fallback path.
- ✅ `InjectorMac` with paste-default strategy + type for short text.
- ✅ Minimal `WhatchuSayMac` Xcode project with `MenuBarExtra`, hardcoded hotkey, hardcoded API key (env var for now). *(Key now in Keychain via `KeychainAPIKeyStore` + menu-driven `APIKeyPrompt`.)*
- ✅ First real dictation: hold key, talk, release, see text appear. Pauses while holding don't trigger anything.
- ✅ Apple SpeechAnalyzer on-device dictation provider (macOS 26+): downloads locale assets before activation, maps progressive/final results to the shared STT contract, exposes device-supported language selection, and requires no dictation API key. ElevenLabs remains available for realtime dictation.

**Exit criteria**: I can dictate a paragraph into TextEdit. Pausing mid-sentence to think doesn't cause premature finalization. No crashes across 20 attempts.

### Milestone 1.3 — Polish, permissions, overlay, cancel (week 4–6)

**Outcome**: app handles permissions cleanly, has a usable settings UI, has the floating overlay, and supports cancellation.

**Status (2026-05-01)**: ~85% — overlay (HUD), Esc-cancel, Keychain API-key, permission fix-it deep links, **the Settings window with all six panes**, **first-run privacy disclosure modal**, and **per-app injection override UI** are in. The remaining gap is the full onboarding wizard (permission status panes); the privacy slice of onboarding ships as the first-run modal. Live re-config of the running orchestrator is a documented follow-up — see [PLAN_LIVE_RECONFIG.md](./PLAN_LIVE_RECONFIG.md).

- ❌ First-run onboarding flow with permission status panes. *(Privacy disclosure is covered by the first-run modal; the Accessibility + Microphone walkthrough panes are still missing.)*
- ✅ Privacy disclosure pane on first run. *(`FirstRunDisclosure` modal blocks bootstrap until acknowledged; reusable `DisclosureContent` view also rendered in the Privacy settings pane.)*
- ✅ Settings window with six toolbar tabs — General, Provider, Shortcuts, Output, History, Privacy. Provider config, hotkey rebinding (custom recorder widget), cancel-key rebinding, injection preferences, overlay anchor preference, Reset to Defaults. *(See [PLAN_SETTINGS.md](./PLAN_SETTINGS.md). Apply Provider Settings rebuilds the dictation coordinator; other settings still require their documented restart paths.)*
- ✅ API key entry and Keychain persistence. *(Provider pane is the canonical home; the menubar ElevenLabs key action shares the same save path via `APIKeyController`. Apple Speech dictation uses no key; an ElevenLabs key remains required for meeting transcription.)*
- ✅ **Floating overlay UI** (`Sources/PlatformApple/Mac/Overlay/`): NSPanel + VU meter view + lifecycle integration. *(Implemented under `Apps/WhatchuSayMac/WhatchuSayMac/HUD/` rather than the originally planned path.)*
- ✅ **Cancellation flow**: second `CGEventTap` filter for cancel key; consume only during dictation states; orchestrator handles `.cancelDictation`. *(Gate driven by `setDictating(_:)` from orchestrator session events.)*
- ✅ Per-app injection override UI. *(Output pane → "Per-app overrides" table with `RunningAppPicker` sheet; `StrategySelector` now also honors a global `defaultStrategy` field, covered by `Tests/InjectorTests`.)*
- ✅ Permission-fix-it deep links to System Settings. *(`PermissionDeepLink` covers Accessibility and Microphone panes; `HotkeySourceError.accessibilityDenied` and orchestrator `.permissionDenied(.microphone)` both route into the menubar fix-it button.)*

**Exit criteria**: a fresh user account can install, walk through onboarding (including privacy disclosure), and dictate within 5 minutes. Cancellation works in both press-hold and (stub) hands-free.

### Milestone 1.4 — Hands-free, reliability, sleep/wake (week 6–8)

**Outcome**: double-tap-toggle works; provider failures surface cleanly; sleep/wake handled.

**Status (2026-04-30)**: ~70% — FSM hands-free, sleep/wake, empty-result handling, yellow icon + error log, permission fix-it links, and audio-device disconnect recovery all in. Hands-free per-utterance flush still missing; reconnect path lacks a dedicated "lost" toast.

- ✅ Double-tap toggle activation mode with full state machine integration.
- ❌ **Hands-free per-utterance boundary signal**: implement candidate (a) — quick double-tap inside hands-free flushes current utterance and continues. Validate via dogfood; switch to (b) or (c) if (a) feels wrong. *(FSM treats single keyDown in `handsFree` as exit, not flush-and-continue. Candidate (a) not yet attempted.)*
- ⚠️ **Reconnect policy**: fail-fast — no audio replay, mid-utterance drops surface as toast, user retries manually. *(No replay — good. Drops surface as generic `.error` event into menubar/error log; no dedicated "lost" toast UX.)*
- ✅ Error toasts and degraded-state UI (yellow tray icon, fix-it links). *(Yellow icon ✅, persistent recent-errors menu ✅, manual dismiss ✅, lifecycle clear on successful inject ✅, permission fix-it deep links ✅. No transient toast UI — the persistent menubar surface replaces it.)*
- ✅ Audio device disconnect recovery. *(`AudioConfigurationObserver` subscribes to `AVAudioEngineConfigurationChange` and dispatches into `Orchestrator.handleAudioInterruption()`, which yields a clear `.error` event then tears the session down so the user retries against the new device.)*
- ✅ **Sleep/wake observer**: graceful close on sleep; transparent reconnect on next activation. *(Wake intentionally not observed — next session opens fresh.)*
- ✅ Empty result handling (silent — no notification, no inject).

**Exit criteria**: kill Wi-Fi mid-utterance — gets a clear "lost" toast, no crash, no garbled output. Mac sleeps for 30+ minutes — first dictation post-wake works without manual intervention. Hands-free tested across a 30-minute writing session.

### Milestone 1.5 — Daily-driver polish + iOS feasibility spike (week 8–11)

**Outcome**: shippable v1 — code-signed, notarized, distributable, with history, usage tracking, autostart. iOS architecture validated.

**Status (2026-04-29)**: ~25% — recent-transcripts menu and iOS spike are done; provider abstraction proven via `STTMockProvider` in `OrchestratorTests`. Usage persistence/UI, autostart, notarization, and README still missing. Personal dogfood pending.

- ✅ Transcription history view (chronological list, copy-to-clipboard). *(Implemented as menubar submenu via `RecentTranscriptsMenu`, not a dedicated window — within the spirit of the requirement.)*
- ❌ **Usage tracking implementation**: `Sources/Usage/`, settings pane, menubar indicator (configurable). *(`UsageTracker` is in-memory stub; no persistence, no settings pane, no indicator.)*
- ❌ `SMAppService` autostart integration.
- ⚠️ Notarization script and packaging. *(`Apps/WhatchuSayMac/scripts/install-local.sh` + `Makefile` ditto a Debug build to `/Applications`; no notarization workflow.)*
- ❌ README + landing page (or GitHub release page) with screenshots. *(No `README*` at repo root.)*
- ⚠️ **Second-provider mock validation**: implement `STTMockProvider` end-to-end with Orchestrator to confirm provider abstraction holds. Bonus: skeletal `STTDeepgram` adapter. *(`STTMockProvider` is wired through `OrchestratorTests` so abstraction is proven; no `STTDeepgram` skeleton yet.)*
- ✅ **iOS feasibility spike** — completed 2026-04-28. Result: in-extension recording is OS-blocked; Phase 2 uses host-app-recording flow. See [TECH_SPEC §8.3](./TECH_SPEC.md#83-phase-15-feasibility-spike-outcome--host-app-recording-is-primary).
- ⏳ Personal dogfood: 2 weeks of replacing Wispr Flow exclusively. *(Not yet started as a tracked exercise.)*

**Exit criteria**: PRD §10 success criteria met. Memory under 200 MB across 8-hour workday. 100 dictations with zero data loss (cancellations and connection-lost-with-clear-error counted as not-data-loss). Feasibility spike answered (✅ completed; see above).

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
| iOS feasibility spike fails | ✅ Resolved 2026-04-28 — spike confirmed in-extension recording is OS-blocked; Phase 2 redesigned around host-app-recording flow |

---

## Phase 2 — iOS keyboard extension

**Goal**: same dictation experience adapted to iOS, using the **host-app-recording flow** with URL-scheme handoff. Keyboard is a thin launcher + paster; the host app is the dictation surface.

**Architecture decided** (Phase 1.5 spike, 2026-04-28): in-extension audio capture is blocked at the OS level on iOS — see [TECH_SPEC §8.3](./TECH_SPEC.md#83-phase-15-feasibility-spike-outcome--host-app-recording-is-primary). Phase 2 implements the redesigned flow; no further gating decision is pending.

Starts after Phase 1 hits exit criteria and stabilizes for ~1 week of real use.

### Milestone 2.1 — iOS host app foundation (week 1)

**Outcome**: host app compiles, settings work, App Group + Keychain Sharing wired, URL scheme registered.

- `WhatchuSayiOS` Xcode project with host app + extension target.
- App Group container (`group.s900mhz.WhatchuSay`) + Keychain Sharing access group configured.
- Custom URL scheme `whatchusay://` registered, with handler stub for `record?return=…&targetBundleID=…`.
- Settings UI ported from Mac.
- Privacy disclosure pane.
- Onboarding flow including keyboard-install + "Allow Full Access" instructions.
- API key entry + test connection from host app.

**Exit criteria**: host app installs from Xcode, settings persist, opening `whatchusay://record?return=…` from another app launches it and reaches the handler.

### Milestone 2.2 — Host-app dictation surface (week 1–3)

**Outcome**: full press-and-hold dictation works inside the host app, identical Mac experience adapted to touch.

- iOS `AVAudioSession` setup in `Sources/Audio/AVAudioCapture.swift` (`.record` / `.measurement`).
- Mic button surface with `UILongPressGestureRecognizer` driving `KeyboardActivationSource` → existing `ActivationStateMachine`.
- Provider integration via shared `Sources/STTElevenLabs/` — unchanged from Mac.
- VU meter + recording overlay (iOS analog of Mac's floating overlay).
- On finalize: write transcript to App Group named pasteboard `group.s900mhz.WhatchuSay.transcript` and history SQLite; then open the return URL.
- Cancellation parity with Mac (touch-up-outside or explicit cancel button).
- Recent transcripts viewer in host (reads same shared SQLite).
- Memory profile baseline for the host app.

**Exit criteria**: launching the host via URL scheme, holding the mic, releasing → transcript lands on the named pasteboard and the host opens the return URL. Works in all-day personal use for 3+ days.

### Milestone 2.3 — Keyboard extension (week 3–4)

**Outcome**: thin keyboard extension closes the loop — launches host on tap, pastes on return.

- Extension target with `RequestsOpenAccess`.
- `UIInputViewController` subclass with SwiftUI mic button.
- Tap → `extensionContext?.open(URL(string: "whatchusay://record?…"))` with cached `targetBundleID` and best-available `return` URL.
- On regain-focus: read named pasteboard → `UITextDocumentProxy.insertText` → mark consumed sentinel in App Group `UserDefaults`.
- Brief "Discard" affordance (~600 ms) before auto-paste, per [TECH_SPEC §8.3.4](./TECH_SPEC.md#834-auto-paste-vs-explicit-confirm).
- Recent transcripts strip (reads shared SQLite).
- Memory profile — under 48 MB ceiling continuously (target ~22 MB per [TECH_SPEC §8.3.5](./TECH_SPEC.md#835-memory-budget-reset)).

**Exit criteria**: dictation round-trip (keyboard → host → keyboard → paste) works in 5 different host apps (Notes, Messages, Safari, Slack, a code editor like Working Copy). Extension RSS stays under 30 MB across 20 round-trips.

### Milestone 2.4 — Polish & ship (week 4–5)

**Outcome**: TestFlight beta, then App Store submission.

- Onboarding polish — keyboard install + "Allow Full Access" + URL-scheme handoff are the trickiest part of iOS UX.
- "Allow Full Access" justification copy (URL launching + App Group pasteboard read; **not** mic, since we don't record in the extension — this should help App Review).
- Return-URL fallback UX when the originating app doesn't advertise an `x-source-app` URL.
- TestFlight beta — solo first, then small cohort.
- App Store submission with privacy policy and Full Access justification.

**Exit criteria**: PRD §10 Phase 2 success criteria met. App Store approves on first or second submission.

### Phase 2 risks

| Risk | Mitigation |
| --- | --- |
| Originating apps don't advertise a return URL | Fallback to "Open Wherever You Were" affordance in host; document expected behavior per app class |
| Named-pasteboard race (extension reads before host writes) | "Consumed" sentinel + transcript-id check in App Group `UserDefaults`; insertText only on fresh entries |
| User stays in host app instead of being returned | Acceptable degraded path — transcript is still on pasteboard; surface a "back to {app}" button explicitly |
| 48 MB ceiling violated despite thin extension | Profile from start of 2.3; suspect SwiftUI scene complexity first |
| App Review rejects "Allow Full Access" justification | Justification is stronger than competitors' (no mic in extension); pre-research approved patterns |
| iOS kills host app between record and return | Persist transcript to SQLite *before* opening return URL; extension reads from SQLite as backup if pasteboard is empty |

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

---

## Phase 4 — Meeting transcription (in progress)

Cross-platform Swift complete (Tasks 1–17, 19, library half of 28b — 211 tests passing). Mac-app UI scaffolded but pending Xcode IDE integration. Pipeline:

- Spike: [`docs/SPIKE_MEETING_TRANSCRIPTION.md`](./SPIKE_MEETING_TRANSCRIPTION.md)
- Design: [`docs/superpowers/specs/2026-05-02-meeting-transcription-design.md`](./superpowers/specs/2026-05-02-meeting-transcription-design.md)
- Plan: [`docs/superpowers/plans/2026-05-02-meeting-transcription.md`](./superpowers/plans/2026-05-02-meeting-transcription.md)

### 4.1 Cross-platform Swift — done

- ✅ `Sources/Meeting/` target: `Speaker`, `Segment`, `MeetingTranscript`, `AttendeeList`, `MeetingSession`
- ✅ `MeetingLibrary` disk persistence + `findIncomplete()` for crash recovery
- ✅ `BatchTranscriber` capability protocol in `STTCore`; `ElevenLabsBatchTranscriber` (Scribe v2) in `STTElevenLabs`
- ✅ `TranscriptMerger`, `MeetingTranscriptionPipeline`, `ContentBasedSpeakerNameMapper`
- ✅ `MeetingOrchestrator` with `start`/`stop`/`recover` lifecycle and recorder-factory injection
- ✅ `MicCapture` and `SystemAudioCapture` (Core Audio Process Tap, macOS 15+)
- ✅ `AppConfig` schema v2 with `MeetingsConfig` + migration handler

### 4.2 Mac-app integration — pending Xcode IDE

- ☐ Add `Apps/WhatchuSayMac/WhatchuSayMac/Meeting/` files to Xcode project
- ☐ Add `Meeting` SwiftPM dependency to the Mac app target
- ☐ Wire `MeetingsCoordinator` from `AppCoordinator`
- ☐ Add Start/Stop meeting menu items to `StatusItemController`
- ☐ Build via Xcode IDE, install via `make install`, smoke test with a real Zoom call

### 4.3 Deferred

- Periodic audio flush via segmented writers (Task 28a) — current crash window is bounded by `AVAudioFile`'s flush cadence
- LLM-backed `SpeakerNameMapper` — content-based mapper handles the common case for v1
- Past-meetings library window — users navigate via "Reveal in Finder" on the Meetings settings pane
- Detection-based trigger, calendar OAuth, live captions, voiceprint enrollment — all per spec §13
