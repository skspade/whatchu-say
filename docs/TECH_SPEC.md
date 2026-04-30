# Technical Specification — whatchu-say

| Field | Value |
| --- | --- |
| Version | v2 |
| Status | Pre-implementation, design phase |
| Last updated | 2026-04-29 |
| Companion docs | [PRD.md](./PRD.md), [ROADMAP.md](./ROADMAP.md) |

---

## 1. Tech stack

### Decision: Swift 6 + SwiftUI

| Layer | Choice |
| --- | --- |
| Language | Swift 6 (strict concurrency) |
| Apple UI | SwiftUI (`MenuBarExtra` on Mac, native UIKit/SwiftUI on iOS) |
| Concurrency | Swift structured concurrency (`async`/`await`, actors, AsyncStream) |
| Build | Swift Package Manager + Xcode for app shells |
| Audio | AVAudioEngine (both Apple platforms). RMS computed in pure Swift for VU meter. |
| Networking | `URLSessionWebSocketTask` for STT WebSocket |
| Persistence | Keychain (secrets), UserDefaults via App Group (settings), GRDB → SQLite (history + usage) |
| Linux UI (Phase 3) | Deferred — likely swift-cross-ui (GTK4 backend) or direct Swift→GTK |

### Why Swift end-to-end

1. **iOS is on the roadmap.** Swift is the only practical language for iOS keyboard extensions. Choosing Swift now means the iOS port shares the orchestration layer.
2. **macOS native experience is best in SwiftUI.** `MenuBarExtra`, native settings, no webview tax. Compared to Tauri, we save 80–130 MB of peak memory when settings is open.
3. **Apple platform APIs are first-class.** AVAudioEngine, CGEventTap, AXUIElement — all clean and modern in Swift 6.
4. **Single language across the team of one.** Less context-switching, simpler tooling.

### What we're not using

- **WebRTC VAD or any voice-activity classifier.** Decided against. The VU meter uses pure-Swift RMS; nothing in our control flow depends on speech-vs-non-speech detection. See §5 and §6 of PRD for rationale.
- **Provider-driven audio replay on reconnect.** A mid-utterance drop fails the session. See §15.

### Memory implications

Swift binaries are heavier than Rust binaries (~25 MB Swift runtime baseline vs. ~10 MB for Rust). On macOS this is offset by SwiftUI being a system framework. On iOS the keyboard extension has a ~48 MB hard ceiling — see §11 for breakdown. Under the host-app-recording architecture (decided by the Phase 1.5 spike, see §8.3) the extension is thin and the budget has substantial headroom.

---

## 2. Architecture overview

```
┌─────────────────────┐  ┌─────────────────────┐  ┌─────────────────────┐
│   WhatchuSayMac     │  │   WhatchuSayiOS     │  │   WhatchuSayLinux   │
│   (macOS app)       │  │   host + ext        │  │   (Phase 3)         │
└──────────┬──────────┘  └──────────┬──────────┘  └──────────┬──────────┘
           │                        │                        │
           └────────────┬───────────┴────────────┬───────────┘
                        │                        │
            ┌───────────▼────────────────────────▼───────────┐
            │          Swift Package: Sources/                │
            │                                                 │
            │  ┌──────┐ ┌─────────┐ ┌────────┐ ┌──────────┐  │
            │  │ Core │ │ STTCore │ │ Hotkey │ │  Audio   │  │
            │  └──────┘ └─────────┘ └────────┘ └──────────┘  │
            │                                                 │
            │  ┌──────────┐ ┌────────────┐ ┌──────────────┐  │
            │  │ Injector │ │ Usage      │ │ Orchestrator │  │
            │  └──────────┘ └────────────┘ └──────────────┘  │
            │                                                 │
            │  ┌─────────────────┐ ┌──────────────────┐      │
            │  │ STTElevenLabs   │ │ STTMockProvider  │      │
            │  └─────────────────┘ └──────────────────┘      │
            │                                                 │
            │  ┌────────────────────────┐ ┌───────────────┐  │
            │  │ PlatformApple/Mac      │ │ Apple/iOS     │  │
            │  │ + Overlay UI (Mac)     │ │               │  │
            │  └────────────────────────┘ └───────────────┘  │
            │                                                 │
            │  ┌────────────────────┐                        │
            │  │ PlatformLinux      │ (Phase 3)              │
            │  └────────────────────┘                        │
            └─────────────────────────────────────────────────┘
                                │
                ┌───────────────▼────────────────┐
                │   External STT providers       │
                │   (ElevenLabs WebSocket, etc.) │
                └────────────────────────────────┘
```

**Architectural rules:**

- The shared `Sources/` targets contain **all orchestration logic**. App shells in `Apps/` are thin — they wire UI events to the orchestrator and own platform-specific lifecycle.
- Platform-conditional code is concentrated in `PlatformApple` and (eventually) `PlatformLinux`. Logic targets (`Hotkey`, `Orchestrator`, `Injector`, `Core`, `STTCore`, `Usage`) have **no `#if os(...)` branches**.
- Adding a new STT provider is a new target implementing the same protocols.
- The floating overlay is a Mac-specific UI component (no equivalent on iOS — keyboard extension *is* the UI).

---

## 3. Project structure

