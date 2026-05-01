# Plan — Live re-config of the running orchestrator

| Field | Value |
| --- | --- |
| Status | Drafted; not yet scheduled |
| Last updated | 2026-05-01 |
| Related | [PLAN_SETTINGS.md](./PLAN_SETTINGS.md), [TECH_SPEC.md §9](./TECH_SPEC.md), [ROADMAP.md Milestone 1.3](./ROADMAP.md) |
| Scope | macOS — `Orchestrator`, `AppCoordinator`, `HotkeySourceMac`, `InjectorMac`, `StrategySelector`. iOS port inherits the same model when Phase 2 lands. |

---

## 1. Why now

The Phase 1.3 Settings work shipped six functional panes that persist user choices through `ConfigStore` immediately, but **none of those choices reach the running orchestrator until the next coordinator restart**. The only restart trigger today is saving a new API key — every other pane (Provider, Output, Shortcuts) advertises a footer caption to that effect. Acceptable for v1; not the final shape.

The fix isn't blocking 1.3 exit (which gates on onboarding + the existing dictate-within-5-minutes flow) but it's the most-asked-for follow-up: changing your hotkey, model, or per-app override should "just work" without a relaunch.

## 2. Where the gaps are

| Field | Captured at | First effective on |
| --- | --- | --- |
| `provider.providerName` | Coordinator init (picks adapter) | Coordinator restart |
| `provider.model` / `language` / `hints` | `Orchestrator.init` (`SessionConfig` snapshot) | Coordinator restart |
| `injection.defaultStrategy` | `StrategySelector.init` | Coordinator restart |
| `injection.typeMaxCharsForAuto` | `StrategySelector.init` | Coordinator restart |
| `injection.terminalAllowlist` | `StrategySelector.init` | Coordinator restart |
| `injection.perAppOverrides` | `StrategySelector.init` | Coordinator restart |
| `injection.leaveOnClipboard` | `InjectorMac.init` (`restoreClipboard`) | Coordinator restart |
| `hotkey.keyCode` / `modifiers` | `HotkeySourceMac.init` (translator) | Coordinator restart |
| `hotkey.cancelKeyCode` / `cancelModifiers` | `HotkeySourceMac.init` (translator) | Coordinator restart |
| `hotkey.pressHoldThresholdMs` / `doubleTapWindowMs` | `ActivationStateMachine.init` | Coordinator restart |
| `overlay.*` | HUD already reads live (verify) | n/a |
| `startup.launchAtLogin` | Side effect (`SMAppService`) | Immediate |
| `usage.*` | No consumer yet | n/a |
| `history.*` | No consumer yet (1.5 work) | n/a |
| `privacy.*` | First-run modal + Privacy pane | Immediate |

The "live re-config" question is really three sub-questions, with different answers:

