# Plan — Replace `MenuBarExtra` with a manually-owned `NSStatusItem`

| Field | Value |
| --- | --- |
| Status | Draft — pending review |
| Last updated | 2026-04-30 |
| Related | [WhatchuSayMacApp.swift](../Apps/WhatchuSayMac/WhatchuSayMac/WhatchuSayMacApp.swift), [MenuBarIcon.swift](../Apps/WhatchuSayMac/WhatchuSayMac/MenuBarIcon.swift), [PRD.md](./PRD.md) |
| Scope | macOS only; bug fix + small architectural shift in the menu bar surface |
| Deployment target | macOS 26.3 (project setting) |

---

## 1. Why now

The user reports: **the menu-bar icon sometimes disappears at runtime; the only known recovery is force-quit + relaunch.** This blocks access to transcription history and the API key prompt.

The icon is currently created via SwiftUI's `MenuBarExtra` scene in [`WhatchuSayMacApp.swift`](../Apps/WhatchuSayMac/WhatchuSayMac/WhatchuSayMacApp.swift). `MenuBarExtra` is a SwiftUI wrapper around AppKit's `NSStatusItem`, but it gives us:

- **No public handle to the underlying `NSStatusItem`** — see Apple Feedback Assistant reports [FB10185203](https://github.com/feedback-assistant/reports/issues/328) (no programmatic show/hide), [FB10184971](https://github.com/feedback-assistant/reports/issues/327) (no way to open Settings), [FB10185325](https://github.com/feedback-assistant/reports/issues/329) (no "no presentation" style). Third-party access requires runtime gymnastics ([MenuBarExtraAccess](https://github.com/orchetect/MenuBarExtraAccess)).
- **No menu-open hook** — [FB13683950](https://github.com/feedback-assistant/reports/issues/475) — and `.menu` style does not re-render its body when the menu opens, [FB13683957](https://github.com/feedback-assistant/reports/issues/477). Both are still open as of macOS 26 / Xcode 26.
- **No recovery API** if the icon vanishes. There is no "rebuild" entry point.

I have **not** found a single named radar that says "MenuBarExtra spontaneously disappears." But the catalog of unresolved `MenuBarExtra` lifecycle bugs is large, the symptom is consistent with what other developers report, and the API surface gives us no in-process hook to recover. Switching to a manually-owned `NSStatusItem` does two things at once:

1. Moves us off the buggy abstraction.
2. Gives us a strong reference and lifecycle hooks so that *if* the system does ever reorganize the menu bar (sleep/wake, display change, memory pressure), we can detect and rebuild.

`NSStatusItem` is the documented public AppKit API for this surface ([Apple Developer Documentation](https://developer.apple.com/documentation/appkit/nsstatusitem)) and has none of the above limitations.

## 2. User-visible goal

The menu bar icon must be present and clickable for the entire lifetime of the running app, including across:

- system sleep/wake
- external display connect/disconnect
- macOS notch overflow events (where the system hides items behind the camera notch)
- arbitrary long-running sessions (24h+)

If the icon ever does go missing, the app must reattach it without a relaunch.

The menu's *contents* and visual behavior must be preserved bit-for-bit relative to today: same icon set, same tint logic, same submenus (Recent Transcripts, Recent Errors), same dynamic Set/Update API Key labelling, same fix-it deep-links, same Quit ⌘Q.

## 3. Approach: manually-owned `NSStatusItem` + native `NSMenu`

### 3.1 The status item itself

Create the status item once, in `AppDelegate.applicationDidFinishLaunching`, and retain it as a strong stored property. This is the well-documented pitfall in NSStatusItem usage — if it is not retained, ARC deallocates it and the icon vanishes ([Peter Arsenault — macOS Status Bar apps](https://www.peterarsenault.industries/posts/macos-status-bar-apps/part01/)).

```swift
// new: Apps/WhatchuSayMac/WhatchuSayMac/StatusItemController.swift
@MainActor
final class StatusItemController {
    private let state: AppState
    private let recentTranscripts: RecentTranscriptsStore
    private let errorLog: ErrorLogStore
    private let onSetKey: () -> Void
    private let onCopyTranscript: (TranscriptEntry) -> Void
    private let onClearTranscripts: () -> Void
    private let onCopyErrorEntry: (ErrorLogEntry) -> Void
    private let onClearErrorLog: () -> Void
    private let onDismissError: () -> Void
    private let onOpenPermission: (PermissionDeepLink) -> Void

    private var statusItem: NSStatusItem?
    private var observationTokens: [NSObjectProtocol] = []
    // ...

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureButton(on: item)
        attachMenu(to: item)
        statusItem = item
        registerSystemObservers()
        startStateObservation()
    }
}
```

`AppDelegate` keeps a single `StatusItemController` for the app's lifetime.

### 3.2 The button: image + tint

`NSStatusItem.button` (typed `NSStatusBarButton?`) replaces the deprecated `image`/`title`/`view` properties. Per the [Apple docs](https://developer.apple.com/documentation/appkit/nsstatusitem), the button is the modern surface for icon and click target.

We already have the icon-name and tint logic in [`MenuBarIcon.swift`](../Apps/WhatchuSayMac/WhatchuSayMac/MenuBarIcon.swift). Both helpers (`iconName(for:)`, `iconTint(for:)`) are pure and unit-tested by [`MenuBarIconTests.swift`](../Apps/WhatchuSayMac/WhatchuSayMacTests/MenuBarIconTests.swift). Plan:

- **Keep `iconName(for:)` unchanged.** It returns SF Symbol names; SF Symbols load into AppKit via `NSImage(systemSymbolName:accessibilityDescription:)`. No test churn.
- **Add a peer `iconTintColor(for:)` returning `NSColor?`** — `nil` = use the system default (template image), `.systemYellow` for the yellow attention state. Apply to the button via `button.contentTintColor`. Keep the existing SwiftUI `iconTint(for:)` if anything still consumes it; otherwise delete it after the migration.
- The button image is set as a *template* (`image.isTemplate = true`) so it picks up dark-mode automatically except when we override `contentTintColor` for the yellow attention state.

### 3.3 The menu: native `NSMenu`, rebuilt on every open

Two options:

| Option | Pros | Cons |
| --- | --- | --- |
| **(A) Native `NSMenu` populated programmatically** ✅ | Matches `.menu` style behavior exactly; gets `NSMenuDelegate.menuWillOpen` (the hook FB13683950 wishes it had); native key equivalents and modifier masks; small code; submenus and separators are first-class | We lose the SwiftUI declarative menu — but only the View shells; the helper logic stays |
| (B) Hosting SwiftUI inside `NSMenuItem.view` via `NSHostingView` | Reuses `RecentTranscriptsMenu`, `ErrorLogMenu` views verbatim | Documented to behave poorly with complex/nested menu controls; submenus and key equivalents become awkward; defeats half the reason we're migrating |
| (C) `NSPopover` + `NSHostingController` | Full SwiftUI freedom inside | This is the `.window` style, not `.menu` style — different UX, more work, and the user explicitly likes the current dropdown |

**Decision: (A).** The current `RecentTranscriptsMenu` and `ErrorLogMenu` SwiftUI views are thin — their non-trivial logic (`label(for:maxLength:)`, `visibleEntries(from:)`, `overflowEntries(from:)`) is already exposed as static helpers and is unit-tested in [`RecentTranscriptsMenuTests.swift`](../Apps/WhatchuSayMac/WhatchuSayMacTests/RecentTranscriptsMenuTests.swift) and [`ErrorLogMenuTests.swift`](../Apps/WhatchuSayMac/WhatchuSayMacTests/ErrorLogMenuTests.swift). Those helpers stay where they are; the View bodies get deleted.

Build pattern:

```swift
final class StatusItemController: NSObject, NSMenuDelegate {
    private func attachMenu(to item: NSStatusItem) {
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu(menu)               // fresh state every open — fixes the FB13683957 staleness class of bugs
    }

    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(statusHeaderItem())     // statusLabel(for: state)
        menu.addItem(.separator())
        menu.addItem(setKeyItem())           // setKeyMenuTitle(for: state)
        menu.addItem(.separator())
        appendRecentTranscripts(to: menu)
        menu.addItem(.separator())
        appendErrorLog(to: menu)
        if let error = state.lastError {
            menu.addItem(.separator())
            menu.addItem(errorLineItem(error))
            if let permission = state.permissionIssue {
                menu.addItem(fixItItem(for: permission))
            }
            menu.addItem(dismissErrorItem())
        }
        menu.addItem(.separator())
        menu.addItem(quitItem())             // ⌘Q
    }
}
```

`appendRecentTranscripts` reuses `RecentTranscriptsMenu.visibleEntries(from:)` / `.overflowEntries(from:)` / `.label(for:maxLength:)` and emits an `NSMenu` "Older…" submenu. `appendErrorLog` mirrors that for errors. Click handlers are `NSMenuItem.target`/`action` + a small dispatcher object that holds the closures.

Because we rebuild the entire menu on `menuWillOpen`, we get fresh state on every open — no `@Observable` re-render trickery, no stale partial captures.

### 3.4 The icon's response to state changes

The button's image needs to update *while the menu is closed* too, so the user sees the icon flip between `mic.slash` ↔ `mic.fill` ↔ yellow attention. We can't rely on `menuWillOpen` for that.

We use Observation framework's tracking closure (available on macOS 14+, project targets 26.3 so this is safe) to drive button updates from `AppState` mutations:

```swift
private func startStateObservation() {
    withObservationTracking {
        applyState()                     // reads state.status / state.lastError
    } onChange: { [weak self] in
        Task { @MainActor in self?.startStateObservation() }   // re-arm
    }
}

private func applyState() {
    guard let button = statusItem?.button else { return }
    button.image = NSImage(systemSymbolName: iconName(for: state),
                           accessibilityDescription: nil)
    button.image?.isTemplate = true
    button.contentTintColor = iconTintColor(for: state)
}
```

This is the standard `withObservationTracking` re-arm pattern Apple documents. One observation cycle per `AppState` mutation; no Combine, no manual KVO.

### 3.5 Recovery: rebuild if the icon goes missing

Defense in depth. Even though `NSStatusItem` is more stable than `MenuBarExtra`, we still register for system events that historically correlate with menu bar reorganization, and we rebuild the item if `isVisible` is ever false when it shouldn't be:

| Notification | Why we observe it |
| --- | --- |
| `NSWorkspace.didWakeNotification` | Sleep/wake is a known trigger for SwiftUI menu-bar oddness |
| `NSApplication.didChangeScreenParametersNotification` | External display connect/disconnect, resolution change, notch reorganization |

On either, we check `statusItem?.isVisible == true`; if the item is gone or `isVisible` was forced to false by an overflow event, we tear down and recreate. This is cheap (creating an `NSStatusItem` is sub-millisecond) and only runs on rare events.

### 3.6 `MenuBarExtra` removal

`WhatchuSayMacApp` currently has `MenuBarExtra` as its only `Scene`. SwiftUI's `App` protocol requires *some* `Scene`. Replace with an empty `Settings { EmptyView() }` scene (the standard pattern for status-item-only apps) or with `MenuBarExtra` *removed entirely* and the `App.body` returning a degenerate scene. The cleanest answer:

```swift
@main
struct WhatchuSayMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    var body: some Scene {
        Settings { EmptyView() }   // never opened; LSUIElement=YES means no Settings menu anyway
    }
}
```

`LSUIElement = YES` is already set in the project file, so the empty Settings scene is invisible.

## 4. File-level change list

| File | Change |
| --- | --- |
| `Apps/WhatchuSayMac/WhatchuSayMac/StatusItemController.swift` | **New.** Owns `NSStatusItem`, builds the `NSMenu` on open, observes `AppState`, handles wake/screen-change recovery |
| `Apps/WhatchuSayMac/WhatchuSayMac/WhatchuSayMacApp.swift` | Remove `MenuBarExtra`. Replace with empty `Settings` scene. `AppDelegate.applicationDidFinishLaunching` now creates and `install()`s a `StatusItemController` after `bootstrap()`. Delete `MenuBarLabelView` and `MenuContentView` |
| `Apps/WhatchuSayMac/WhatchuSayMac/MenuBarIcon.swift` | Add `iconTintColor(for:) -> NSColor?`. Either keep or delete `iconTint(for:) -> Color` depending on whether anything else uses it (HUD does not — it lives in [`HUDView.swift`](../Apps/WhatchuSayMac/WhatchuSayMac/HUD/HUDView.swift) and uses its own colors) |
| `Apps/WhatchuSayMac/WhatchuSayMac/History/RecentTranscriptsMenu.swift` | Delete the SwiftUI View body; promote to a namespace `enum RecentTranscriptsMenu` so the existing static helpers (`label`, `visibleEntries`, `overflowEntries`) keep their public surface and existing tests keep passing without modification |
| `Apps/WhatchuSayMac/WhatchuSayMac/Errors/ErrorLogMenu.swift` | Same treatment: SwiftUI body removed, helpers preserved as `enum ErrorLogMenu` namespace |
| `Apps/WhatchuSayMac/WhatchuSayMacTests/MenuBarIconTests.swift` | No change. `iconName`/`iconTint` continue to work |
| `Apps/WhatchuSayMac/WhatchuSayMacTests/RecentTranscriptsMenuTests.swift` | No change. Tests call static helpers, not the View body |
| `Apps/WhatchuSayMac/WhatchuSayMacTests/ErrorLogMenuTests.swift` | No change. Same reasoning |

New tests:

| File | Purpose |
| --- | --- |
| `Apps/WhatchuSayMac/WhatchuSayMacTests/StatusItemMenuBuilderTests.swift` | Drive `StatusItemController.buildMenuItems(for:)` (factor out a static, side-effect-free builder) and assert on item titles, separators, key equivalents, and submenu structure for each `AppState` shape: idle/listening/needsSetup/startupFailed × with/without `lastError` × with/without `permissionIssue` |

The builder is split into a pure `static` function returning `[NSMenuItem]` so it's testable without mounting an `NSStatusItem`. The wiring layer (`menuWillOpen`, observation, recovery) is glue around that.

## 5. Trade-offs

| Concern | Resolution |
| --- | --- |
| **Loss of declarative SwiftUI menu** | The View bodies are 30-40 lines each and trivial. The complexity that mattered (truncation, overflow split) is already in static helpers and stays declarative-equivalent. Net code is roughly the same. |
| **Icon is now an `NSImage` not a SwiftUI `Image`** | SF Symbols have first-class AppKit support via `NSImage(systemSymbolName:)`. Visual parity is maintained. |
| **Manual menu rebuild instead of automatic SwiftUI re-render** | `menuWillOpen` rebuilds on every open, so the menu is always fresh — strictly *better* than today's behavior (FB13683957 means today's menu *doesn't* re-render on open, which is a latent bug we'd be fixing in passing). |
| **More AppKit code, less SwiftUI** | Yes. The trade is correctness and a recovery story for a buggy abstraction. The codebase already has substantial AppKit (HUD panel, hotkey tap, injector, sleep/wake observer); this fits. |
| **Cannot reproduce the original disappearance to verify the fix** | True. Acceptance criteria below are about *not regressing* the menu's content + behavior. The real verification is "user runs the new build for several days and the icon never disappears." |

## 6. Acceptance criteria

Pre-merge, all of these must hold:

1. Cold launch → icon visible in menu bar within 1s.
2. Click icon → menu shows: status line, Set/Update API Key, Recent Transcripts (or "No recent transcripts"), Recent Errors (or "No recent errors"), Quit. Submenus, separators, and the "Older…" overflow match today's structure 1-to-1.
3. State transitions during a session correctly update the icon shape and tint without any menu interaction (drive a session, observe `mic.slash` → `mic.fill` → `mic.slash`).
4. Trigger an error path (force a transient orchestrator error, e.g. by yanking network mid-session). The icon goes yellow; the menu shows the "Error: …" line and the Dismiss Error item; Dismiss Error clears it.
5. Trigger `.needsSetup` (delete the API key from Keychain, relaunch). Icon is the key glyph; menu shows the "Set ElevenLabs API Key…" entry; the prompt opens and a successful save bringings up `.idle`.
6. Trigger `.startupFailed` with `permissionIssue` set (revoke Accessibility, relaunch). Menu shows the fix-it deep-link button alongside the error line; clicking opens the right Settings pane.
7. Sleep the Mac for >5 minutes, wake it. Icon still present and clickable.
8. Connect/disconnect an external display. Icon still present and clickable.
9. All existing tests pass unchanged. New `StatusItemMenuBuilderTests` cover the table of `AppState` shapes from §4.
10. Quit via ⌘Q from the menu still works.

## 7. What this plan does *not* cover

- Any change to `AppCoordinator`, `AppState`, `Orchestrator`, the HUD, or the audio pipeline. They keep their current shapes.
- Settings window migration. The empty `Settings { EmptyView() }` scene is a placeholder; if a real Settings UI lands later, it gets wired up there.
- Detection telemetry for "the icon went missing." We rely on the wake / screen-change rebuild path. If field reports show the icon still vanishing despite this, a future plan can add a periodic `isVisible` poll or move to a `DispatchSourceTimer`-based watchdog.
- Any change to iOS — this plan is macOS-only.

## 8. Sources

- Apple Developer Documentation — [`NSStatusItem`](https://developer.apple.com/documentation/appkit/nsstatusitem) (current API: `button: NSStatusBarButton?`, `menu: NSMenu?`, `length`, `isVisible`, `behavior`, deprecated legacy properties)
- Apple Developer Documentation — [`NSStatusBar`](https://developer.apple.com/documentation/appkit/nsstatusbar) (`system`, `statusItem(withLength:)`, `removeStatusItem(_:)`)
- Apple Developer Documentation — [`MenuBarExtra`](https://developer.apple.com/documentation/SwiftUI/MenuBarExtra)
- Feedback Assistant Reports — [FB13683957 (`.menu` body re-render)](https://github.com/feedback-assistant/reports/issues/477), [FB13683950 (no menu-open event)](https://github.com/feedback-assistant/reports/issues/475), [FB10184971 (no Settings open)](https://github.com/feedback-assistant/reports/issues/327), [FB10185325 (no "no presentation" style)](https://github.com/feedback-assistant/reports/issues/329), [FB10185203 (no programmatic show/hide)](https://github.com/feedback-assistant/reports/issues/328), [FB11984872 (no programmatic close)](https://github.com/feedback-assistant/reports/issues/383), [FB10185703 (click-and-hold)](https://github.com/feedback-assistant/reports/issues/332), [FB10185639 (highlight while open)](https://github.com/feedback-assistant/reports/issues/331)
- [MenuBarExtraAccess](https://github.com/orchetect/MenuBarExtraAccess) — third-party library that documents the gaps in `MenuBarExtra`'s public API and the runloop-blocking behavior of `.menu` style
- [Peter Arsenault — macOS Status Bar apps, Part 1](https://www.peterarsenault.industries/posts/macos-status-bar-apps/part01/) — canonical retain-or-vanish pitfall for `NSStatusItem`
- [Multi blog — Pushing the limits of NSStatusItem](https://multi.app/blog/pushing-the-limits-nsstatusitem) — context on advanced NSStatusItem techniques
