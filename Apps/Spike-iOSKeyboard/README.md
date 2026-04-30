# Spike — iOS keyboard feasibility

Throwaway target. Answers four questions before committing to Phase 2 (PRD §3.3, TECH_SPEC §8.3):

1. **Mic permission** — Can the extension capture audio with `RequestsOpenAccess` granted? Does the host-app grant carry over, or does the extension need to prompt separately?
2. **AVAudioEngine** — Does the input tap actually deliver samples while the extension is presented as the system keyboard?
3. **WebSocket** — Can `URLSessionWebSocketTask` open and stream to `wss://api.elevenlabs.io/v1/speech-to-text/realtime` from extension context?
4. **Memory** — Does RSS stay under ~48 MB during a 30-second dictation? Under ~30 MB idle?

If any answer is "no," Phase 2 redesigns to host-app-recording with URL-scheme handoff.

## Why standalone

Deliberately does **not** import `WhatchuSayKit`. We're measuring the floor of what an extension needs to do dictation — adding our orchestration on top of an unknown floor confounds the measurement.

The spike borrows the protocol shape from `Sources/STTElevenLabs/Protocol/*` (same JSON, same query params) so the WebSocket exchange matches what production will do.

## Layout

The spike sources now live inside the Xcode project's target folders so Xcode 16's synchronized folder references pick them up automatically — no Add Files dance:

```
Apps/Spike-iOSKeyboard/
├── README.md                              # this file
└── Generated/SpikeIOSKeyboard/
    ├── SpikeIOSKeyboard.xcodeproj
    ├── SpikeIOSKeyboard/                  # host app target
    │   ├── HostApp.swift                  # SwiftUI: mic prompt + API-key entry
    │   ├── SpikeStorage.swift             # shared UserDefaults wrapper
    │   └── Assets.xcassets
    └── SpikeKeyboard/                     # keyboard extension target
        ├── KeyboardViewController.swift   # UIInputViewController + SwiftUI mic UI
        ├── SpikeCoordinator.swift         # Wires audio → WebSocket
        ├── SpikeAudioCapture.swift        # Minimal AVAudioEngine wrapper
        ├── SpikeWebSocketClient.swift     # Minimal ElevenLabs realtime client
        ├── MemoryProbe.swift              # mach_task_basic_info → resident MB
        ├── SpikeStorage.swift             # duplicate of host app's copy
        └── Info.plist                     # RequestsOpenAccess + mic usage
```

`Generated/` is throwaway. Delete it after the spike concludes; the production iOS code lands at `Sources/PlatformApple/iOS/`.

## Remaining setup

1. **App Group (optional but recommended)**
   - Both targets → Signing & Capabilities → +Capability → App Groups → check `group.s900mhz.SpikeIOSKeyboard`. Without this, the keyboard extension can't read the API key the host app saved — `SpikeStorage` falls back to `UserDefaults.standard`, which is per-bundle.

2. **Code signing**
   - Open the project in Xcode → SpikeIOSKeyboard target → Signing & Capabilities. Ensure "Automatically manage signing" is on and your Team is selected. Repeat for SpikeKeyboard.
   - On first device build Xcode will prompt to register the bundle IDs with Apple — accept.

3. **Run on a real device** — Simulator's audio path isn't representative of extension behavior, and "Allow Full Access" + mic permission both need device-level testing.

## Running the test

1. Build + install the host app.
2. Open it. Tap "Grant Microphone." Paste your ElevenLabs key. Tap "Save."
3. Settings → General → Keyboards → Add → SpikeKeyboard. Tap into it → toggle **Allow Full Access** → confirm.
4. Open Notes (or any text app). Tap the globe key until SpikeKeyboard is shown.
5. Watch the on-keyboard readouts (top of the view):
   - `RSS x.x MB (peak y.y)` — updates every 0.5 s.
   - `WS: idle | connecting | open | finalizing | failed`.
   - `frames sent: N` — increments while audio is streaming.
6. Press and hold the mic button. Speak. Release.
7. Expected: WebSocket goes `connecting → open` within ~150 ms, frame counter ticks up at ~50/s, on release the final transcript appears in the text field and `WS: finalizing` resolves.

## What to record

Open the spike's worksheet (paper or a note) and capture:

| Measurement | Method | Threshold |
| --- | --- | --- |
| RSS idle, 3 s after first keyboard present | Read top-line RSS | ≤ 30 MB target |
| RSS peak during 30 s hold | Watch peak readout | ≤ 45 MB ceiling |
| RSS post-finalize | Wait 5 s after release | ≤ 32 MB |
| Mic permission prompt behavior | Note in the worksheet | Either "host app grant carried over" or "extension prompted separately" — both acceptable |
| WebSocket open time | Eyeball | < 500 ms |
| Frame counter rate | Visual | ~50/s while holding |
| Final transcript correctness | Compare to spoken words | Should match what you said |
| Behavior across keyboard hide/show | Switch keyboards mid-session | Should clean-tear-down without crash |
| Behavior on extension memory pressure | Hold for 60+ s | RSS should plateau, not creep |

## Decision tree

| Outcome | Action |
| --- | --- |
| All four pass, RSS comfortably under 45 MB | Phase 2 proceeds as designed. Promote spike learnings to production iOS files (`Sources/PlatformApple/iOS/`). |
| Mic blocked from extension | Redesign: keyboard tap-mic launches host app via custom URL scheme; host records and writes transcript to shared clipboard. Worse UX, still functional. |
| WebSocket blocked from extension | Same redesign as above. |
| RSS pegs at 50+ MB | Profile: identify whether it's our code, AVAudioEngine, or URLSession framework load. If unrecoverable, same redesign. |
| RSS creeps over time | Likely a leak in our test code; fix and re-measure. Not a Phase 2 blocker on its own. |

## After the spike

Delete the Xcode project. Keep this directory + the source files for the next round of validation if anything changes (new iOS version, new ElevenLabs SDK, etc.). The production iOS code lives at `Sources/PlatformApple/iOS/` — sketches there now reflect what we expect to land if the spike passes.
