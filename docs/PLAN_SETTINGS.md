# Plan — Settings window (Phase 1.3)

| Field | Value |
| --- | --- |
| Status | Ready for implementation |
| Last updated | 2026-04-30 |
| Related | [PRD.md](./PRD.md), [TECH_SPEC.md §9](./TECH_SPEC.md), [ROADMAP.md Milestone 1.3](./ROADMAP.md) |
| Scope | macOS Settings window. Schema + `ConfigStore` are cross-platform; iOS port is Phase 2.1. |

---

## 1. Why now

Roadmap Milestone 1.3 sits at ~45% and the Settings window is its single largest unchecked item. It also blocks:

- **Onboarding** (1.3): the wizard writes into the same `AppConfig` + Keychain.
- **Per-app injection overrides** (1.3): infrastructure exists in `StrategySelector`; no UI to edit.
- **Usage tracking** (1.5): needs both a config pane (indicator, threshold) and a viewer pane.
- **iOS host app** (2.1): "Settings UI ported from Mac" — every pane we build here gets reused.

Everything except the Usage *viewer* falls in Phase 1.3.

## 2. Current state

- [Sources/Core/AppConfig.swift](../Sources/Core/AppConfig.swift) is a stub (`schemaVersion` only).
- No `ConfigStore`, no UserDefaults reads, no migration handlers. Hotkey + provider config are effectively hard-coded today.
- API key entry already works via [APIKeyPrompt.swift](../Apps/WhatchuSayMac/WhatchuSayMac/APIKeyPrompt.swift) → Keychain.
- Per-app override data type exists in `InjectionConfig.perAppOverrides`; no editor.

So the work is: flesh out the `AppConfig` sub-structs from TECH_SPEC §9.2 → write `ConfigStore` → migrate existing call sites to read through it → build the Settings window.

## 3. UX sketch

Standard macOS `Settings { TabView }` — toolbar tabs, not a sidebar. Six panes for 1.3, plus a Usage pane in 1.5.

### 3.1 General

- Launch at login (`SMAppService`) — toggle, `StartupConfig.launchAtLogin`.
- Floating overlay — enable toggle, anchor picker (near-cursor / screen-bottom), screen picker when screen-bottom is selected. `OverlayConfig`.
- Menubar usage indicator — segmented (off / minutes / cost). `UsageConfig.menubarIndicator`. *(The chart that goes with it lives in the Usage pane in 1.5.)*
- Footer: **Reset to Defaults…** button with confirmation alert. Single button for the whole app, not per-pane.

### 3.2 Provider

- Provider picker — `ElevenLabs` only for now, picker present so the shape is right when more land.
- Model, language, hints (comma-separated input → `[String]`).
- API key field (secure input, "Show" toggle) — canonical home; the menubar "Set API Key…" entry stays as a shortcut into this pane.
- **Test Connection** button — opens a WebSocket, confirms handshake + auth, closes. No audio sent. Green check / red X with the provider's error message.

### 3.3 Shortcuts

- Dictation hotkey — record-to-set widget (see §6.3).
- Cancel hotkey — same widget.
- Press-hold threshold (ms) — number stepper, default 250.
- Double-tap window (ms) — number stepper, default 300.

### 3.4 Output

- Default injection strategy — segmented (auto / always-paste / always-type).
- `typeMaxCharsForAuto` — number stepper, default 8.
- Leave-on-clipboard toggle — `InjectionConfig.leaveOnClipboard`.
- **Per-app overrides table** — three columns: app (bundle ID + display name + icon if available), strategy menu, delete button. "Add from running apps…" button opens an `NSWorkspace.shared.runningApplications` picker. Inline within the pane; promote to a sheet only if real-world use exceeds ~10 rows.

### 3.5 History

- Enabled toggle.
- Retention days — number stepper, default 30.
- Max entries — number stepper, default 1000.
- **Clear History…** destructive button with confirmation.

### 3.6 Privacy