```
whatchu-say/
├── Package.swift
├── Sources/
│   ├── Core/                       # Domain types, errors, config schema, settings store
│   │   ├── AppConfig.swift
│   │   ├── ConfigMigration.swift   # Version-aware migration handlers
│   │   ├── Errors.swift
│   │   └── Logging.swift
│   │
│   ├── Audio/                      # Capture pipeline + RMS for VU meter
│   │   ├── AudioCapturing.swift    # protocol
│   │   ├── AVAudioCapture.swift    # AVAudioEngine impl (Mac + iOS)
│   │   ├── Resampler.swift
│   │   ├── RingBuffer.swift
│   │   ├── Chunker.swift
│   │   └── RMSAnalyzer.swift       # Pure Swift, frame-by-frame RMS for VU meter
│   │
│   ├── STTCore/                    # Provider/Session protocols, normalized events
│   │   ├── SttProvider.swift
│   │   ├── SttSession.swift
│   │   ├── SttEvent.swift
│   │   ├── SessionConfig.swift     # Includes endpointDetection mode
│   │   └── SttError.swift
│   │
│   ├── STTElevenLabs/              # ElevenLabs adapter
│   │   ├── ElevenLabsProvider.swift
│   │   ├── ElevenLabsSession.swift
│   │   └── Protocol/
│   │       ├── ClientMessages.swift
│   │       └── ServerMessages.swift
│   │
│   ├── STTMockProvider/            # For tests + provider-abstraction validation
│   │   └── MockProvider.swift
│   │
│   ├── Hotkey/                     # Pure-logic state machine
│   │   ├── ActivationStateMachine.swift
│   │   ├── HotkeyEvent.swift       # keyDown, keyUp, cancel, timerExpired
│   │   └── HotkeyOutput.swift      # startDictation, stop, toggle, cancel
│   │
│   ├── Injector/                   # Cross-platform injection orchestrator
│   │   ├── Injector.swift          # protocol
│   │   ├── StrategySelector.swift  # paste-default; type for short text
│   │   ├── TerminalAllowlist.swift
│   │   └── ClipboardManager.swift  # Save/restore for paste strategy
│   │
│   ├── Usage/                      # Usage tracking & cost surfacing
│   │   ├── UsageTracker.swift
│   │   ├── UsageStore.swift        # SQLite-backed via GRDB
│   │   └── ProviderUsageReporter.swift  # Optional remote usage queries
│   │
│   ├── PlatformApple/
│   │   ├── Mac/
│   │   │   ├── HotkeySourceMac.swift            # CGEventTap
│   │   │   ├── InjectorMac.swift                # CGEvent + NSPasteboard
│   │   │   ├── PermissionsMac.swift             # TCC checks
│   │   │   ├── AutostartMac.swift               # SMAppService
│   │   │   ├── FrontmostAppDetectorMac.swift
│   │   │   ├── SleepWakeObserver.swift          # NSWorkspace notifications
│   │   │   └── Overlay/                         # Floating overlay UI
│   │   │       ├── OverlayWindowController.swift
│   │   │       ├── OverlayPanel.swift           # NSPanel subclass
│   │   │       └── VUMeterView.swift            # SwiftUI view
│   │   │
│   │   └── iOS/
│   │       ├── KeyboardExtensionInjector.swift  # UITextDocumentProxy wrapper
│   │       └── KeyboardActivationSource.swift   # UILongPressGesture wrapper
│   │
│   └── Orchestrator/               # Glues Hotkey → Audio → STT → Injector + Usage + Overlay
│       ├── Orchestrator.swift
│       ├── ReconnectPolicy.swift   # Fail-fast, no replay
│       └── State.swift
│
├── Tests/
│   ├── HotkeyTests/
│   ├── OrchestratorTests/
│   ├── AudioTests/
│   ├── STTElevenLabsTests/
│   └── UsageTests/
│
├── Apps/
│   ├── WhatchuSayMac/
│   │   ├── WhatchuSayMacApp.swift
│   │   ├── Settings/
│   │   ├── Onboarding/
│   │   ├── History/
│   │   ├── Tray/
│   │   └── Resources/
│   │       └── Info.plist
│   │
│   └── WhatchuSayiOS/
│       ├── HostApp/
│       ├── KeyboardExtension/
│       ├── Shared/
│       └── Resources/
│
├── Tooling/
│   ├── notarize.sh
│   ├── package-mac.sh
│   └── replay-fixture.sh
│
└── docs/
    ├── PRD.md
    ├── TECH_SPEC.md
    └── ROADMAP.md
```

---

## 4. Provider abstraction

### 4.1 Protocols

```swift
// Sources/STTCore/SttProvider.swift
public protocol SttProvider: Sendable {
    var name: String { get }
    var capabilities: Capabilities { get }
    func open(config: SessionConfig) async throws -> any SttSession
}

// Sources/STTCore/SttSession.swift
public protocol SttSession: AnyObject, Sendable {
    func pushAudio(_ samples: [Int16]) async throws
    func endOfStream() async throws
    var events: AsyncStream<SttEvent> { get }
    func close() async
}

// Sources/STTCore/SttEvent.swift
public enum SttEvent: Sendable {
    case partial(text: String, stability: Float)
    case final(text: String, alternatives: [String])
    case providerInfo(latencyMs: UInt32, model: String)
    case warning(String)
}

// Sources/STTCore/SessionConfig.swift
public struct SessionConfig: Sendable {
    public let sampleRate: UInt32
    public let language: String?
    public let model: String?
    public let interimResults: Bool
    public let punctuation: Bool
    public let hints: [String]
    public let endpointDetection: EndpointMode   // NEW
}

public enum EndpointMode: Sendable {
    /// Provider auto-finalizes on detected speech end.
    case providerControlled
    /// Final only after explicit endOfStream() from us.
    /// Required for our use case — we control utterance boundaries via hotkey.
    case clientControlled
}

public struct Capabilities: Sendable {
    public let partials: Bool
    public let punctuation: Bool
    public let languages: LanguageSupport
    public let sampleRates: [UInt32]
    public let maxSessionSeconds: UInt32?
    public let supportsClientEndpointing: Bool   // NEW
}

public enum SttError: Error, Sendable {
    case authentication
    case rateLimit(retryAfter: Duration?)
    case transient(String)
    case fatal(String)
    case cancelled
}
```

