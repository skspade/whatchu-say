# Plan — Recent Transcripts (re-paste buffer)

| Field | Value |
| --- | --- |
| Status | Ready for implementation |
| Last updated | 2026-04-28 |
| Related | [PRD.md §3.2 / §8](./PRD.md), [TECH_SPEC.md §9](./TECH_SPEC.md), [ROADMAP.md Milestone 1.5](./ROADMAP.md) |
| Scope | macOS only, interim implementation |

---

## 1. Why now

The full transcription-history feature lives in **Roadmap Milestone 1.5** and is specced as a SQLite/GRDB store with retention rules, history view, copy-to-clipboard, etc. (TECH_SPEC §9.2–9.3).

That's a bigger lift than is needed today. The immediate problem is operational:

> "We often transcribe text, and then somehow the input loses focus, so it'd be nice to have a way to go back to old transcripts so that we can try to re-paste them."

This plan covers a **slim, in-app recent-transcripts buffer** sized for that re-paste workflow: ~20 entries, accessed from the menu-bar dropdown, designed to migrate cleanly into the full Milestone 1.5 store when the time comes.

It does **not** cover: a full history viewer, retention by days, search, transcript editing, or a per-app filter. Those stay in 1.5.

## 2. User story

1. I press-and-hold the hotkey, dictate, release. Text is injected.
2. Sometimes the target text field has lost focus (window switch, modal popped, etc.) — text lands somewhere I don't want, or the paste no-ops, or both.
3. I open the menu-bar icon. I see a list of my recent transcripts (most recent first).
4. I click the one I want. The text is **copied to my clipboard**, replacing whatever was there.
5. I switch to the right text field and paste with `Cmd+V` at my own leisure. No focus race, no surprise injections.

Secondary use: just glance at the last few things I dictated to refresh my memory. Same UI surface.

## 3. Trade-offs and decisions

### 3.1 Slim JSON store now vs. SQLite/GRDB now

| Option | Pros | Cons |
| --- | --- | --- |
| **(A) Slim JSON file in App Support** ✅ | Tiny code surface, no GRDB dep, fast to ship, easy to delete and replace in 1.5 | Throwaway code; a second migration when 1.5 lands |
| (B) Build the 1.5 SQLite store now | One implementation, future-proof | Pulls in GRDB and the full history schema before 1.3 polish ships; out of milestone order |
| (C) UserDefaults | Zero file plumbing | Transcripts can be arbitrarily large; UserDefaults is the wrong tool; mingles app config with content |

**Decision: (A).** The buffer holds at most ~20 strings. JSON-on-disk is ~30 lines of code and matches the "App Support / history" location that TECH_SPEC §9.1 already calls out. Migration to SQLite in 1.5 is a one-shot read-and-import.

### 3.2 Click action: re-inject vs. copy-to-clipboard

