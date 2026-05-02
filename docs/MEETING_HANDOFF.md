# Meeting transcription — Xcode integration handoff

This document covers the remaining work to ship Phase 4 meeting transcription. All cross-platform Swift is done and tested (211 tests passing on `feat/meeting-transcription`). The Mac-app file scaffolding is committed but not yet wired into the Xcode project. You need to do the IDE-level steps below because the project rule (per CLAUDE.md memory) is **build the Mac app in Xcode IDE only — never `xcodebuild`** to preserve TCC permission grants.

## Branch state

```
feat/meeting-transcription  ← work lives here, push when ready
└─ 22 commits ahead of main
```

Run `git log --oneline main..HEAD` for the full list.

## Step-by-step Xcode integration

### 1. Add the `Meeting` SwiftPM target as a dependency of the Mac app

1. Open `Apps/WhatchuSayMac/WhatchuSayMac.xcodeproj` in Xcode.
2. Select the `WhatchuSayMac` target.
3. **General → Frameworks, Libraries, and Embedded Content** → click **+**.
4. Pick **Meeting** from the workspace's local SwiftPM packages.
5. Set "Embed" to **Do Not Embed** (it's a static library — same setting as the other workspace deps).

### 2. Add the new Mac-app files to the project

The files live on disk under `Apps/WhatchuSayMac/WhatchuSayMac/Meeting/` and `Apps/WhatchuSayMac/WhatchuSayMac/Settings/MeetingsPane.swift`. Xcode does not auto-pick them up.

1. In Xcode's Project Navigator, right-click the `WhatchuSayMac` group → **Add Files to "WhatchuSayMac"…**
2. Select the `Apps/WhatchuSayMac/WhatchuSayMac/Meeting/` directory.
3. Check **Create groups** (not folder references), check **Add to targets: WhatchuSayMac**, click **Add**.
4. Same for `Apps/WhatchuSayMac/WhatchuSayMac/Settings/MeetingsPane.swift`.

### 3. Wire `MeetingsCoordinator` into `AppCoordinator`

Open `Apps/WhatchuSayMac/WhatchuSayMac/AppCoordinator.swift` and add construction of the meetings coordinator next to where the dictation orchestrator is built. The coordinator needs the ElevenLabs API key (already managed by `APIKeyController` for dictation) and the `ConfigStore`. Approximate shape:

```swift
// somewhere AppCoordinator already has access to apiKey and configStore
let meetingsCoordinator: MeetingsCoordinator?
do {
    meetingsCoordinator = try MeetingsCoordinator(apiKey: apiKey, configStore: configStore)
} catch {
    // fall back to nil — meeting feature unavailable, dictation still works
    meetingsCoordinator = nil
    appState.lastError = "Meeting transcription unavailable: \(error)"
}
```

Pass `meetingsCoordinator` to `StatusItemController` so the menu can call into it.

### 4. Add Start/Stop meeting menu items to `StatusItemController`

Open `Apps/WhatchuSayMac/WhatchuSayMac/StatusItemController.swift`. Wherever the menu is built, add a section for meetings above (or below) the existing dictation entries:

```swift
// Inject meetingsCoordinator via init or property; if nil, skip the section.
if let mc = meetingsCoordinator {
    if mc.isRecording {
        let stop = NSMenuItem(
            title: "Stop recording (\(formatElapsed(mc.elapsedSeconds)))",
            action: #selector(MeetingsCoordinator.stopMeetingMenuAction(_:)),
            keyEquivalent: ""
        )
        stop.target = mc
        menu.addItem(stop)
    } else {
        let start = NSMenuItem(
            title: "Start meeting recording…",
            action: #selector(MeetingsCoordinator.startMeetingMenuAction(_:)),
            keyEquivalent: ""
        )
        start.target = mc
        menu.addItem(start)
    }
    menu.addItem(.separator())
}
```

`formatElapsed` is a one-liner: `String(format: "%02d:%02d", seconds / 60, seconds % 60)`.

The menu rebuilds on each open (existing project pattern), so the Start/Stop swap happens for free.

### 5. Build & install

1. ⌘B in Xcode. Expected: clean build.
2. From the repo root: `make install`.
3. Launch `/Applications/WhatchuSayMac.app`.

### 6. Smoke test — golden path

1. Click the menu bar icon → "Start meeting recording…".
2. Modal appears with consent reminder + attendees field.
3. Type `Alice, Bob` → click **Start**.
4. macOS prompts for **Screen & System Audio Recording** the first time. Grant it. Quit and relaunch the app (TCC requires this).
5. Repeat steps 1–3. Recording starts. Menu bar now shows `Stop recording (00:01)` ticking up.
6. Open YouTube, play a 30-second clip with people talking. Speak briefly into your mic.
7. Click menu bar → **Stop recording**. App says "Transcribing…" briefly.
8. Transcript window opens with merged segments labeled `Me` and `Speaker N` (or attendee names if mappable).
9. Try the **Delete audio** button → "Audio: deleted" appears.
10. Try the **trash** button → window closes, transcript directory deleted.
11. Open Settings → **Meetings** tab. Toggle "Delete recorded audio after transcription" off. Run another short meeting → after stop, audio file should still exist on disk.

### 7. Smoke test — regressions

1. Run a normal dictation push-to-talk → text injects at cursor as before. The whole point of the sibling-subsystem architecture is that dictation is unaffected.
2. Quit the app mid-recording (force-quit). Relaunch. Recovery prompt appears: "Recover unfinished meeting?" Try each of the three buttons across separate runs.

### 8. (Optional) Run the Process Tap manual smoke test

In `Tests/MeetingTests/SystemAudioCaptureSmokeTests.swift`, the suite is annotated `.disabled("manual: ...")`. To exercise it:

1. Remove the `.disabled(...)` argument or change to a `.enabled` predicate.
2. Grant Screen & System Audio Recording to the test runner (it'll prompt on first run).
3. Play audio.
4. `swift test --filter SystemAudioCapture`.

This validates spike open question §10.1 (Process Tap on macOS 15+ behaves as expected).

## What's deferred — read before scope-creeping

These were called out in the plan as "out of scope for v1" with rationale; do not pull them in unless real user demand surfaces.

- **Periodic audio flush via segmented writers (Task 28a).** Current behavior: a crash during recording can lose up to whatever `AVAudioFile` hasn't flushed. The library-side recovery (`findIncomplete()` + `recover(id:)`) handles half-written meetings gracefully — they just get a shorter transcript. Implementing segmented writes is meaningful complexity; revisit if real-world crashes prove costly.
- **LLM-backed `SpeakerNameMapper`.** v1 ships `ContentBasedSpeakerNameMapper` which catches the trivial "I'm Alice" case. Adding LLM-backed mapping requires introducing a chat-completion provider abstraction (not currently in `STTCore`) — defer until the spike's §10.4 measurement shows accuracy is poor in practice.
- **Past-meetings library window.** No UI for browsing prior transcripts. Users navigate via "Reveal in Finder" on the Meetings settings pane → double-click `transcript.md`.
- **Detection-based trigger, calendar OAuth, live captions, voiceprint enrollment.** All deferred per spec §13.

## When you're ready to merge

```bash
swift test                                  # confirm all 211 still pass
# do the Xcode integration above + smoke tests
git push -u origin feat/meeting-transcription
gh pr create --title "Meeting transcription (Phase 4)" \
  --body "Implements docs/superpowers/specs/2026-05-02-meeting-transcription-design.md"
```

Or invoke `/ultrareview` for a multi-agent review of the branch first.