Note that `SttEvent` no longer includes `speechStarted` / `speechEnded` — we don't act on these signals (per VAD/auto-exit removal). Adapters may surface them via `providerInfo` if useful for debugging, but the orchestrator ignores them.

### 4.2 Why two protocols (Provider + Session)

Providers often have expensive per-process setup (auth handshake, model warm-up). The factory caches what it can; sessions are cheap to open per-utterance.

### 4.3 ElevenLabs adapter

| Concern | Implementation |
| --- | --- |
| Transport | `URLSessionWebSocketTask` |
| Endpoint | `wss://api.elevenlabs.io/...` (exact path from docs at implementation time) |
| Auth | API key in request header |
| Audio format | 16-bit signed PCM, mono, 16 kHz — matches our capture format, no resampling |
| Frame format | Binary frames, 20 ms each (320 samples) |
| Initial config | JSON message with model, language, options. **Sets endpointing to client-controlled.** Confirm during implementation that the API supports this; if not, fall back to `providerControlled` and accept that hands-free needs the per-utterance signal mechanism in §16. |
| Server events | JSON, mapped to `SttEvent` enum |
| Heartbeat | If protocol requires keepalive, handled inside the adapter |

### 4.4 Future adapters (sketches)

- `STTDeepgram` — WebSocket, similar shape, supports keyword boost natively.
- `STTOpenAIRealtime` — WebSocket, audio in Opus encoding (adapter handles encode).
- `STTWhisperLocal` — links `whisper.cpp` via C interop. No streaming partials; emits one Final per utterance after EOS.
- `STTAssemblyAI` — WebSocket with session-token auth flow.

Each is a new SPM target depending only on `STTCore` and the network primitives.

---

## 5. Audio capture pipeline

### 5.1 Pipeline shape

```
[AVAudioEngine input tap]
        ↓
[Format conversion → 16 kHz mono Int16]
        ↓
[Ring buffer (~30s capacity, ~1 MB)]
        ↓
[Chunker → 20 ms frames (320 samples)]
        ↓
        ├──→ [SttSession.pushAudio]
        │
        └──→ [RMSAnalyzer] → AsyncStream<Float> → VU meter
```

### 5.2 Capture protocol

```swift
public protocol AudioCapturing: Sendable {
    func start() async throws
    func stop() async
    var frames: AsyncStream<AudioFrame> { get }
    var rmsLevels: AsyncStream<Float> { get }   // NEW: for VU meter (dBFS)
}

public struct AudioFrame: Sendable {
    public let samples: [Int16]    // 16 kHz mono, 320 samples (20 ms)
    public let timestamp: Duration
}
```

### 5.3 macOS implementation (`AVAudioCapture`)

- `AVAudioEngine` with input node tap.
- Tap format: 16 kHz, mono, Int16. CoreAudio handles conversion from device-native format.
- Tap buffer: 1024 samples (~64 ms at 16 kHz). Re-chunked to 20 ms frames.
- Backpressure: drop oldest frames at the chunker, log a warning. Never block the audio thread.
- Permission requested via `AVAudioApplication.requestRecordPermission` lazily on first activation.

### 5.4 iOS implementation

Same `AVAudioCapture` class with conditional compilation, **running in the host app** (not the keyboard extension — see §8.3 for why):