1. **Cheap fields, consulted per session-open** (`SessionConfig`, `StrategySelector`'s value-type fields): rebuild the value on every consult.
2. **Expensive fields with persistent state** (`HotkeySourceMac`'s `CGEventTap`, the FSM's threshold timers): rebind in place rather than tear down and recreate.
3. **Provider identity** (`provider.providerName`): a different adapter entirely; this *should* keep requiring a coordinator restart.

## 3. Approach options

### 3.1 Option A — Closures on every read (recommended)

Each consumer takes a `() -> Snapshot` closure instead of a captured snapshot. AppCoordinator constructs the closures referencing `ConfigStore`. The orchestrator and selector read fresh values per session-open / per resolve.

| Field | Change |
| --- | --- |
| `Orchestrator.init` | Accept `sessionConfigSource: @Sendable () -> SessionConfig` instead of a captured `sessionConfig`. Read in `openSession`. |
| `StrategySelector` | Replace value fields with `injectionConfigSource: @Sendable () -> InjectionConfig`. `resolve` reads on each call. Existing convenience init takes a fixed `InjectionConfig` so SwiftPM tests don't break. |
| `InjectorMac` | Already accepts `restoreClipboard: Bool` at init. Change to `restoreClipboardSource: @Sendable () -> Bool`, read inside the paste path. |
| `ActivationStateMachine` | Already takes thresholds at init. Promote to closures or expose `setThresholds(...)` for live update. |

**Pros**: smallest change to call-sites that already depend on these types; no observation plumbing; new sessions pick up changes immediately.

**Cons**: closure indirection on hot path (negligible — these types are not in the audio loop); test harnesses need to wrap fixed values in closures; subtle lifetime question (closure captures `ConfigStore` strongly).

### 3.2 Option B — Observation-driven rebuilds

`AppCoordinator` subscribes to `ConfigStore` via `withObservationTracking` (re-arming pattern already used by `StatusItemController.startStateObservation`). On change to a tracked field, tears down + rebuilds the affected subsystem.

**Pros**: keeps consumers as pure value-receivers; matches existing pattern in `StatusItemController`; explicit when a rebuild happens.

**Cons**: rebuild churn (every keystroke into a Stepper would trigger a full orchestrator rebuild absent debouncing); rebuild during an active dictation is hostile; requires careful field-level tracking to avoid over-firing.

### 3.3 Option C — Hybrid (Option A + targeted in-place rebind)

Use Option A for *cheap, value-type* consumers (orchestrator, selector, injector). For the one consumer with persistent OS state — `HotkeySourceMac`'s `CGEventTap` — add a `setBindings(activation:cancel:)` API that swaps the translator without uninstalling the tap. AppCoordinator observes only `hotkey.*` fields and calls `setBindings` debounced.

This is the recommended shape: cheap reads where they're cheap, in-place updates where the OS handle is expensive to recreate, and observation only for the one path that genuinely needs it.

## 4. Trade-offs and decisions to make

### 4.1 Closure capture of `ConfigStore`

Closures stored inside `Orchestrator` / `StrategySelector` will hold the store strongly. `ConfigStore` is a long-lived MainActor singleton owned by `AppDelegate`, so a strong reference from the orchestrator is fine — both have the same lifetime. Document this so a future refactor that introduces multiple coordinators doesn't accidentally leak.

### 4.2 Re-config during an active dictation

If the user changes `defaultStrategy` mid-dictation, the change should apply on the *next* session, not the current one. Option A naturally gives this: `SessionConfig` reads on `openSession`. `StrategySelector.resolve` is called once per inject, after `endOfStream` — so a mid-dictation change *would* affect the inject decision for the in-flight session. Probably fine; users don't change settings mid-dictation in practice. Document.

### 4.3 Hotkey rebind safety

`CGEventTap` callback runs on the main run loop. `setBindings` must be safe to call from MainActor without breaking the tap's invariants. Easiest: lock-protected swap inside the `TapContext`, mirroring how `setDictating(_:)` already works.

### 4.4 Provider switching

Provider switching (`provider.providerName` changes from `elevenlabs` to a new adapter) is genuinely a different adapter — Option A doesn't help. Either:
- Keep "save API key for the new provider" as the trigger for adapter switch (current behavior), or
- Add an explicit "Switch provider" path that tears down the orchestrator and rebuilds with the new adapter.

The latter is cleaner once a second provider lands; deferred.

### 4.5 Threshold values and the FSM

`ActivationStateMachine.pressHoldThresholdMs` and `doubleTapWindowMs` are captured in the FSM. The FSM is held by `Orchestrator`. Two options:
- Pass closures into the FSM init (Option A everywhere).
- AppCoordinator rebuilds the FSM on threshold change. The FSM is cheap to recreate but may be holding a partial-keypress state — re-create *while idle*, not during a dictation. Add a guard.

The closure approach is simpler and avoids the "while idle" coordination.

## 5. Recommended implementation order

1. **`StrategySelector` closure-source.** Smallest, lowest-risk start. Change the type to read from a closure. Update `Tests/InjectorTests` to construct via a fixed-config convenience init. Verify all 9 existing tests still pass with the new shape.
2. **`InjectorMac.restoreClipboardSource`.** Same shape as 1.
3. **`Orchestrator.sessionConfigSource`.** Threaded through `AppCoordinator`. `OrchestratorTests` use a `{ SessionConfig() }` closure.
4. **`HotkeySourceMac.setBindings(activation:cancel:)` + observation.** AppCoordinator observes `configStore.config.hotkey` (debounced) and calls `setBindings`. Document the OS-handle invariant.
5. **`ActivationStateMachine` threshold closures** (or rebuild path). Verify hands-free + double-tap tests still pass.
6. **Remove the "takes effect on next coordinator restart" footer captions** from Provider, Output, Shortcuts panes.
7. **Tests**: add a CoreTests-level integration test asserting that mutating `ConfigStore` after coordinator init produces the new behavior on the next session-open. This is the load-bearing assertion.

## 6. Out of scope

- Multi-provider switching UI (separate concern; needs a real second adapter first).
- Live-toggle for verbose logging — already deferred per [PLAN_SETTINGS.md §4.10](./PLAN_SETTINGS.md), bundle with the `Logging.swift` refactor when picked up.
- iOS port. Phase 2 work; same closure pattern transfers cleanly.
- HUD overlay anchor live-updates (the HUD already reads the relevant flags live; verify but no work expected).

## 7. Open questions

- **Convenience init for `StrategySelector`/`InjectorMac` etc. — keep or drop?** Tests today construct with fixed values. Keeping a fixed-value convenience init `{ Self(closure: { fixedValue }) }` minimises churn. Decide before step 1.
- **Debounce window for hotkey rebind observation.** During a recorder field's "press a key" capture, the user releases the captured combo immediately. We don't want a rebind on every keystroke if the user is mid-recording. ~250ms feels right — same as the ConfigStore save debounce, so rebinding lines up with persistence.
- **Should `OverlayConfig` reads be live too?** The HUD subscribes to overlay config somewhere; verify the path before changing anything. If it already reads live, no work; if not, treat it as a one-line addition under step 1.