| Option | Pros | Cons |
| --- | --- | --- |
| (A) Re-inject only — fire `Cmd+V` after menu close | One-click flow; matches dictation UX | Focus race after menu close; lands in wrong field if previous focus was lost (which is *the very problem we're solving*) |
| (B) Both — primary re-inject, secondary copy | Most flexible | Two affordances to design; brings (A)'s focus-race risk into the primary path |
| **(C) Copy to clipboard only** ✅ | No focus-race risk; user picks where and when to paste with `Cmd+V`; trivial code | One extra keystroke after click |

**Decision: (C).** The original problem is *focus is unreliable when we paste*. (A) and (B) re-introduce that exact failure mode into the recovery path. Copy + manual paste hands control back to the user, who can see their cursor before pasting. The "extra keystroke" cost is real but tiny next to the reliability gain.

This also means the live-dictation injection path stays untouched — it still uses auto-inject + clipboard-restore as today. Recent-transcripts is a parallel surface, not a layer on top.

### 3.3 Does this contradict "no auto-anything"?

The project rule (memory + PRD §11 #8) is explicit: no VAD, no auto-exit, no audio replay. The spirit is *the user must initiate transitions; nothing automatic*.

Recent-transcripts copy is **fully user-initiated** — they open the menu, click, and the result lands on the clipboard. We do not auto-paste. We do not auto-recall. There is no automation introduced by this feature.

### 3.4 Where does the buffer live?

| Option | Notes |
| --- | --- |
| **(A) Mac app target only (`Apps/WhatchuSayMac/.../History/`)** ✅ | Stays out of cross-platform `Sources/` until iOS Phase 2 / Milestone 1.5 needs it |
| (B) New `Sources/History/` SPM target | Premature — iOS keyboard isn't reading it yet, and the slim JSON impl will be deleted in 1.5 |

**Decision: (A).** Mac-app-only. Behind a small protocol so the 1.5 SQLite store is a drop-in.

### 3.5 What gets stored per entry

| Field | In v1 plan | Reason |
| --- | --- | --- |
| `text` | yes | the whole point |
| `timestamp` | yes | sort order + display |
| `id` (UUID) | yes | stable identity for SwiftUI `ForEach` and dedup logic |
| `durationMs`, `provider`, `targetApp`, `injectionStrategy`, `cancelled` | **no** | TECH_SPEC §9.3 has these for the full history view; not needed for re-paste |

When 1.5 lands, the SQLite schema is a superset; migration fills missing fields with defaults.

### 3.6 What does *not* get stored

- **Empty / cancelled finals** — `OrchestratorEvent.sessionEnded(injectedText: nil)`. The orchestrator's contract guarantees `injectedText != nil` implies `!text.isEmpty` (`Orchestrator.swift:135-160`), so we trust it without re-checking.
- **Errors** — `.error` events are not stored.

There is no "menu re-injection" path that could double-record entries (see §3.2).

### 3.7 De-duping

If the user dictates the exact same text twice in a row (e.g., "test", retry, "test"), do we keep both or collapse? **Collapse.** Same text as the most-recent entry → bump the timestamp on the existing entry, do not insert. Different text → insert.

Rationale: the user opens the menu to find a *specific* recent thing. Two identical entries are clutter without information.

## 4. Architecture

```
Orchestrator ──┐
               │ events: AsyncStream<OrchestratorEvent>
               ▼
       AppCoordinator ──► HUDController             (existing)
                       └► RecentTranscriptsStore     (NEW)
                            ├ persisted JSON file
                            └ in-memory ring of TranscriptEntry
                       
       AppDelegate / MenuContentView ──► reads store ──► flat top-N + "Older…" submenu
                                          │
                                          └ click: NSPasteboard.general.setString(entry.text)
```

Components:

- **`TranscriptEntry`** — `{ id: UUID, text: String, timestamp: Date }`. Codable, Sendable, Equatable.
- **`RecentTranscriptsStore`** — `@MainActor @Observable`. Owns the buffer, the JSON file, dedup + capacity logic. Single instance, owned by `AppDelegate` (alongside `AppState`).
- **`AppCoordinator`** — already consumes `OrchestratorEvent`s. Adds a hook on `.sessionEnded(injectedText:)` to call `store.record(text:)` when the text is non-nil. Adds one method: `copyToPasteboard(_ entry:)`.
- **Menu UI** — `MenuContentView` gains a flat list of recent entries plus an "Older…" submenu when needed.

Storage:

- File: `~/Library/Application Support/whatchu-say/recent-transcripts.json`
- Format: `{ "schemaVersion": 1, "entries": [...] }`
- Writes: debounced (~250 ms) to coalesce dedup-then-insert bursts; flushed on app termination via `applicationWillTerminate`.
- Reads: once at launch, in `AppDelegate.bootstrap()` before the menu opens.

## 5. Data model and API

```swift
// Apps/WhatchuSayMac/WhatchuSayMac/History/TranscriptEntry.swift
struct TranscriptEntry: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    let text: String
    let timestamp: Date
}

// Apps/WhatchuSayMac/WhatchuSayMac/History/RecentTranscriptsStore.swift
@MainActor
@Observable
final class RecentTranscriptsStore {
    private(set) var entries: [TranscriptEntry] = []   // newest first

    init(fileURL: URL = .recentTranscriptsDefault, maxCount: Int = RecentTranscriptsConfig.maxCount)
    func load() async                                  // hydrate from disk
    func record(text: String)                          // dedup + insert + truncate + schedule flush
    func clear()
}

// Apps/WhatchuSayMac/WhatchuSayMac/History/RecentTranscriptsConfig.swift
enum RecentTranscriptsConfig {
    /// Default cap on the recent-transcripts buffer. The user-facing value
    /// for now; will graduate to AppConfig.history.maxEntries when the
    /// Milestone 1.5 SQLite store lands.
    static let maxCount: Int = 20

    /// How many entries to render directly in the main menu before the
    /// remainder are pushed under an "Older…" submenu.
    static let topLevelDisplayCount: Int = 5

    /// Optional UserDefaults override hatch: setting `recentTranscripts.maxCount`
    /// to a positive integer overrides the default at next launch. Lets the
    /// 1.3 settings UI bind to a key without coupling the constant.
    static let userDefaultsKey: String = "recentTranscripts.maxCount"

    static func resolvedMaxCount(defaults: UserDefaults = .standard) -> Int {
        let override = defaults.integer(forKey: userDefaultsKey)
        return override > 0 ? override : maxCount
    }
}
```

The store's interface stays small enough that the Milestone 1.5 SQLite-backed replacement can implement the same API with `entries` derived from a SELECT.

## 6. UI / menu surface

The current `MenuContentView` looks like this (truncated):

```
Idle / Listening… / …
─────
[Set | Update API Key…]
─────
Last: hello world          (Text, caption)
─────
Quit
```

After this change:

```
Idle / Listening… / …
─────
[Set | Update API Key…]
─────
Recent transcripts            (Section header)
  hello world                 (click → copy to clipboard)
  remember to buy milk
  …                           (up to topLevelDisplayCount = 5 entries)
  Older…                  ▶   (submenu, only when entries.count > 5)
     ↳ entry 6
     ↳ entry 7
     ↳ … up to maxCount = 20 …
─────
Clear Recent Transcripts      (with confirm alert)
─────
[Error: …]                    (existing, conditional)
─────
Quit
```

Rules:

- We **remove** the existing standalone `Last: …` line; the recent-transcripts section subsumes it.
- Each entry's title is the text truncated to 60 chars with a trailing `…` if longer (first-60 strategy — keeps the opening words visible, which best identifies the transcript). The full text is bound to `.help(fullText)` so hovering reveals it via tooltip.
- Single click on an entry: write `entry.text` to `NSPasteboard.general` as `.string`, replacing prior contents. No clipboard restore (this is an intentional clipboard write, the opposite of the live-paste flow). No notification, no HUD flash — silent, per §3.2.
- "Older…" submenu only renders when `entries.count > topLevelDisplayCount`. The submenu lists entries `[topLevelDisplayCount ..< maxCount]` with the same click behavior.
- "Clear Recent Transcripts" empties the buffer and the on-disk file. Requires a confirm alert because it's destructive and easy to mis-click.
- If the buffer is empty, the section shows a single disabled "No recent transcripts" item rather than vanishing — keeps menu shape stable.

## 7. Configuration surface

For now (this plan):

- `RecentTranscriptsConfig.maxCount = 20` — the headline cap.
- `RecentTranscriptsConfig.topLevelDisplayCount = 5` — how many entries appear directly in the menu before "Older…" picks up the rest.
- `recentTranscripts.maxCount` UserDefaults override hatch for power users / preview of the 1.3 settings UI.
- No menu item to edit either count today. The user said "expose it in a settings menu" — interpreted as eventually-available, not blocking this slice. There is no settings window yet (Milestone 1.3 work).

When the Milestone 1.3 settings window lands:

- Add a Stepper / number field bound to `recentTranscripts.maxCount` UserDefaults.
- Decide whether `topLevelDisplayCount` is also user-configurable; my guess is no — it's a UI-density choice we tune for everyone.
- Optionally remap `RecentTranscriptsConfig.maxCount` to read from `AppConfig.history.maxEntries` once that schema is real (TECH_SPEC §9.2).

When Milestone 1.5 lands:

- The slim JSON file is read once, contents imported into SQLite, file deleted.
- `RecentTranscriptsStore` is re-implemented atop GRDB. Public API unchanged; menu code untouched.

## 8. Edge cases

| Case | Behaviour |
| --- | --- |
| First launch, no file yet | Empty buffer; menu shows "No recent transcripts" disabled item |
| Corrupt JSON on disk | Log the decode error; rewrite with empty entries; do not crash |
| File grows unexpectedly (e.g., user edited it to 10k entries) | On load, truncate to `resolvedMaxCount()`; rewrite |
| User reduces `maxCount` (e.g., from 50 → 20) | At next launch, oldest entries trimmed to fit |
| Same text recorded twice in a row | Bump timestamp on existing entry, do not insert |
| Click during an active dictation session | Allowed — copy still works; HUD continues unaffected. The clipboard write doesn't interfere with the live session. |
| App quits with pending debounced write | `applicationWillTerminate` flushes synchronously |
| Transcript contains sensitive content (e.g., a password user just dictated) | "Clear Recent Transcripts" exists; document in the privacy disclosure pane that recent transcripts persist on disk in App Support |
| `HUDState`-like top-level `lastTranscript` on `AppState` | Removed; the store is now the single source of truth |
| Clipboard contains something the user wanted | Copying clobbers it deliberately; no restore. User chose to copy. |

## 9. Privacy

TECH_SPEC §10 already states transcripts are stored locally in App Support and never leave the machine. This plan extends that store from "implicit (none yet)" to "JSON file with last 20 entries." The privacy disclosure pane (Milestone 1.3) needs one line: *"Whatchu-Say keeps your N most recent transcripts on this Mac so you can re-paste them. Clear them from the menu at any time."*

We do **not**:

- Log transcript contents to file (logging policy in TECH_SPEC §10).
- Send anything off-device.
- Encrypt the JSON. (App Support is user-readable already; full-disk encryption covers it.)

## 10. Testing

Unit tests in `WhatchuSayMacTests/`:

- `RecentTranscriptsStoreTests`
  - `record` inserts at the front
  - `record` of duplicate text bumps timestamp without growing count
  - `record` past `maxCount` evicts oldest
  - `load` decodes a sample JSON and respects truncation
  - `load` on missing file returns empty without throwing
  - `load` on corrupt JSON logs and returns empty
  - `clear` empties memory and disk
- `RecentTranscriptsConfigTests`
  - default returns 20
  - positive UserDefaults override returns the override
  - zero / negative override returns 20

Integration:

- Manual: dictate three things → open menu → top three appear under "Recent transcripts" → click the second one → check `pbpaste` shows that text → paste it into TextEdit successfully.
- Manual: dictate six things → top five appear flat, sixth lands under "Older…" submenu.
- Manual: corrupt the JSON file → reopen app → no crash, "No recent transcripts" shown, fresh dictation populates again.

We do not unit-test the menu views (SwiftUI `MenuBarExtra` is awkward to instantiate in tests); the existing pattern (per `HUDTests`) covers controllers/state, not views.

## 11. Implementation phasing

Three commits, each builds and tests cleanly:

### Commit 1 — store + persistence

- `TranscriptEntry.swift`
- `RecentTranscriptsConfig.swift`
- `RecentTranscriptsStore.swift`
- `RecentTranscriptsStoreTests.swift`, `RecentTranscriptsConfigTests.swift`
- App Support directory creation helper (probably `URL+AppSupport.swift` alongside)

No UI wiring yet; the store stands alone with full unit-test coverage.

### Commit 2 — orchestrator hook + AppCoordinator

- `AppCoordinator` constructs the store, calls `await store.load()` in `start()`.
- The orchestrator-event consumer records on `.sessionEnded(injectedText: text?)` when `text != nil`. Trust the orchestrator's empty-string filter (`Orchestrator.swift:135-160`).
- New method on `AppCoordinator`: `copyToPasteboard(_ entry: TranscriptEntry)`.
- Drop `AppState.lastTranscript` (now redundant) — coordinate the rename in the same commit.

### Commit 3 — menu UI

- Add `RecentTranscriptsMenu` SwiftUI view; embed in `MenuContentView` as a `Section`.
- Remove the old `Last: …` line.
- Wire entry click → `coordinator.copyToPasteboard(entry)`.
- Render flat top-N entries + "Older…" submenu when `entries.count > topLevelDisplayCount`.
- Add "Clear Recent Transcripts" with confirm.
- Manual smoke test in TextEdit; record results in commit message.

## 12. Resolved decisions log

| # | Question | Resolution |
| --- | --- | --- |
| 1 | How to time re-inject after menu close | Eliminated — clipboard-only, user pastes manually with `Cmd+V` |
| 2 | Empty-string guard at the store call site | None — orchestrator's contract (`Orchestrator.swift:135-160`) guarantees `injectedText != nil` ⇒ `!text.isEmpty`; trust it |
| 3 | Per-app safety check on re-inject | Eliminated — no auto re-inject, so no risk of pasting into the wrong app |
| 4 | Copy-gesture rendering inside `MenuBarExtra(.menu)` | Eliminated — every entry click *is* the copy action |
| 5 | Menu layout | Flat: top `topLevelDisplayCount = 5` entries inline, remainder under "Older…" submenu |
| 6 | Truncation direction | First 60 chars + `…` suffix; full text in `.help(...)` tooltip |
| 7 | Visual feedback on copy success | None — silent, per the no-notifications ethos |