- `AVAudioSession` configured: category `.record`, mode `.measurement`.
- Permission flow: standard iOS mic permission prompt on first capture (against the host app's bundle ID).
- The keyboard extension does not link or invoke `AVAudioCapture`; it has no `NSMicrophoneUsageDescription`.

### 5.5 RMS for the VU meter

```swift
// Sources/Audio/RMSAnalyzer.swift
public actor RMSAnalyzer {
    public func process(_ samples: [Int16]) -> Float {
        var sum: Double = 0
        for s in samples {
            let normalized = Double(s) / Double(Int16.max)
            sum += normalized * normalized
        }
        let rms = sqrt(sum / Double(samples.count))
        // Convert to dBFS, clamp for display
        let dBFS = 20 * log10(max(rms, 1e-6))
        return Float(max(-60, min(0, dBFS)))
    }
}
```

- Pure Swift. ~10 µs per 20 ms frame on Apple Silicon.
- Output: dBFS in [-60, 0]. Mapped to VU meter levels in `VUMeterView`.
- **Informational only.** No control logic depends on RMS values. Used solely to drive the visual indicator.

---

## 6. Hotkey handling

### 6.1 State machine (pure Swift, no platform deps)

```swift
public enum HotkeyEvent: Sendable {
    case keyDown(at: Date)
    case keyUp(at: Date)
    case cancelKey(at: Date)         // Esc or configured cancel key
    case timerExpired
}

public enum HotkeyOutput: Sendable {
    case startDictation(mode: ActivationMode)
    case stopDictation
    case toggleHandsFree
    case cancelDictation
    case discardSpeculativeBuffer
}

public enum ActivationMode: Sendable {
    case pressHold
    case handsFree
}

public struct HotkeyConfig: Sendable {
    public let pressHoldThreshold: Duration   // default 250 ms
    public let doubleTapWindow: Duration      // default 300 ms
}

public actor ActivationStateMachine {
    public init(config: HotkeyConfig)
    public func handle(_ event: HotkeyEvent) async -> [HotkeyOutput]
    public func reset() async
}
```

States:

- `idle` — no key activity.
- `pressed(downAt: Date)` — key currently held; outcome undecided.
- `tapPending(firstUpAt: Date)` — first tap completed, waiting up to 300 ms for a second key-down.
- `pressHold` — held past 250 ms; dictating until release or cancel.
- `pressHoldCancelled` — user cancelled while still holding; consume KeyUp without finalizing.
- `handsFree` — hands-free mode active; waiting for next key-down or cancel.

Transitions match PRD §6.4.

### 6.2 macOS event source (`HotkeySourceMac`)

- `CGEventTap` at `.cgSessionEventTap` listening for `.keyDown`, `.keyUp`, `.flagsChanged`.
- `.flagsChanged` covers modifier-only hotkeys.
- **Modifier-key disambiguation**: on a `.flagsChanged` event, read `CGEventField.keyboardEventKeycode` to determine the *specific* key (left-Option vs right-Option, etc.). The flags alone don't disambiguate.
- **Key-repeat filtering**: ignore `.keyDown` events where `CGEventField.keyboardEventAutorepeat` is non-zero. macOS sends synthetic key-repeat events while a key is held; the FSM treats only the original keyDown as activation.
- Tap runs on a dedicated `CFRunLoop` thread; events bridge to the actor via `AsyncStream`.
- Timer expiration implemented via `Task.sleep` inside the actor.

### 6.3 Cancel key handling on Mac

A second `CGEventTap` (or a filter on the same tap) monitors for the configured cancel key (default Esc).

- The cancel key event is **consumed only while the FSM is in `pressHold` or `handsFree`** — i.e., we return `nil` from the tap callback to swallow the event, preventing it from reaching the focused app.
- Outside dictation states, cancel-key events pass through normally.
- Implementation detail: the tap callback queries the FSM's current state via a shared atomic before deciding to consume.

### 6.4 iOS event source

Not applicable. The iOS keyboard extension uses `UILongPressGestureRecognizer` on the mic button to drive `keyDown` / `keyUp` events directly. Cancellation in the extension is via gesture liftoff outside the button bounds (touch-up-outside).

---

## 7. Text injection

### 7.1 Strategy selector

```swift
public protocol Injector: Sendable {
    func inject(text: String, hint: InjectionHint) async throws
}

public enum InjectionHint: Sendable {
    case auto         // pick by heuristic — paste-default
    case forceType
    case forcePaste
}
```

### 7.2 Mac strategy logic

**Paste is the default**, not an exception. Type is the optimization for short, simple text where clipboard pollution is undesirable.

```
if user has set per-app override → use override
else if text length ≤ 8 chars AND no special chars (no newlines, no tabs, ASCII-only)
       AND frontmost app is not in a known IME-using locale
   → type via CGEventKeyboardSetUnicodeString
else
   → paste with Cmd+V
```

The 8-character threshold is a starting point — may tune during dogfood. Reasoning: very short text (e.g., "Hi", "ok", "yes please") feels more natural typed; anything longer benefits from paste's reliability.

### 7.3 Type implementation (Mac)

- For each character:
  - `CGEventCreateKeyboardEvent(nil, 0, true)` for key-down.
  - `CGEventKeyboardSetUnicodeString(...)` to attach the character.
  - Post to `.cghidEventTap`.
  - Repeat with `false` for key-up.
- Throttle: ~1 ms between characters.
- Known limitations: IME interactions, secure input fields, and some Electron apps may misbehave. Strategy selector errs on paste for text where these matter.

### 7.4 Paste implementation (Mac)

- Save current `NSPasteboard.general` contents (data + type representation).
- Set new contents: `pasteboard.setString(text, forType: .string)`.
- Synthesize `Cmd+V` via `CGEventCreateKeyboardEvent` (keycode 9, with `.maskCommand` flag).
- After 100 ms (configurable), restore previous pasteboard contents.
- Setting "leave on clipboard" disables restoration.

### 7.5 Frontmost app detection (Mac)

- `NSWorkspace.shared.frontmostApplication.bundleIdentifier`. Captured at **dictation start**, not at inject time, so a Spaces/monitor switch during dictation doesn't change the inject target.
- Cached for the duration of the session.

### 7.6 iOS implementation

- Keyboard extension has direct access to `UITextDocumentProxy`.
- `textDocumentProxy.insertText(text)` — atomic, instant.
- No type-vs-paste distinction needed.
- No per-app override system on iOS.

---

## 8. iOS-specific architecture

### 8.1 Two-target structure

| Target | Purpose |
| --- | --- |
| Host app | Settings, onboarding, API key, history viewer, usage stats — **and the dictation surface itself** (recording + STT + finalize) |
| Keyboard extension | Thin launcher: mic button → URL-scheme open of host; pasteboard read + `insertText` paste-back on return |

### 8.2 Shared state

- **App Group container**: settings, history, usage data.
- **Keychain Sharing access group**: API key.
- **Identical Swift Package targets** ensure no logic divergence.

### 8.3 Phase 1.5 feasibility spike outcome — host-app-recording is primary

Run on iPhone 17 Pro / iOS 26.4 on 2026-04-28. The four gating questions and their answers:

| # | Question | Result |
| --- | --- | --- |
| 1 | Can the extension receive mic permission and capture audio? | ❌ **Blocked at OS level.** `CMSUtilities` denies the audio sandbox extension regardless of `RequestsOpenAccess`, "Allow Full Access," or `NSMicrophoneUsageDescription`. `AVAudioEngine.start()` returns `kAudioUnitErr` 2003329396 (`'what'`); console logs `unable to make sandbox extension: [22: Invalid argument]`. |
| 2 | Can `AVAudioEngine` instantiate and capture in extension context? | ❌ Cannot reach a working state without (1). |
| 3 | Can `URLSessionWebSocketTask` open + stream from extension? | ✅ Reached `committed_transcript` against ElevenLabs realtime endpoint. |
| 4 | Memory under ~48 MB ceiling? | ⚠️ Spike peaked at 67 MB during the *attempted* audio path. Under the redesigned (no-recording) extension this drops substantially; budget revalidates during 2.2. |

**Architectural verdict**: in-extension recording is not achievable on current iOS. This is a hard platform restriction, not a configuration miss; Wispr Flow — the leading dictation keyboard — uses the same workaround ("when you tap Start Flow from the third-party keyboard, it takes you to the full Wispr Flow app, activates the Flow Session, and then hops you back to where you were", per [Zapier's deep dive](https://zapier.com/blog/wispr-flow/)).

The previously contingent **host-app-recording flow is now the primary architecture.**

#### 8.3.1 URL-scheme handoff

```
[whatchu-say keyboard]                [WhatchuSayiOS host app]
       │
       │ user taps mic button
       │
       ├─── open URL ────────────────►
       │   whatchusay://record
       │     ?return={originating app's URL or x-source-app}
       │     ?targetBundleID={cached bundle ID}
       │
       │                              [Recording UI presents]
       │                              [User press-and-holds, dictates]
       │                              [AVAudioEngine + STTElevenLabs as on Mac]
       │                              [Final arrives, written to App Group:
       │                                  pasteboard + history SQLite]
       │                              [Host opens return URL]
       │  ◄──── return ─────────────────
       │
       │ keyboard regains focus
       │ (UIApplication will-enter-foreground in host;
       │  on extension side, the input view's
       │  viewDidAppear / textDidChange equivalents fire)
       │
       │ keyboard reads App Group pasteboard
       │ inserts via UITextDocumentProxy.insertText
       │ marks the pasteboard entry consumed
       │
       └─── done ────►
```

URL scheme: `whatchusay://`. Single endpoint at v1 — `record` — with two query params: `return` (the URL to return to, typically `x-source-app://` or whatever the originating app advertises) and `targetBundleID` (cached so the extension can recover focus correctly even if iOS loses the source-app context).

#### 8.3.2 Where the work actually lives

| Component | Lives in | Notes |
| --- | --- | --- |
| `AVAudioEngine` capture | Host app | Same `Sources/Audio/AVAudioCapture.swift` as Mac, with iOS `AVAudioSession` setup |
| `STTElevenLabs` session | Host app | Identical to Mac — provider abstraction holds |
| `Orchestrator` | Host app | Same actor, same FSM-driven flow |
| `KeyboardActivationSource` (sketched at `Sources/PlatformApple/iOS/`) | Host app | Drives the FSM from a `UILongPressGestureRecognizer` on the host's mic button; same shape as the Mac hotkey source |
| Mic-button-launches-URL | Extension | Tiny — `UIInputViewController` subclass with a SwiftUI mic button that calls `extensionContext?.open(url:completionHandler:)` |
| Pasteboard read + `insertText` | Extension | `KeyboardExtensionInjector` sketch holds, but reads from App Group `UIPasteboard` rather than receiving text in-process |
| App Group container | Both | `group.s900mhz.WhatchuSay` — pasteboard, history, settings, audit |
| Mic permission (`NSMicrophoneUsageDescription`) | Host app **only** | Extension does not record, so does not need this |
| `RequestsOpenAccess` | Extension | Required to open URL schemes and read App Group state |

#### 8.3.3 Pasteboard contract

We can't use `UIPasteboard.general` for the handoff — that would clobber whatever the user already has on their clipboard, violating the "preserve clipboard" convention from the Mac flow. Use a **private named pasteboard** scoped to the App Group:

```swift
let pb = UIPasteboard(name: UIPasteboard.Name("group.s900mhz.WhatchuSay.transcript"), create: true)
pb?.setValue(transcript, forPasteboardType: "public.utf8-plain-text")
```

The keyboard reads from that named pasteboard on regain-focus, inserts via `insertText`, and marks the entry consumed (overwrite with empty + bump a "consumed" sentinel in App Group `UserDefaults`) so a stale transcript can't double-insert. The user's general clipboard is never touched.

#### 8.3.4 Auto-paste vs. explicit confirm

Auto-paste on return is the chosen behavior — it's the natural completion of the user's "tap mic" intent, not a separate automatic event. The full chain is *user-initiated*: tap mic → speak → release → return → paste. The user can suppress the paste with a small "Discard" affordance the keyboard shows briefly on return; if they don't act, the paste happens after a short visible window (~600 ms) so they see the transcript before it lands.

This is consistent with the firm decision against auto-anything (no VAD, no auto-exit, no audio replay) — those are *system-initiated* automation. Paste-on-return is the user's own intent completing.

#### 8.3.5 Memory budget reset

Original budget assumed in-extension audio + WebSocket: ~35 MB target / ~48 MB ceiling. Under host-app-recording the extension does only:

| Component | Estimate |
| --- | --- |
| Swift runtime (per-process) | ~12 MB |
| Minimal SwiftUI keyboard UI | ~5 MB |
| App Group pasteboard read | ~1 MB |
| App heap | ~4 MB |
| **Total** | **~22 MB** |

Comfortably inside the ceiling with ~26 MB headroom. Profile from week one of Milestone 2.2; if anything pushes us over, suspect SwiftUI scene complexity first.

#### 8.3.6 What this does *not* solve

- **Hands-free** still not viable. Same reason as before: the originating app's text field loses focus when the user leaves for the host app, so by the time we'd return continuously there's no insertion target. Excluded from v1 iOS.
- **Background/lock screen recording** — unchanged; we don't try.
- **Direct keyboard-to-network audio streaming** — explicitly out, since recording is.

### 8.4 Hands-free mode on iOS

Not viable in keyboard extensions. Excluded from v1.

---

## 9. Settings & persistence

### 9.1 Storage layout

| Data | Storage | Notes |
| --- | --- | --- |
| API keys | Keychain | iOS uses access group for host ↔ extension sharing |
| App settings | UserDefaults | iOS uses `UserDefaults(suiteName: appGroupID)` |
| Transcription history | SQLite via GRDB | Stored in App Support (Mac) or App Group container (iOS) |
| Usage data | SQLite via GRDB (same DB as history) | Aggregates: per-day, per-month minutes used per provider |
| Local logs | Rotating file in `~/Library/Logs/whatchu-say/` (Mac) | Weekly rotation; no transcript content |

### 9.2 Settings schema (Codable)

```swift
public struct AppConfig: Codable, Sendable {
    public var schemaVersion: UInt32       // for migration; current = 1
    public var provider: ProviderConfig
    public var hotkey: HotkeyBinding
    public var injection: InjectionConfig
    public var startup: StartupConfig
    public var history: HistoryConfig
    public var usage: UsageConfig
    public var overlay: OverlayConfig
    public var privacy: PrivacyConfig
}

public struct ProviderConfig: Codable, Sendable {
    public var providerName: String          // "elevenlabs"
    public var model: String?
    public var language: String?
    public var hints: [String]
}

public struct HotkeyBinding: Codable, Sendable {
    public var keyCode: UInt16
    public var modifiers: ModifierSet
    public var cancelKeyCode: UInt16         // default: 0x35 (Escape)
    public var cancelModifiers: ModifierSet  // default: empty
    public var pressHoldThresholdMs: UInt32  // default 250
    public var doubleTapWindowMs: UInt32     // default 300
}

public struct InjectionConfig: Codable, Sendable {
    public var defaultStrategy: InjectionStrategy   // .auto (paste-default)
    public var typeMaxCharsForAuto: UInt32          // default 8
    public var terminalAllowlist: [String]
    public var perAppOverrides: [String: InjectionStrategy]
    public var leaveOnClipboard: Bool
}

public struct StartupConfig: Codable, Sendable {
    public var launchAtLogin: Bool
    // No auto-exit fields — explicit-only exit per PRD §6.3
}

public struct HistoryConfig: Codable, Sendable {
    public var retentionDays: UInt32              // default 30
    public var maxEntries: UInt32                 // default 1000
    public var enabled: Bool
}

public struct UsageConfig: Codable, Sendable {
    public var menubarIndicator: MenubarIndicator   // .off | .minutes | .cost
    public var monthlyAlertThresholdMinutes: UInt32?  // optional soft alert
}

public struct OverlayConfig: Codable, Sendable {
    public var enabled: Bool                  // default true
    public var anchor: OverlayAnchor          // .nearCursor | .screenBottom
    public var screenAnchorScreen: String?    // displayUUID for screen anchor
}

public struct PrivacyConfig: Codable, Sendable {
    public var hasReadDisclosure: Bool        // user has acknowledged data flow
}
```

### 9.3 History schema (SQLite)

```sql
CREATE TABLE sessions (
    id INTEGER PRIMARY KEY,
    started_at REAL NOT NULL,
    ended_at REAL NOT NULL,
    duration_ms INTEGER NOT NULL,
    activation_mode TEXT NOT NULL,    -- 'press_hold' | 'hands_free'
    provider TEXT NOT NULL,
    model TEXT,
    text TEXT NOT NULL,
    target_app TEXT,
    injection_strategy TEXT NOT NULL,  -- 'type' | 'paste' | 'failed' | 'cancelled'
    cancelled INTEGER DEFAULT 0
);

CREATE INDEX idx_sessions_started_at ON sessions(started_at DESC);

CREATE TABLE usage_daily (
    day TEXT PRIMARY KEY,             -- YYYY-MM-DD
    provider TEXT NOT NULL,
    seconds_used INTEGER NOT NULL,
    estimated_cost_cents INTEGER
);
```

Retention enforcement runs on app launch.

### 9.4 Settings migration

`Sources/Core/ConfigMigration.swift` holds version-aware handlers. On launch:

1. Decode raw JSON and read `schemaVersion`.
2. If less than current, run migration handlers in sequence (`migrateV1ToV2`, etc.) until current.
3. If decoding fails entirely, write defaults and log.
4. Migration must be lossless for user-set values; new fields get defaults.

---

## 10. Security & privacy

| Concern | Approach |
| --- | --- |
| API key storage | Keychain only. Never UserDefaults, never plaintext on disk. |
| API key in memory | Loaded into `String` on demand. No long-lived caching beyond active session. |
| Network | HTTPS / WSS only. Default cert validation. |
| Telemetry | None. No remote crash reporting. |
| Logs | Rotating local file, weekly. **No transcript content** — only metadata. |
| Code signing (Mac) | Developer ID Application certificate. Hardened runtime. |
| Entitlements (Mac) | `com.apple.security.device.audio-input`, Keychain access groups. App is not sandboxed. |
| Entitlements (iOS) | App Group, Keychain Sharing, `RequestsOpenAccess`, `com.apple.security.device.microphone`. |
| Notarization (Mac) | Required. `notarytool` via release script. |

### 10.1 Privacy disclosure

A dedicated settings pane describes the data flow in plain language:

- "Audio is streamed to {provider} over an encrypted WebSocket while you dictate."
- "Transcripts are stored locally in `~/Library/Application Support/whatchu-say/` and never sent anywhere except your configured provider."
- "API keys are stored in macOS Keychain and never leave your machine except when authenticating with your provider."
- "No usage analytics, crash reports, or telemetry are sent to whatchu-say developers."
- Link to provider's data handling policy (URL configurable per provider).

The user must acknowledge this on first run (records in `PrivacyConfig.hasReadDisclosure`).

---

## 11. Memory budget

### 11.1 macOS

| Component | Headless | Settings open | Dictating + overlay |
| --- | --- | --- | --- |
| Swift runtime + Foundation | ~25 MB | ~25 MB | ~25 MB |
| AVAudioEngine + ring buffer | ~5 MB | ~5 MB | ~5 MB |
| URLSessionWebSocketTask + buffers | ~1 MB | ~1 MB | ~8 MB |
| MenuBarExtra + status icon | ~3 MB | ~3 MB | ~3 MB |
| SwiftUI settings window | 0 MB | ~30 MB | 0 MB |
| Floating overlay (NSPanel + VU meter) | 0 MB | 0 MB | ~8 MB |
| App heap + fragmentation | ~10 MB | ~15 MB | ~12 MB |
| **Total** | **~44 MB** | **~79 MB** | **~61 MB** |

Comfortably under the 200 MB ceiling.

### 11.2 iOS keyboard extension (host-app-recording architecture)

The extension is thin — no `AVAudioEngine`, no `URLSessionWebSocketTask` — so the budget shifted from the original ~35 MB target to ~22 MB. Authoritative table lives in §8.3.5; reproduced here for the §11 budget summary:

| Component | Estimate |
| --- | --- |
| Swift runtime (per-process) | ~12 MB |
| Minimal SwiftUI keyboard UI | ~5 MB |
| App Group pasteboard read | ~1 MB |
| App heap | ~4 MB |
| **Total** | **~22 MB** |

Comfortably inside the ~48 MB ceiling with ~26 MB headroom. **Profile from week one** of Milestone 2.3; if anything pushes us over, suspect SwiftUI scene complexity first.

The host app has its own budget (settings + recording + STT) — measured during 2.2; documented after dogfood.

---

## 12. Testing strategy

### 12.1 Unit

| Target | What we test |
| --- | --- |
| `HotkeyTests` | Exhaustive event sequences. Property-style: random sequences should never produce illegal output. Cancel-during-pressHold and cancel-during-handsFree paths exhaustively covered. |
| `AudioTests` | Ring buffer overflow/underflow, chunker boundary alignment, RMS calculation correctness. |
| `STTCoreTests` | Protocol conformance via mock sessions. Endpoint-mode contract (`clientControlled` honored). |
| `UsageTests` | Aggregation across day/month boundaries, edge cases at month rollover. |

### 12.2 Integration

| Target | What we test |
| --- | --- |
| `STTElevenLabsTests` | Replay recorded WAV → assert event sequence matches expected. Verifies endpoint-mode setting is honored by the actual API. |
| `OrchestratorTests` | End-to-end with fake hotkey, fake provider, fake injector. Covers cancellation, reconnect, sleep/wake transitions. |

### 12.3 Manual smoke

`docs/MANUAL_TESTS.md` (authored during Milestone 1.5):

- Press-and-hold across 10+ app categories.
- Pause-mid-dictation while holding (verify no premature finalization).
- Cancel-mid-dictation in press-hold and hands-free.
- Sleep/wake cycle with active session.
- Network kill mid-utterance.
- Memory profile across 8-hour session.

### 12.4 Performance

- Latency instrumentation: log per-utterance elapsed times. Aggregate weekly. Tune by feel; no NFR threshold.
- Memory: nightly Instruments run on Mac CI; fail if RSS exceeds component budgets by >20%.

---

## 13. Build & distribution

### 13.1 Toolchain

- Swift 6 (Xcode 16+).
- `swift build` for cross-platform CI smoke tests.
- `xcodebuild` for app archives and notarization.

### 13.2 Mac distribution

- Universal binary (arm64 + x86_64).
- Notarized `.dmg` via `notarytool`.
- Phase 1: GitHub release.
- Phase 1.5: Sparkle for auto-updates.

### 13.3 iOS distribution

- TestFlight beta first.
- App Store submission with App Review writeup justifying "Allow Full Access."

### 13.4 CI

- GitHub Actions.
- `macos-15` runner for Apple builds.
- `ubuntu-24.04` runner for `swift build` smoke test.
- Nightly: full test suite + memory regression check.

---

## 14. Cross-cutting concerns

### 14.1 Logging

`Sources/Core/Logging.swift` over `os.Logger`. Subsystems: `audio`, `stt`, `hotkey`, `injector`, `orchestrator`, `usage`, `overlay`, `ui`. Production default: `info`. Verbose mode toggleable from settings.

### 14.2 Concurrency

- Swift 6 strict concurrency mode.
- `Sendable` conformance for all public types.
- Actors for stateful long-lived components.
- AsyncStream for event flows.
- Audio thread writes only to lock-free ring buffer; everything else on cooperative pool.

### 14.3 Sleep/wake handling (Mac)

- `SleepWakeObserver` subscribes to `NSWorkspace.willSleepNotification` and `NSWorkspace.didWakeNotification`.
- On sleep: if a session is active, mark it for graceful close; otherwise no-op.
- On wake: clear any cached WebSocket state. The next dictation activation opens a fresh session — so "auto-reconnect" really means "transparently reconnect on next use," not "maintain a permanent connection."
- Audio device may have changed during sleep; re-enumerate on next capture start.

### 14.4 Multi-monitor / Spaces

- Frontmost app and target screen are captured at **dictation start** (KeyDown), not at inject time.
- The floating overlay positions on the screen containing the cursor at activation.
- If the user switches Spaces or monitors during dictation, injection still goes to the originally-focused app — `NSWorkspace.runningApplications` retains the activation reference.

### 14.5 Error surfaces

User-facing errors produce structured `AppError` values:
- Severity (`.info`, `.warning`, `.error`).
- User-facing message (short, actionable).
- Optional fix-it action (deep link to settings or System Settings).
- Internal context for logs.

Toast UI on Mac uses `UserNotifications` framework.

### 14.6 Empty result handling

- If the provider returns `Final` with empty text, log it but produce no toast and no inject.
- The session ends normally; the user can immediately start another.
- Rationale: false-trigger mid-thought shouldn't punish the user with notification noise.

---

## 15. Reconnect policy

**No silent retry. No audio replay across reconnections.** Mid-utterance connection drops are surfaced as failures.

Behavior:

| Scenario | Policy |
| --- | --- |
| Connection failed at session open | Toast: "Couldn't reach {provider}. Check connection or settings." Session aborts. |
| Connection drops mid-utterance | Close session. Toast: "Connection lost — try again." Captured audio is discarded. The state machine returns to idle. |
| Authentication error | Toast: "Provider rejected your API key." Open settings. |
| Rate limit | Toast with retry-after if provided. |
| Sleep/wake | Not a "reconnect" — the next dictation opens a fresh session. |

Why no replay: ElevenLabs (and most realtime STT WebSocket providers) treat each connection as an independent session. Replaying audio after reconnect would either produce duplicate transcripts or require complex deduplication logic. Failing fast is simpler, more predictable, and matches user expectations — they'd rather repeat one sentence than get garbled output.

---

## 16. Cancellation handling

### 16.1 Mac

- Cancel key event source: see §6.3.
- Orchestrator handles `.cancelDictation` from FSM:
  1. Stop audio capture.
  2. Close STT session.
  3. Discard any buffered Final text.
  4. Tell overlay to fade with "cancelled" indicator.
  5. Return to idle state (waiting for KeyUp to clear from `pressHoldCancelled` → `idle`).
- No history entry written. No usage minutes counted (cancelled sessions are free of charge — though network bytes were spent).

### 16.2 Hands-free per-utterance boundary signal

With provider endpointing disabled, hands-free mode wouldn't naturally produce Finals — `Final` only fires after EOS, but EOS happens on hands-free exit, so we'd buffer the entire session and inject it all at once. That's not what users want.

**Resolution candidates** (decision deferred to Milestone 1.4):

- **(a)** Quick double-tap of the hotkey inside hands-free → "flush" — sends EOS, gets Final, opens a new session, continues capturing.
- **(b)** Periodic auto-flush every N seconds (configurable, e.g., 30s).
- **(c)** Voice command — say "send" or similar, parse from partials. Requires `interimResults: true`.
- **(d)** Re-enable provider endpointing in hands-free mode only, accepting that pauses trigger flushes (contradicts user preference; not preferred).

Will dogfood (a) first — it's explicit, matches the "no implicit behavior" preference, and reuses a known gesture.

### 16.3 iOS

- Touch-up-outside on the mic button cancels the current dictation (gesture liftoff outside button bounds).
- Same orchestrator path as Mac cancel.

---

## 17. Floating overlay UI (Mac)

### 17.1 Window

- `NSPanel` subclass with:
  - `.floating` window level.
  - `.nonactivatingPanel` style mask (doesn't steal focus).
  - Transparent background with subtle blur (`NSVisualEffectView`).
  - Rounded corners, ~24×120 px size.
  - Ignores mouse events (passthrough).

### 17.2 Position

- **Default**: anchored near the cursor at dictation start. Position computed via `AXUIElement` to find the focused text element's caret bounds; falls back to mouse pointer position.
- **Alternate**: screen-anchored (e.g., bottom-center of the active screen). Toggle in settings.
- Pinned for the duration of the session — does not follow cursor or focus changes.

### 17.3 Content

- Mic icon (left).
- VU meter visualization (right) — fed by `rmsLevels` AsyncStream from `AudioCapturing`.
- Brief text overlay for state changes:
  - "Listening" (default during capture)
  - "Transcribing" (after EOS, before Final arrives)
  - "Cancelled" (on cancel, fades quickly)
  - Color cue: red border = active, yellow = transcribing, grey-fade = cancelled.

### 17.4 Lifecycle

- Created on dictation start.
- Animated fade-in (~120 ms).
- Pinned during capture and transcription.
- Fade-out on inject complete or cancel (~200 ms).
- Window destroyed after fade-out — not pooled. ~8 MB memory churn per session is acceptable.

---

## 18. Usage tracking

### 18.1 What we track

- Per-session: start/end timestamps, duration, provider, model, success/cancelled.
- Daily aggregates: total seconds per provider.
- Monthly aggregates: total seconds + estimated cost (computed locally from provider rates in config).

### 18.2 Where it surfaces

- **Settings → Usage pane**: line chart of last 30 days, monthly totals, estimated cost.
- **Menubar indicator** (configurable):
  - `.off`: no indicator.
  - `.minutes`: small badge with month-to-date minutes.
  - `.cost`: small badge with month-to-date estimated cost.
- **Optional soft alert**: if month-to-date exceeds a user-set threshold, show a one-time notification.

### 18.3 How costs are estimated

- `ProviderConfig` includes a `costPerMinute` field (user-editable, default from provider's published rates).
- Usage computes locally by `seconds_used / 60 * costPerMinute`.
- We don't query provider APIs for billing — keeps things simple and offline-friendly.
- **Estimate disclosure**: settings clearly states this is an estimate based on user-configured rates, not a live billing query.

---

## 19. Open technical decisions

- **Hands-free per-utterance signal** (§16.2) — decide between (a)/(b)/(c) at Milestone 1.4 based on dogfood.
- **GRDB vs. raw SQLite**: lean toward GRDB unless iOS extension memory is tight.
- **Type vs paste threshold**: 8 chars is a starting point; tune in dogfood.
- **Cancel key default**: Esc. May add platform-specific defaults if conflicts surface.
- **Linux UI toolchain (Phase 3)**: defer until Phase 3 starts.