- Disclosure prose verbatim from TECH_SPEC §10.1.
- Acknowledgment status: "Acknowledged on YYYY-MM-DD" once `hasReadDisclosure` flips, with a re-show button.
- Provider data-handling policy link — URL pulled from `ProviderRegistry` (see §4.8), not stored in `AppConfig`.
- **First-run gate**: on launch, if `hasReadDisclosure == false`, present this pane's contents as a modal sheet with an "I understand" button before the menubar becomes interactive (see §4.9).

### 3.7 Usage *(Phase 1.5)*

- 30-day line chart (Swift Charts), monthly totals, estimated cost based on user-configured rate.
- Monthly alert threshold (minutes) — `UsageConfig.monthlyAlertThresholdMinutes`.
- Estimate disclosure copy per TECH_SPEC §10.1031–1032.

## 4. Trade-offs and decisions

### 4.1 Toolbar tabs vs sidebar

**Decision: toolbar tabs** via `Settings { TabView }`. Six panes fits comfortably; sidebar is overkill and fights Mac convention. Easy to swap if the count grows.

### 4.2 Per-app overrides — inline table vs sheet vs separate pane

**Decision: inline table in the Output pane**, with an "Add from running apps…" picker button. Push to a sheet only if the table grows past ~10 rows during dogfood. Cheapest right thing.

### 4.3 Hotkey rebinder

**Decision: build the custom widget for 1.3.** SwiftUI ships nothing for "press a combo to capture", so this needs an `NSViewRepresentable` backed by `NSEvent.addLocalMonitor(matching: .keyDown)`. Highest-effort piece in this plan; do it last so the rest of the window is shippable in case it slips. Cancel-key reuses the same widget.

### 4.4 API key — duplicate or move?

**Decision: Provider pane is canonical.** The menubar entry stays as a shortcut into this pane (no in-place editor). "Test Connection" lives only in settings, not the menubar.

### 4.5 Reset to Defaults — global vs per-pane

**Decision: single button** in the General pane footer with confirmation. Clearer mental model; per-pane resets invite half-reset confusion.

### 4.6 Recent transcripts in Settings?

**Decision: no.** It already lives in the menubar submenu ([RecentTranscriptsMenu](../Apps/WhatchuSayMac/WhatchuSayMac/History/)). Not in the roadmap; not duplicating.

### 4.7 Test Connection — handshake or real audio?

**Decision: handshake only.** Open WebSocket, send the auth/init frame, confirm response, close. Doesn't need mic permission and doesn't burn provider quota. Surfaces 95% of the failure modes (bad key, bad URL, network).

### 4.8 Provider data-policy URL — config field or registry?

**Decision: static `ProviderRegistry`, not in `AppConfig`.** New file `Sources/Core/ProviderRegistry.swift` keyed by provider name, returning `displayName`, `dataPolicyURL`, etc. The Privacy pane reads `ProviderRegistry.url(for: config.provider.providerName)`. Treats the URL as code-owned metadata about the provider, not a user preference — avoids drift, migration churn, and the "what should the default be on import" question. When ElevenLabs moves their policy page, that's a code update.

### 4.9 First-run privacy disclosure — modal now or wait for onboarding?

**Decision: ship a slim first-run modal in this work.** On launch, if `PrivacyConfig.hasReadDisclosure == false`, present the Privacy pane's contents as a sheet with an "I understand" button before the menubar becomes interactive. Acking flips the bit. The onboarding wizard, when it lands, replaces this surface — same flag.

Without this, anyone who installs from a DMG, resets config, or runs a build before onboarding ships never sees the disclosure, and Phase 1.3 exit criteria (which include the disclosure) can't be claimed. The slim modal is ~30 LOC and reuses the Privacy pane's prose.

### 4.10 Verbose-logging toggle — ship now, half-ship, or defer?

**Decision: defer entirely.** Drop the General → Advanced disclosure from this work. Verbose logging stays controllable via launch-arg / env var (whatever `Logging.swift` already supports); we'll document the existing path. The UI toggle gets its own follow-up that bundles a small refactor of `Logging.swift` (atomic level + wrapper that checks before forwarding) so flipping the toggle takes effect live. Half-shipping (toggle that only takes effect after restart) is the worst option — invites "why isn't this doing anything?" support cost.

## 5. Data layer

### 5.1 Flesh out `AppConfig`

Implement every sub-struct from TECH_SPEC §9.2 verbatim in [Sources/Core/AppConfig.swift](../Sources/Core/AppConfig.swift). One file, public, `Codable + Sendable`. Defaults for every field so a fresh user gets a sensible config on first launch.

### 5.2 `ConfigStore`

New file `Sources/Core/ConfigStore.swift`. Responsibilities:

- Load on launch from UserDefaults (per spec §9.1: Mac uses standard UserDefaults; iOS uses `UserDefaults(suiteName: appGroupID)`).
- Single `@Observable` instance held by `AppCoordinator`; SwiftUI panes bind directly.
- Writes are debounced (~250ms) and serialized through a single actor to avoid torn writes.
- Exposes typed getters and a `mutate { $0.hotkey.keyCode = … }` API to keep call sites readable.
- On decode failure: log, write defaults, do not crash.

### 5.3 Migration

Stub `Sources/Core/ConfigMigration.swift` with the framework from spec §9.4. We're at `schemaVersion = 1`, so no handlers yet — but ship the dispatch loop now so v2 is a one-line addition.

### 5.4 Migrating existing call sites

Today, hotkey and provider config are effectively hard-coded. As part of this work:

- Hotkey source reads `HotkeyBinding` from `ConfigStore`, observes changes, rebinds taps.
- ElevenLabs adapter reads `ProviderConfig.model/language/hints` from store.
- `StrategySelector` reads `InjectionConfig` from store.
- `APIKeyPrompt` keeps writing to Keychain, but the Provider pane is now the primary writer.

This refactor lands *before* the SwiftUI panes so we don't have two sources of truth in flight.

## 6. Implementation order

The order de-risks: foundation first, then trivial panes to validate the binding pattern, then complex widgets last.

1. **`AppConfig` + `ConfigStore` + migration scaffold.** No UI. Unit-tested.
2. **`ProviderRegistry`** with ElevenLabs entry (display name, data-policy URL). Tiny; ships alongside step 1.
3. **Migrate existing call sites** (hotkey, provider config, strategy selector) onto `ConfigStore`. Behavior unchanged from user's POV.
4. **Settings window scaffold.** Empty `TabView` with all six panes as placeholders. Verifies window lifecycle, observability binding, dirty-state handling.
5. **Trivial panes**: General, History, Privacy. Mostly toggles and numbers. Shake out the two-way-binding pattern.
6. **First-run privacy modal.** Reuses the Privacy pane's content view; sheet presented from `AppCoordinator` when `hasReadDisclosure == false`.
7. **Provider pane** including Test Connection (small async task; reuse provider's session-open path with an early-close).
8. **Output pane** including per-app override table + running-apps picker.
9. **Shortcuts pane** with the custom hotkey rebinder widget. Ships last because it's the highest-risk piece.
10. **Reset to Defaults** in General footer, once all panes exist.

## 7. Out of scope

- Usage *viewer* pane (Phase 1.5; the configuration toggles for it ship in General now).
- Onboarding wizard (tracked separately in roadmap; reuses `ConfigStore` + Keychain + the first-run modal pattern from §4.9).
- Multi-provider switching UI beyond the picker shape.
- Notification sounds, dictionary/replacements UI.
- iOS port (Phase 2.1).
- **Verbose-logging settings toggle** (see §4.10). Bundle with the `Logging.swift` live-toggle refactor in a follow-up.

## 8. Open questions

None — all decisions resolved in §4. Ready to start at step 1 of §6.
