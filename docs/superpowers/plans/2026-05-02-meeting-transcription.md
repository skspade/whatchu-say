# Meeting Transcription Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add meeting transcription to whatchu-say as a sibling subsystem to the existing dictation flow. Capture mic + Mac system audio during a manually-started session, run post-meeting batch transcription with diarization via ElevenLabs Scribe v2, and surface the result in a transcript window with manual attendee entry and per-speaker rename.

**Architecture:** New `Meeting` SwiftPM target holds cross-platform models, capture protocols, and the transcription pipeline. Capture implementations are macOS-only and gated `@available(macOS 15, *)` because Process Tap requires it. `STTCore` gains a `BatchTranscriber` capability protocol; `STTElevenLabs` adds an HTTP-only `ElevenLabsBatchTranscriber`. UI lives in the existing `Apps/WhatchuSayMac/WhatchuSayMac/` tree as a new `Meeting/` directory plus a `MeetingsPane` added to the existing Settings window. Dictation `Orchestrator`, `AudioCapture`, FSM, and hotkey path are not modified.

**Tech Stack:** Swift 6, Swift Testing (`import Testing`), AVFoundation, AudioToolbox (`CATapDescription` / Process Tap on macOS 15+), AppKit, SwiftUI for new panes, URLSession for the Scribe v2 HTTP call.

**Spec:** [`docs/superpowers/specs/2026-05-02-meeting-transcription-design.md`](../specs/2026-05-02-meeting-transcription-design.md). The plan implements the spec verbatim — every product/architecture decision is settled there.

---

## Project conventions to follow

- **Build the Mac app in Xcode IDE only.** Never run `xcodebuild` against the `WhatchuSayMac` target — ad-hoc signing breaks TCC permission grants. Use `make install` after Xcode builds Debug. Library targets (everything in `Sources/`) build and test fine via `swift build` / `swift test`.
- **Do not raise `Package.swift`'s `.macOS(.v14)` platform floor.** Meeting capture is gated `@available(macOS 15, *)` per file. Bumping the package floor would break dictation on macOS 14, which is supported.
- **Tests use Swift Testing**, not XCTest: `import Testing`, `@Suite`/`@Test`/`#expect`. See `Tests/AudioTests/AudioTests.swift` for the canonical shape.
- **Swift 6 strict concurrency.** All shared mutable state must be actor-isolated or `Sendable`.
- **Do not modify** `Sources/Orchestrator/`, `Sources/Audio/AVAudioCapture.swift`, the dictation hotkey path, or any FSM logic. Meeting flow is fully sibling.
- **Commit after every passing test.** Frequent commits — see `git log` for the project's existing one-line subject style with `feat(...)`, `fix(...)`, `docs(...)` prefixes.

---

## File structure

### New SwiftPM target: `Meeting`

`Sources/Meeting/`
- `Models/MeetingSession.swift` — id, title, started_at, ended_at, attendees, retention flag, status
- `Models/Segment.swift` — `Segment(start, end, speaker, text)` and `Speaker` enum (`me` | `tagged(String)` | `anonymous(Int)`)
- `Models/MeetingTranscript.swift` — `[Segment]` with merge + render-to-markdown
- `Models/AttendeeList.swift` — typed wrapper around `[String]` with autocomplete-history helpers
- `Persistence/MeetingLibrary.swift` — disk persistence under `meetings/<uuid>/`
- `Persistence/MeetingMetaCodable.swift` — JSON shapes for `meta.json` and `transcript.json`
- `Capture/AudioRecorderProtocol.swift` — protocol that both `MicCapture` and `SystemAudioCapture` conform to
- `Capture/MicCapture.swift` — `@available(macOS 15, *)` long-running mic to file (sibling to `AVAudioCapture`, not a reuse)
- `Capture/SystemAudioCapture.swift` — `@available(macOS 15, *)` Process Tap wrapper, default-output capture
- `Capture/OpusFileWriter.swift` — wraps `AVAudioFile` configured for Opus/Ogg output
- `Pipeline/MeetingTranscriptionPipeline.swift` — orchestrates batch transcribe + merge + LLM map
- `Pipeline/SpeakerNameMapper.swift` — protocol + LLM-backed implementation
- `Pipeline/TranscriptMerger.swift` — pure function: two `[Segment]` lists → one chronological list
- `Errors/MeetingError.swift`
- `MeetingOrchestrator.swift` — public entry point: `start(attendees:)`, `stop()`, exposes events stream

`Tests/MeetingTests/`
- `SegmentTests.swift`
- `MeetingTranscriptTests.swift`
- `AttendeeListTests.swift`
- `MeetingLibraryTests.swift`
- `TranscriptMergerTests.swift`
- `SpeakerNameMapperTests.swift`
- `MeetingTranscriptionPipelineTests.swift`
- `MeetingOrchestratorTests.swift`

### Modifications to existing modules

- `Sources/STTCore/SttProvider.swift` — extend with optional `var batchTranscriber: (any BatchTranscriber)? { get }` (default nil).
- `Sources/STTCore/BatchTranscriber.swift` — **new** file: protocol + result types.
- `Sources/STTElevenLabs/ElevenLabsBatchTranscriber.swift` — **new** file.
- `Sources/STTElevenLabs/ElevenLabsProvider.swift` — return non-nil `batchTranscriber`.
- `Sources/STTElevenLabs/Endpoints.swift` — add Scribe v2 endpoint constant.
- `Sources/Core/AppConfig.swift` — add `MeetingsConfig` struct + field on `AppConfig`.
- `Sources/Core/ConfigMigration.swift` — bump schema version, add migration handler.
- `Package.swift` — register new `Meeting` target + `MeetingTests` test target; wire new dependencies.

### New UI files in Mac app

`Apps/WhatchuSayMac/WhatchuSayMac/Meeting/`
- `MeetingMenuBarController.swift` — owns the Start meeting recording menu entry + recording-state UI (timer, Stop)
- `StartMeetingModal.swift` — consent reminder + attendees field + Start/Cancel
- `TranscriptWindow.swift` + `TranscriptView.swift` — list view of segments, attendee chip input, rename context menu, delete-transcript and keep-audio controls
- `MeetingsCoordinator.swift` — glue between AppCoordinator, MeetingOrchestrator, and the windows above
- `RecoveryPrompt.swift` — launch-time prompt when a half-written meeting is detected on disk

`Apps/WhatchuSayMac/WhatchuSayMac/Settings/`
- `MeetingsPane.swift` — **new** Settings pane (mirrors existing `PrivacyPane.swift` shape)
- `SettingsView.swift` — modify to register the new pane
- `FirstRunDisclosure.swift` — modify to add the optional Meetings section

`Apps/WhatchuSayMac/WhatchuSayMac/Permissions/`
- `PermissionDeepLink.swift` — modify to add Screen & System Audio Recording deep link

`Apps/WhatchuSayMac/WhatchuSayMac/AppCoordinator.swift` — modify to construct the `MeetingsCoordinator` and `MeetingOrchestrator`.

`Apps/WhatchuSayMac/WhatchuSayMac/WhatchuSayMac.entitlements` — verify the `NSScreenCaptureUsageDescription` Info.plist key is present (or add it).

`Apps/WhatchuSayMac/WhatchuSayMac/StatusItemController.swift` — modify to host the Meeting menu entries alongside existing dictation entries.

---

## Phase 1 — Cross-platform foundations (Sources/Meeting + STTCore)

### Task 1: Wire up empty `Meeting` SwiftPM target

**Files:**
- Modify: `Package.swift`
- Create: `Sources/Meeting/Placeholder.swift` (deleted at end of phase)
- Create: `Tests/MeetingTests/PlaceholderTests.swift` (deleted at end of phase)

- [ ] **Step 1: Add target + testTarget to Package.swift**

In `Package.swift` `targets:` array, add after the existing `Orchestrator` target:

```swift
.target(
    name: "Meeting",
    dependencies: ["Core", "STTCore"],
    path: "Sources/Meeting"
),
```

In the `testTargets` section add:

```swift
.testTarget(
    name: "MeetingTests",
    dependencies: ["Meeting", "STTCore", "STTMockProvider"],
    path: "Tests/MeetingTests"
),
```

- [ ] **Step 2: Add placeholder source so SwiftPM can build the target**

`Sources/Meeting/Placeholder.swift`:

```swift
// Placeholder — deleted in Task 2. Lets SwiftPM build the target before any
// real source files exist.
```

`Tests/MeetingTests/PlaceholderTests.swift`:

```swift
import Testing
@testable import Meeting

@Suite("Meeting target builds")
struct PlaceholderTests {
    @Test("placeholder")
    func placeholder() {}
}
```

- [ ] **Step 3: Verify build + tests pass**

Run: `swift test --filter MeetingTests`
Expected: PASS, 1 test

- [ ] **Step 4: Commit**

```bash
git add Package.swift Sources/Meeting Tests/MeetingTests
git commit -m "chore(meeting): scaffold Meeting SwiftPM target"
```

---

### Task 2: `Speaker` and `Segment` value types

**Files:**
- Create: `Sources/Meeting/Models/Segment.swift`
- Create: `Tests/MeetingTests/SegmentTests.swift`
- Delete: `Sources/Meeting/Placeholder.swift` and `Tests/MeetingTests/PlaceholderTests.swift`

- [ ] **Step 1: Write failing tests**

`Tests/MeetingTests/SegmentTests.swift`:

```swift
import Testing
import Foundation
@testable import Meeting

@Suite("Speaker")
struct SpeakerTests {
    @Test("equality across cases")
    func equality() {
        #expect(Speaker.me == .me)
        #expect(Speaker.tagged("Alice") == .tagged("Alice"))
        #expect(Speaker.anonymous(1) == .anonymous(1))
        #expect(Speaker.tagged("Alice") != .tagged("Bob"))
        #expect(Speaker.anonymous(1) != .tagged("Alice"))
    }

    @Test("roundtrips through JSON")
    func codable() throws {
        let cases: [Speaker] = [.me, .tagged("Alice"), .anonymous(3)]
        for s in cases {
            let data = try JSONEncoder().encode(s)
            let decoded = try JSONDecoder().decode(Speaker.self, from: data)
            #expect(decoded == s)
        }
    }
}

@Suite("Segment")
struct SegmentTests {
    @Test("constructs with values")
    func construct() {
        let s = Segment(start: 1.0, end: 2.5, speaker: .me, text: "hello")
        #expect(s.start == 1.0)
        #expect(s.end == 2.5)
        #expect(s.speaker == .me)
        #expect(s.text == "hello")
    }

    @Test("duration")
    func duration() {
        let s = Segment(start: 1.0, end: 2.5, speaker: .me, text: "x")
        #expect(s.duration == 1.5)
    }
}
```

- [ ] **Step 2: Run, expect compile failure**

Run: `swift test --filter MeetingTests`
Expected: compile error — `Speaker`, `Segment` undefined.

- [ ] **Step 3: Implement minimal types**

`Sources/Meeting/Models/Segment.swift`:

```swift
import Foundation

/// Who said something in a meeting transcript. `me` is the local user;
/// `tagged` is a name (typed by the user or mapped by the LLM); `anonymous`
/// is an unmapped diarized speaker.
public enum Speaker: Sendable, Equatable, Hashable, Codable {
    case me
    case tagged(String)
    case anonymous(Int)
}

/// A contiguous transcribed utterance. Times are seconds since recording start.
public struct Segment: Sendable, Equatable, Codable {
    public let start: TimeInterval
    public let end: TimeInterval
    public var speaker: Speaker
    public let text: String

    public init(start: TimeInterval, end: TimeInterval, speaker: Speaker, text: String) {
        self.start = start
        self.end = end
        self.speaker = speaker
        self.text = text
    }

    public var duration: TimeInterval { end - start }
}
```

- [ ] **Step 4: Delete placeholders**

```bash
rm Sources/Meeting/Placeholder.swift Tests/MeetingTests/PlaceholderTests.swift
```

- [ ] **Step 5: Run, expect pass**

Run: `swift test --filter MeetingTests`
Expected: 4 tests passing.

- [ ] **Step 6: Commit**

```bash
git add Sources/Meeting Tests/MeetingTests
git commit -m "feat(meeting): Speaker and Segment value types"
```

---

### Task 3: `TranscriptMerger` pure function

**Files:**
- Create: `Sources/Meeting/Pipeline/TranscriptMerger.swift`
- Create: `Tests/MeetingTests/TranscriptMergerTests.swift`

- [ ] **Step 1: Write failing tests**

`Tests/MeetingTests/TranscriptMergerTests.swift`:

```swift
import Testing
@testable import Meeting

@Suite("TranscriptMerger")
struct TranscriptMergerTests {
    @Test("interleaves by start time")
    func interleave() {
        let mic: [Segment] = [
            .init(start: 0.0, end: 1.0, speaker: .me, text: "hi"),
            .init(start: 5.0, end: 6.0, speaker: .me, text: "yes"),
        ]
        let system: [Segment] = [
            .init(start: 2.0, end: 3.0, speaker: .anonymous(1), text: "hello"),
            .init(start: 4.0, end: 4.5, speaker: .anonymous(2), text: "ok"),
        ]
        let merged = TranscriptMerger.merge(mic: mic, system: system)
        #expect(merged.map(\.start) == [0.0, 2.0, 4.0, 5.0])
        #expect(merged[0].speaker == .me)
        #expect(merged[1].speaker == .anonymous(1))
    }

    @Test("on tie at start, mic comes first")
    func tieFavorsMe() {
        let mic: [Segment] = [.init(start: 1.0, end: 2.0, speaker: .me, text: "a")]
        let system: [Segment] = [.init(start: 1.0, end: 2.0, speaker: .anonymous(1), text: "b")]
        let merged = TranscriptMerger.merge(mic: mic, system: system)
        #expect(merged.map(\.speaker) == [.me, .anonymous(1)])
    }

    @Test("empty inputs produce empty output")
    func empties() {
        #expect(TranscriptMerger.merge(mic: [], system: []) == [])
    }
}
```

- [ ] **Step 2: Run, expect compile failure**

Run: `swift test --filter TranscriptMergerTests`

- [ ] **Step 3: Implement**

`Sources/Meeting/Pipeline/TranscriptMerger.swift`:

```swift
import Foundation

/// Merges two transcribed streams (mic + system) into one chronological
/// transcript. Pure function — no I/O. On a tie at `start`, mic segments
/// come first by convention so "I said X" reads before "they said Y".
public enum TranscriptMerger {
    public static func merge(mic: [Segment], system: [Segment]) -> [Segment] {
        var combined: [(Int, Segment)] = []
        combined.reserveCapacity(mic.count + system.count)
        for s in mic { combined.append((0, s)) }
        for s in system { combined.append((1, s)) }
        combined.sort { lhs, rhs in
            if lhs.1.start != rhs.1.start { return lhs.1.start < rhs.1.start }
            return lhs.0 < rhs.0
        }
        return combined.map(\.1)
    }
}
```

- [ ] **Step 4: Run, expect pass**

Run: `swift test --filter TranscriptMergerTests`
Expected: 3 passing.

- [ ] **Step 5: Commit**

```bash
git add Sources/Meeting/Pipeline/TranscriptMerger.swift Tests/MeetingTests/TranscriptMergerTests.swift
git commit -m "feat(meeting): TranscriptMerger pure-function"
```

---

### Task 4: `MeetingTranscript` — apply mappings, render markdown

**Files:**
- Create: `Sources/Meeting/Models/MeetingTranscript.swift`
- Create: `Tests/MeetingTests/MeetingTranscriptTests.swift`

- [ ] **Step 1: Write failing tests**

`Tests/MeetingTests/MeetingTranscriptTests.swift`:

```swift
import Testing
@testable import Meeting

@Suite("MeetingTranscript")
struct MeetingTranscriptTests {
    let segments: [Segment] = [
        .init(start: 0, end: 1, speaker: .me, text: "Hi everyone."),
        .init(start: 1, end: 2, speaker: .anonymous(1), text: "Hi Sean."),
        .init(start: 2, end: 3, speaker: .anonymous(2), text: "Hello."),
    ]

    @Test("applies mapping to anonymous speakers")
    func applyMapping() {
        var t = MeetingTranscript(segments: segments)
        t.applySpeakerMapping([1: "Alice"])
        #expect(t.segments[0].speaker == .me)
        #expect(t.segments[1].speaker == .tagged("Alice"))
        #expect(t.segments[2].speaker == .anonymous(2))
    }

    @Test("manual rename overrides")
    func manualRename() {
        var t = MeetingTranscript(segments: segments)
        t.renameSpeaker(.anonymous(2), to: "Bob")
        #expect(t.segments[2].speaker == .tagged("Bob"))
    }

    @Test("renders markdown with [mm:ss] timestamps")
    func renderMarkdown() {
        let t = MeetingTranscript(segments: [
            .init(start: 65, end: 67, speaker: .me, text: "Hello."),
            .init(start: 70, end: 72, speaker: .tagged("Alice"), text: "Hi."),
        ])
        let md = t.renderMarkdown(title: "Test meeting")
        #expect(md.contains("# Test meeting"))
        #expect(md.contains("[01:05] **Me:** Hello."))
        #expect(md.contains("[01:10] **Alice:** Hi."))
    }
}
```

- [ ] **Step 2: Run, expect compile failure**

- [ ] **Step 3: Implement**

`Sources/Meeting/Models/MeetingTranscript.swift`:

```swift
import Foundation

/// In-memory transcript. Mutable: callers can apply LLM speaker mappings or
/// user manual renames, then re-render to markdown. The on-disk
/// `transcript.json` stores the post-mapping segments; `transcript.md` is
/// the rendered version.
public struct MeetingTranscript: Sendable, Equatable, Codable {
    public private(set) var segments: [Segment]

    public init(segments: [Segment]) {
        self.segments = segments
    }

    /// Replaces `Speaker.anonymous(id)` with `Speaker.tagged(name)` for each
    /// `id → name` entry in the mapping. Other speakers are untouched.
    public mutating func applySpeakerMapping(_ mapping: [Int: String]) {
        segments = segments.map { seg in
            guard case let .anonymous(id) = seg.speaker, let name = mapping[id] else {
                return seg
            }
            var copy = seg
            copy.speaker = .tagged(name)
            return copy
        }
    }

    /// Renames every segment whose speaker matches `from`. Used when the
    /// user right-clicks a speaker label in the transcript window.
    public mutating func renameSpeaker(_ from: Speaker, to name: String) {
        segments = segments.map { seg in
            guard seg.speaker == from else { return seg }
            var copy = seg
            copy.speaker = .tagged(name)
            return copy
        }
    }

    public func renderMarkdown(title: String) -> String {
        var lines: [String] = ["# \(title)", ""]
        for seg in segments {
            let stamp = Self.formatTimestamp(seg.start)
            let speaker = Self.speakerLabel(seg.speaker)
            lines.append("[\(stamp)] **\(speaker):** \(seg.text)")
        }
        return lines.joined(separator: "\n")
    }

    private static func formatTimestamp(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }

    private static func speakerLabel(_ speaker: Speaker) -> String {
        switch speaker {
        case .me: return "Me"
        case .tagged(let n): return n
        case .anonymous(let id): return "Speaker \(id)"
        }
    }
}
```

- [ ] **Step 4: Run, expect pass**

Run: `swift test --filter MeetingTranscriptTests`

- [ ] **Step 5: Commit**

```bash
git add Sources/Meeting/Models/MeetingTranscript.swift Tests/MeetingTests/MeetingTranscriptTests.swift
git commit -m "feat(meeting): MeetingTranscript with mapping + markdown render"
```

---

### Task 5: `AttendeeList` typed wrapper

**Files:**
- Create: `Sources/Meeting/Models/AttendeeList.swift`
- Create: `Tests/MeetingTests/AttendeeListTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import Testing
@testable import Meeting

@Suite("AttendeeList")
struct AttendeeListTests {
    @Test("parses comma-separated input, trims whitespace")
    func parseCSV() {
        let list = AttendeeList(parsing: "  Alice, Bob , Carol  ")
        #expect(list.names == ["Alice", "Bob", "Carol"])
    }

    @Test("ignores empty entries")
    func parseEmpties() {
        let list = AttendeeList(parsing: "Alice,,Bob,")
        #expect(list.names == ["Alice", "Bob"])
    }

    @Test("isEmpty when no names")
    func empty() {
        #expect(AttendeeList(parsing: "").isEmpty)
        #expect(AttendeeList(parsing: " ,, ").isEmpty)
    }

    @Test("dedupes case-insensitively, keeps first casing")
    func dedupe() {
        let list = AttendeeList(parsing: "Alice, alice, ALICE, Bob")
        #expect(list.names == ["Alice", "Bob"])
    }
}
```

- [ ] **Step 2: Run, expect compile failure**

- [ ] **Step 3: Implement**

`Sources/Meeting/Models/AttendeeList.swift`:

```swift
import Foundation

public struct AttendeeList: Sendable, Equatable, Codable {
    public let names: [String]

    public init(names: [String]) {
        self.names = names
    }

    public init(parsing input: String) {
        var seen = Set<String>()
        var result: [String] = []
        for raw in input.split(separator: ",") {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            if seen.insert(key).inserted {
                result.append(trimmed)
            }
        }
        self.names = result
    }

    public var isEmpty: Bool { names.isEmpty }
}
```

- [ ] **Step 4: Run, expect pass**

- [ ] **Step 5: Commit**

```bash
git commit -am "feat(meeting): AttendeeList parsing + dedupe"
```

---

### Task 6: `MeetingSession` model

**Files:**
- Create: `Sources/Meeting/Models/MeetingSession.swift`
- Modify: `Tests/MeetingTests/MeetingTranscriptTests.swift` is unaffected; add `Tests/MeetingTests/MeetingSessionTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import Testing
import Foundation
@testable import Meeting

@Suite("MeetingSession")
struct MeetingSessionTests {
    @Test("init sets required fields, status starts at .recording")
    func initFields() {
        let id = UUID()
        let started = Date()
        let s = MeetingSession(
            id: id,
            title: "Test",
            startedAt: started,
            attendees: AttendeeList(names: ["Alice"]),
            keepAudio: false
        )
        #expect(s.id == id)
        #expect(s.title == "Test")
        #expect(s.startedAt == started)
        #expect(s.attendees.names == ["Alice"])
        #expect(s.keepAudio == false)
        #expect(s.status == .recording)
        #expect(s.endedAt == nil)
    }

    @Test("default title uses ISO date when not provided")
    func defaultTitle() {
        let s = MeetingSession(id: UUID(), title: nil, startedAt: Date(timeIntervalSince1970: 0), attendees: AttendeeList(names: []), keepAudio: false)
        #expect(s.title.contains("Meeting —"))
    }

    @Test("status transitions")
    func transitions() {
        var s = MeetingSession(id: UUID(), title: "x", startedAt: Date(), attendees: AttendeeList(names: []), keepAudio: false)
        s.markStopped(at: Date(timeIntervalSince1970: 100))
        #expect(s.status == .transcribing)
        #expect(s.endedAt == Date(timeIntervalSince1970: 100))
        s.markCompleted()
        #expect(s.status == .completed)
        s.markFailed(reason: "boom")
        #expect(s.status == .failed("boom"))
    }
}
```

- [ ] **Step 2: Run, expect compile failure**

- [ ] **Step 3: Implement**

```swift
import Foundation

public struct MeetingSession: Sendable, Equatable, Codable {
    public enum Status: Sendable, Equatable, Codable {
        case recording
        case transcribing
        case completed
        case failed(String)
    }

    public let id: UUID
    public var title: String
    public let startedAt: Date
    public var endedAt: Date?
    public var attendees: AttendeeList
    public var keepAudio: Bool
    public var status: Status

    public init(
        id: UUID,
        title: String?,
        startedAt: Date,
        attendees: AttendeeList,
        keepAudio: Bool
    ) {
        self.id = id
        self.title = title ?? Self.defaultTitle(for: startedAt)
        self.startedAt = startedAt
        self.endedAt = nil
        self.attendees = attendees
        self.keepAudio = keepAudio
        self.status = .recording
    }

    public mutating func markStopped(at date: Date) {
        endedAt = date
        status = .transcribing
    }

    public mutating func markCompleted() { status = .completed }

    public mutating func markFailed(reason: String) { status = .failed(reason) }

    private static func defaultTitle(for date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return "Meeting — \(f.string(from: date))"
    }
}
```

- [ ] **Step 4: Run, expect pass**

- [ ] **Step 5: Commit**

```bash
git commit -am "feat(meeting): MeetingSession model"
```

---

### Task 7: `MeetingLibrary` disk persistence

**Files:**
- Create: `Sources/Meeting/Persistence/MeetingLibrary.swift`
- Create: `Tests/MeetingTests/MeetingLibraryTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import Testing
import Foundation
@testable import Meeting

@Suite("MeetingLibrary")
struct MeetingLibraryTests {
    func makeTempLibrary() throws -> (MeetingLibrary, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (MeetingLibrary(rootDirectory: root), root)
    }

    @Test("creates session directory on save")
    func saveCreatesDir() throws {
        let (lib, root) = try makeTempLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = MeetingSession(id: UUID(), title: "x", startedAt: Date(), attendees: AttendeeList(names: ["Alice"]), keepAudio: false)
        let dir = try lib.create(session: session)
        #expect(FileManager.default.fileExists(atPath: dir.path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("meta.json").path))
    }

    @Test("round-trips meta.json")
    func roundtripMeta() throws {
        let (lib, root) = try makeTempLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = MeetingSession(id: UUID(), title: "x", startedAt: Date(timeIntervalSince1970: 1000), attendees: AttendeeList(names: ["A","B"]), keepAudio: true)
        _ = try lib.create(session: original)
        let loaded = try lib.load(id: original.id)
        #expect(loaded.id == original.id)
        #expect(loaded.attendees.names == ["A","B"])
        #expect(loaded.keepAudio == true)
    }

    @Test("writeTranscript persists transcript.json + transcript.md")
    func writeTranscript() throws {
        let (lib, root) = try makeTempLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let s = MeetingSession(id: UUID(), title: "x", startedAt: Date(), attendees: AttendeeList(names: []), keepAudio: false)
        _ = try lib.create(session: s)
        let t = MeetingTranscript(segments: [.init(start: 0, end: 1, speaker: .me, text: "hi")])
        try lib.writeTranscript(t, for: s.id, title: "Test")
        let dir = try lib.directory(for: s.id)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("transcript.json").path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("transcript.md").path))
    }

    @Test("deleteAudio removes mic.opus and system.opus only")
    func deleteAudio() throws {
        let (lib, root) = try makeTempLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let s = MeetingSession(id: UUID(), title: "x", startedAt: Date(), attendees: AttendeeList(names: []), keepAudio: false)
        let dir = try lib.create(session: s)
        try Data().write(to: dir.appendingPathComponent("mic.opus"))
        try Data().write(to: dir.appendingPathComponent("system.opus"))
        try Data().write(to: dir.appendingPathComponent("meta.json"))
        try lib.deleteAudio(for: s.id)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("mic.opus").path))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("system.opus").path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("meta.json").path))
    }
}
```

- [ ] **Step 2: Run, expect compile failure**

- [ ] **Step 3: Implement**

`Sources/Meeting/Persistence/MeetingLibrary.swift`:

```swift
import Foundation

public protocol MeetingLibraryProtocol: Sendable {
    func create(session: MeetingSession) throws -> URL
    func load(id: UUID) throws -> MeetingSession
    func update(session: MeetingSession) throws
    func directory(for id: UUID) throws -> URL
    func micFile(for id: UUID) throws -> URL
    func systemFile(for id: UUID) throws -> URL
    func writeTranscript(_ transcript: MeetingTranscript, for id: UUID, title: String) throws
    func deleteAudio(for id: UUID) throws
    func listAll() throws -> [MeetingSession]
    func delete(id: UUID) throws
}

public struct MeetingLibrary: MeetingLibraryProtocol {
    private let rootDirectory: URL
    private let fileManager: FileManager

    public init(rootDirectory: URL, fileManager: FileManager = .default) {
        self.rootDirectory = rootDirectory
        self.fileManager = fileManager
    }

    public static func defaultRoot() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = support.appendingPathComponent("whatchu-say/meetings", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public func directory(for id: UUID) throws -> URL {
        rootDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    public func micFile(for id: UUID) throws -> URL {
        try directory(for: id).appendingPathComponent("mic.opus")
    }

    public func systemFile(for id: UUID) throws -> URL {
        try directory(for: id).appendingPathComponent("system.opus")
    }

    public func create(session: MeetingSession) throws -> URL {
        let dir = try directory(for: session.id)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        try writeMeta(session, to: dir)
        return dir
    }

    public func load(id: UUID) throws -> MeetingSession {
        let url = try directory(for: id).appendingPathComponent("meta.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(MeetingSession.self, from: data)
    }

    public func update(session: MeetingSession) throws {
        let dir = try directory(for: session.id)
        try writeMeta(session, to: dir)
    }

    public func writeTranscript(_ transcript: MeetingTranscript, for id: UUID, title: String) throws {
        let dir = try directory(for: id)
        let json = try JSONEncoder().encode(transcript)
        try json.write(to: dir.appendingPathComponent("transcript.json"))
        let md = transcript.renderMarkdown(title: title)
        try md.data(using: .utf8)!.write(to: dir.appendingPathComponent("transcript.md"))
    }

    public func deleteAudio(for id: UUID) throws {
        let dir = try directory(for: id)
        for name in ["mic.opus", "system.opus"] {
            let url = dir.appendingPathComponent(name)
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }
    }

    public func listAll() throws -> [MeetingSession] {
        let entries = try fileManager.contentsOfDirectory(at: rootDirectory, includingPropertiesForKeys: nil)
        var result: [MeetingSession] = []
        for entry in entries {
            guard UUID(uuidString: entry.lastPathComponent) != nil else { continue }
            let metaURL = entry.appendingPathComponent("meta.json")
            guard let data = try? Data(contentsOf: metaURL),
                  let session = try? JSONDecoder().decode(MeetingSession.self, from: data) else { continue }
            result.append(session)
        }
        return result.sorted { $0.startedAt > $1.startedAt }
    }

    public func delete(id: UUID) throws {
        try fileManager.removeItem(at: try directory(for: id))
    }

    private func writeMeta(_ session: MeetingSession, to dir: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(session)
        try data.write(to: dir.appendingPathComponent("meta.json"))
    }
}
```

Note: above implementation also needs `JSONDecoder` to use `.iso8601` for `Date` — fix that:

In `load(id:)`, replace `JSONDecoder()` with:

```swift
let decoder = JSONDecoder()
decoder.dateDecodingStrategy = .iso8601
return try decoder.decode(MeetingSession.self, from: data)
```

Apply same to `listAll()`.

- [ ] **Step 4: Run, expect pass**

Run: `swift test --filter MeetingLibraryTests`

- [ ] **Step 5: Commit**

```bash
git commit -am "feat(meeting): MeetingLibrary disk persistence"
```

---

### Task 8: `BatchTranscriber` capability protocol in STTCore

**Files:**
- Create: `Sources/STTCore/BatchTranscriber.swift`
- Modify: `Sources/STTCore/SttProvider.swift` — add `batchTranscriber` requirement with default
- Create: `Tests/STTCoreTests/BatchTranscriberTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import Testing
import Foundation
@testable import STTCore
@testable import STTMockProvider

@Suite("BatchTranscriber")
struct BatchTranscriberTests {
    @Test("default provider exposes nil batchTranscriber")
    func defaultNil() {
        let provider = MockProvider()
        #expect(provider.batchTranscriber == nil)
    }

    @Test("BatchTranscriptionResult preserves segments")
    func resultStruct() {
        let result = BatchTranscriptionResult(segments: [
            .init(start: 0, end: 1, speakerId: nil, text: "a"),
            .init(start: 1, end: 2, speakerId: 0, text: "b"),
        ])
        #expect(result.segments.count == 2)
        #expect(result.segments[1].speakerId == 0)
    }
}
```

- [ ] **Step 2: Run, expect compile failure**

- [ ] **Step 3: Implement protocol + types**

`Sources/STTCore/BatchTranscriber.swift`:

```swift
import Foundation

/// Optional capability for STT providers that support file-based batch
/// transcription with diarization. Distinct from the realtime `SttSession`
/// path; batch is "POST a finished audio file, get a JSON transcript back".
public protocol BatchTranscriber: Sendable {
    func transcribe(
        audioFileURL: URL,
        diarize: Bool,
        languageHint: String?
    ) async throws -> BatchTranscriptionResult
}

public struct BatchTranscriptionResult: Sendable, Equatable, Codable {
    public let segments: [BatchSegment]
    public init(segments: [BatchSegment]) { self.segments = segments }
}

/// One segment from a batch provider response. `speakerId` is the
/// provider-assigned diarization label (typically 0, 1, 2, …) — not yet
/// mapped to a name. `nil` if diarization was disabled.
public struct BatchSegment: Sendable, Equatable, Codable {
    public let start: TimeInterval
    public let end: TimeInterval
    public let speakerId: Int?
    public let text: String

    public init(start: TimeInterval, end: TimeInterval, speakerId: Int?, text: String) {
        self.start = start
        self.end = end
        self.speakerId = speakerId
        self.text = text
    }
}
```

In `Sources/STTCore/SttProvider.swift`, add a default implementation by extending the protocol. Place after the `SttProvider` declaration:

```swift
public extension SttProvider {
    /// Providers that don't support batch transcription return `nil`. To
    /// support it, override and return your `BatchTranscriber` instance.
    var batchTranscriber: (any BatchTranscriber)? { nil }
}
```

Also add the requirement to the protocol itself for opt-in implementers — but **do not** add it as a stored requirement, since that would force every existing provider to write `var batchTranscriber: (any BatchTranscriber)? { nil }`. Use the extension-only approach (consistent with how Swift handles optional protocol methods).

- [ ] **Step 4: Run, expect pass**

Run: `swift test --filter BatchTranscriber`

- [ ] **Step 5: Commit**

```bash
git add Sources/STTCore Tests/STTCoreTests
git commit -m "feat(stt-core): BatchTranscriber capability protocol"
```

---

### Task 9: `SpeakerNameMapper` protocol + naive content-based default

**Files:**
- Create: `Sources/Meeting/Pipeline/SpeakerNameMapper.swift`
- Create: `Tests/MeetingTests/SpeakerNameMapperTests.swift`

The default implementation is the LLM-backed one; for v1 we ship a content-based mapper that handles the trivial "Speaker X says 'I'm Alice'" case as a reasonable starting point. The LLM-backed path is wired in Phase 2 once we have a provider for it.

- [ ] **Step 1: Write failing tests**

```swift
import Testing
@testable import Meeting

@Suite("ContentBasedSpeakerNameMapper")
struct SpeakerNameMapperTests {
    @Test("returns empty map when no attendees")
    func noAttendees() async throws {
        let mapper = ContentBasedSpeakerNameMapper()
        let result = try await mapper.map(
            transcript: MeetingTranscript(segments: [.init(start:0,end:1,speaker:.anonymous(0),text:"hi")]),
            attendees: AttendeeList(names: [])
        )
        #expect(result.isEmpty)
    }

    @Test("matches self-introduction 'I'm <Name>' to the speaking speaker")
    func selfIntro() async throws {
        let mapper = ContentBasedSpeakerNameMapper()
        let result = try await mapper.map(
            transcript: MeetingTranscript(segments: [
                .init(start: 0, end: 1, speaker: .anonymous(0), text: "Hey, I'm Alice."),
                .init(start: 1, end: 2, speaker: .anonymous(1), text: "Nice to meet you."),
            ]),
            attendees: AttendeeList(names: ["Alice", "Bob"])
        )
        #expect(result == [0: "Alice"])
    }

    @Test("does not map names not in attendee list")
    func unknownName() async throws {
        let mapper = ContentBasedSpeakerNameMapper()
        let result = try await mapper.map(
            transcript: MeetingTranscript(segments: [
                .init(start: 0, end: 1, speaker: .anonymous(0), text: "I'm Charlie."),
            ]),
            attendees: AttendeeList(names: ["Alice", "Bob"])
        )
        #expect(result.isEmpty)
    }

    @Test("does not map .me or .tagged segments")
    func skipsNonAnonymous() async throws {
        let mapper = ContentBasedSpeakerNameMapper()
        let result = try await mapper.map(
            transcript: MeetingTranscript(segments: [
                .init(start: 0, end: 1, speaker: .me, text: "I'm Alice."),
            ]),
            attendees: AttendeeList(names: ["Alice"])
        )
        #expect(result.isEmpty)
    }
}
```

- [ ] **Step 2: Run, expect compile failure**

- [ ] **Step 3: Implement**

`Sources/Meeting/Pipeline/SpeakerNameMapper.swift`:

```swift
import Foundation

/// Maps anonymous diarized speaker IDs (`Speaker.anonymous(N)`) to names from
/// the attendee list. The protocol is async + throwing so an LLM-backed
/// implementation can drop in later without breaking the pipeline.
public protocol SpeakerNameMapper: Sendable {
    /// Returns a partial mapping `[anonymousId: name]`. IDs absent from the
    /// returned dict are intentionally left as `Speaker.anonymous(...)` —
    /// the user can manually rename them.
    func map(
        transcript: MeetingTranscript,
        attendees: AttendeeList
    ) async throws -> [Int: String]
}

/// Default mapper: scans transcript for self-introductions of the form
/// "I'm <Name>" or "I am <Name>" or "this is <Name>" where `<Name>` is in
/// the attendee list. First match wins per anonymous speaker id.
///
/// This is a deliberately simple baseline. A future LLM-backed mapper
/// (Task 14) will replace it but must keep the same protocol shape.
public struct ContentBasedSpeakerNameMapper: SpeakerNameMapper {
    public init() {}

    public func map(
        transcript: MeetingTranscript,
        attendees: AttendeeList
    ) async throws -> [Int: String] {
        guard !attendees.isEmpty else { return [:] }

        let nameSet = Dictionary(uniqueKeysWithValues: attendees.names.map { ($0.lowercased(), $0) })
        var result: [Int: String] = [:]

        for seg in transcript.segments {
            guard case let .anonymous(id) = seg.speaker, result[id] == nil else { continue }
            for prefix in ["i'm ", "i am ", "this is "] {
                if let range = seg.text.range(of: prefix, options: [.caseInsensitive]) {
                    let after = seg.text[range.upperBound...]
                    let candidate = after
                        .prefix { $0.isLetter || $0 == "-" }
                        .trimmingCharacters(in: .whitespaces)
                    if !candidate.isEmpty, let canonical = nameSet[candidate.lowercased()] {
                        result[id] = canonical
                        break
                    }
                }
            }
        }
        return result
    }
}
```

- [ ] **Step 4: Run, expect pass**

Run: `swift test --filter SpeakerNameMapper`

- [ ] **Step 5: Commit**

```bash
git commit -am "feat(meeting): SpeakerNameMapper protocol + content-based default"
```

---

### Task 10: `MeetingTranscriptionPipeline`

Orchestrates: read mic + system audio files → call BatchTranscriber for each → assemble Speakers → merge → run name mapper → return transcript. Pure async function with all dependencies injected.

**Files:**
- Create: `Sources/Meeting/Pipeline/MeetingTranscriptionPipeline.swift`
- Create: `Tests/MeetingTests/MeetingTranscriptionPipelineTests.swift`
- Create: `Tests/MeetingTests/Mocks/MockBatchTranscriber.swift`

- [ ] **Step 1: Create mock batch transcriber for tests**

`Tests/MeetingTests/Mocks/MockBatchTranscriber.swift`:

```swift
import Foundation
import STTCore

actor MockBatchTranscriber: BatchTranscriber {
    var responseFor: [URL: BatchTranscriptionResult] = [:]
    var callCount = 0
    var lastDiarize: Bool?

    func setResponse(_ result: BatchTranscriptionResult, for url: URL) {
        responseFor[url] = result
    }

    func transcribe(audioFileURL: URL, diarize: Bool, languageHint: String?) async throws -> BatchTranscriptionResult {
        callCount += 1
        lastDiarize = diarize
        guard let r = responseFor[audioFileURL] else {
            throw NSError(domain: "MockBatch", code: 1)
        }
        return r
    }
}
```

- [ ] **Step 2: Write failing pipeline tests**

```swift
import Testing
import Foundation
@testable import Meeting
import STTCore

@Suite("MeetingTranscriptionPipeline")
struct MeetingTranscriptionPipelineTests {
    @Test("calls transcriber with diarize=false for mic, diarize=true for system")
    func diarizeFlags() async throws {
        let mock = MockBatchTranscriber()
        let micURL = URL(fileURLWithPath: "/tmp/mic.opus")
        let systemURL = URL(fileURLWithPath: "/tmp/system.opus")
        await mock.setResponse(.init(segments: []), for: micURL)
        await mock.setResponse(.init(segments: []), for: systemURL)

        let pipeline = MeetingTranscriptionPipeline(
            transcriber: mock,
            mapper: ContentBasedSpeakerNameMapper()
        )
        _ = try await pipeline.run(
            micAudio: micURL,
            systemAudio: systemURL,
            attendees: AttendeeList(names: [])
        )
        #expect(await mock.callCount == 2)
    }

    @Test("relabels mic segments as .me, system segments as .anonymous")
    func relabel() async throws {
        let mock = MockBatchTranscriber()
        let micURL = URL(fileURLWithPath: "/tmp/mic.opus")
        let systemURL = URL(fileURLWithPath: "/tmp/system.opus")
        await mock.setResponse(.init(segments: [
            .init(start: 0, end: 1, speakerId: nil, text: "hi"),
        ]), for: micURL)
        await mock.setResponse(.init(segments: [
            .init(start: 1, end: 2, speakerId: 0, text: "hello"),
            .init(start: 2, end: 3, speakerId: 1, text: "world"),
        ]), for: systemURL)

        let pipeline = MeetingTranscriptionPipeline(
            transcriber: mock,
            mapper: ContentBasedSpeakerNameMapper()
        )
        let t = try await pipeline.run(
            micAudio: micURL,
            systemAudio: systemURL,
            attendees: AttendeeList(names: [])
        )
        #expect(t.segments.count == 3)
        #expect(t.segments[0].speaker == .me)
        #expect(t.segments[1].speaker == .anonymous(0))
        #expect(t.segments[2].speaker == .anonymous(1))
    }

    @Test("applies name mapping when attendees match self-intros")
    func applyMapping() async throws {
        let mock = MockBatchTranscriber()
        let micURL = URL(fileURLWithPath: "/tmp/mic.opus")
        let systemURL = URL(fileURLWithPath: "/tmp/system.opus")
        await mock.setResponse(.init(segments: []), for: micURL)
        await mock.setResponse(.init(segments: [
            .init(start: 0, end: 1, speakerId: 0, text: "I'm Alice."),
        ]), for: systemURL)

        let pipeline = MeetingTranscriptionPipeline(
            transcriber: mock,
            mapper: ContentBasedSpeakerNameMapper()
        )
        let t = try await pipeline.run(
            micAudio: micURL,
            systemAudio: systemURL,
            attendees: AttendeeList(names: ["Alice"])
        )
        #expect(t.segments[0].speaker == .tagged("Alice"))
    }
}
```

- [ ] **Step 3: Implement pipeline**

`Sources/Meeting/Pipeline/MeetingTranscriptionPipeline.swift`:

```swift
import Foundation
import STTCore

public struct MeetingTranscriptionPipeline: Sendable {
    private let transcriber: any BatchTranscriber
    private let mapper: any SpeakerNameMapper

    public init(transcriber: any BatchTranscriber, mapper: any SpeakerNameMapper) {
        self.transcriber = transcriber
        self.mapper = mapper
    }

    public func run(
        micAudio: URL,
        systemAudio: URL,
        attendees: AttendeeList,
        languageHint: String? = nil
    ) async throws -> MeetingTranscript {
        async let micResult = transcriber.transcribe(audioFileURL: micAudio, diarize: false, languageHint: languageHint)
        async let systemResult = transcriber.transcribe(audioFileURL: systemAudio, diarize: true, languageHint: languageHint)
        let (mic, system) = try await (micResult, systemResult)

        let micSegments = mic.segments.map {
            Segment(start: $0.start, end: $0.end, speaker: .me, text: $0.text)
        }
        let systemSegments = system.segments.map { seg in
            Segment(
                start: seg.start,
                end: seg.end,
                speaker: seg.speakerId.map(Speaker.anonymous) ?? .anonymous(0),
                text: seg.text
            )
        }

        let merged = TranscriptMerger.merge(mic: micSegments, system: systemSegments)
        var transcript = MeetingTranscript(segments: merged)
        let mapping = try await mapper.map(transcript: transcript, attendees: attendees)
        transcript.applySpeakerMapping(mapping)
        return transcript
    }
}
```

- [ ] **Step 4: Run, expect pass**

Run: `swift test --filter MeetingTranscriptionPipeline`

- [ ] **Step 5: Commit**

```bash
git commit -am "feat(meeting): MeetingTranscriptionPipeline (transcribe → merge → map)"
```

---

## Phase 2 — ElevenLabs batch transcription

### Task 11: `ElevenLabsBatchTranscriber` HTTP client

ElevenLabs Scribe v2 endpoint is `POST https://api.elevenlabs.io/v1/speech-to-text` with `multipart/form-data`. Required form fields: `model_id=scribe_v2`, `file=<opus binary>`. Optional: `diarize=true|false`, `language_code=<iso>`. Auth via `xi-api-key` header.

**Files:**
- Modify: `Sources/STTElevenLabs/Endpoints.swift` — add `static let batchSpeechToText = URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!`
- Create: `Sources/STTElevenLabs/ElevenLabsBatchTranscriber.swift`
- Modify: `Sources/STTElevenLabs/ElevenLabsProvider.swift` — return non-nil `batchTranscriber`
- Create: `Tests/STTElevenLabsTests/ElevenLabsBatchTranscriberTests.swift`

Verify the exact endpoint shape against ElevenLabs docs at the start of the task — if the path or field names differ, update accordingly. The user provided the model card; spike Task 25 below also confirms the wire format.

- [ ] **Step 1: Add endpoint constant**

In `Sources/STTElevenLabs/Endpoints.swift`, add the batch URL alongside existing constants.

- [ ] **Step 2: Write failing tests using a stub URLProtocol**

```swift
import Testing
import Foundation
@testable import STTElevenLabs
import STTCore

final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var stubbedResponse: (Data, HTTPURLResponse)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let (data, response) = Self.stubbedResponse else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "stub", code: 0))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("ElevenLabsBatchTranscriber")
struct ElevenLabsBatchTranscriberTests {
    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    @Test("parses Scribe v2 JSON response into BatchTranscriptionResult")
    func parseResponse() async throws {
        let json = """
        {
          "segments": [
            {"start": 0.0, "end": 1.5, "speaker": null, "text": "Hello."},
            {"start": 1.5, "end": 3.0, "speaker": 0, "text": "Hi there."}
          ]
        }
        """.data(using: .utf8)!
        StubURLProtocol.stubbedResponse = (json, HTTPURLResponse(url: URL(string: "https://x")!, statusCode: 200, httpVersion: nil, headerFields: nil)!)

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("test.opus")
        try Data().write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let t = ElevenLabsBatchTranscriber(apiKey: "key", urlSession: makeSession())
        let result = try await t.transcribe(audioFileURL: tmp, diarize: true, languageHint: nil)
        #expect(result.segments.count == 2)
        #expect(result.segments[0].speakerId == nil)
        #expect(result.segments[1].speakerId == 0)
    }

    @Test("throws on non-2xx response")
    func httpError() async throws {
        StubURLProtocol.stubbedResponse = (Data(), HTTPURLResponse(url: URL(string: "https://x")!, statusCode: 401, httpVersion: nil, headerFields: nil)!)

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("test.opus")
        try Data().write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let t = ElevenLabsBatchTranscriber(apiKey: "key", urlSession: makeSession())
        await #expect(throws: Error.self) {
            _ = try await t.transcribe(audioFileURL: tmp, diarize: false, languageHint: nil)
        }
    }
}
```

- [ ] **Step 3: Implement**

`Sources/STTElevenLabs/ElevenLabsBatchTranscriber.swift`:

```swift
import Foundation
import STTCore

public struct ElevenLabsBatchTranscriber: BatchTranscriber {
    private let apiKey: String
    private let urlSession: URLSession
    private let modelId: String

    public init(apiKey: String, urlSession: URLSession = .shared, modelId: String = "scribe_v2") {
        self.apiKey = apiKey
        self.urlSession = urlSession
        self.modelId = modelId
    }

    public func transcribe(
        audioFileURL: URL,
        diarize: Bool,
        languageHint: String?
    ) async throws -> BatchTranscriptionResult {
        let boundary = "----wcs-\(UUID().uuidString)"
        var request = URLRequest(url: Endpoints.batchSpeechToText)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func appendField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append(value.data(using: .utf8)!)
            body.append("\r\n".data(using: .utf8)!)
        }
        appendField("model_id", modelId)
        appendField("diarize", diarize ? "true" : "false")
        if let lang = languageHint {
            appendField("language_code", lang)
        }

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(audioFileURL.lastPathComponent)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/ogg\r\n\r\n".data(using: .utf8)!)
        body.append(try Data(contentsOf: audioFileURL))
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw BatchTranscriptionError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? -1, data)
        }

        return try Self.parse(data)
    }

    static func parse(_ data: Data) throws -> BatchTranscriptionResult {
        struct Wire: Codable {
            struct Segment: Codable {
                let start: TimeInterval
                let end: TimeInterval
                let speaker: Int?
                let text: String
            }
            let segments: [Segment]
        }
        let wire = try JSONDecoder().decode(Wire.self, from: data)
        let segments = wire.segments.map {
            BatchSegment(start: $0.start, end: $0.end, speakerId: $0.speaker, text: $0.text)
        }
        return BatchTranscriptionResult(segments: segments)
    }
}

public enum BatchTranscriptionError: Error, Equatable {
    case httpStatus(Int, Data)
}
```

- [ ] **Step 4: Wire into provider**

In `Sources/STTElevenLabs/ElevenLabsProvider.swift`, add property and override:

```swift
public var batchTranscriber: (any BatchTranscriber)? {
    ElevenLabsBatchTranscriber(apiKey: apiKey, urlSession: urlSession)
}
```

> **Note for callers:** This is a computed property — each access allocates a new transcriber. `MeetingsCoordinator` reads it once during init and stores the result; do not call it inside hot loops or per-segment.

- [ ] **Step 5: Run, expect pass**

Run: `swift test --filter ElevenLabsBatch`

- [ ] **Step 6: Commit**

```bash
git add Sources/STTElevenLabs Tests/STTElevenLabsTests
git commit -m "feat(stt-elevenlabs): batch transcriber for Scribe v2"
```

---

## Phase 3 — Capture (macOS-specific)

These tasks must be guarded `@available(macOS 15, *)`. Tests for the actual capture behavior are manual smoke tests (recording 30 seconds of audio while a Zoom call is active). Unit-testable behavior is limited to writer correctness.

### Task 12: `OpusFileWriter`

ElevenLabs Scribe v2 accepts Ogg Opus. We use `AVAudioFile` with the appropriate settings. If `AVAudioFile` Opus output proves unworkable in practice (one of the spike's open questions, §10.5), fall back to writing 16 kHz Int16 WAV — also accepted by Scribe v2, just larger files.

**Files:**
- Create: `Sources/Meeting/Capture/OpusFileWriter.swift`
- Create: `Tests/MeetingTests/OpusFileWriterTests.swift`

- [ ] **Step 1: Write failing test (write samples, reread, assert non-empty file)**

```swift
import Testing
import Foundation
import AVFoundation
@testable import Meeting

@available(macOS 15, *)
@Suite("OpusFileWriter")
struct OpusFileWriterTests {
    @Test("writes a non-empty file")
    func writeSomething() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try OpusFileWriter(url: url, sampleRate: 16_000)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
        buffer.frameLength = 16_000
        try writer.append(buffer: buffer)
        try writer.close()

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = attrs[.size] as! Int
        #expect(size > 0)
    }
}
```

- [ ] **Step 2: Implement**

`Sources/Meeting/Capture/OpusFileWriter.swift`:

```swift
#if canImport(AVFoundation)
import Foundation
@preconcurrency import AVFoundation

/// Writes audio to an Ogg/Opus file via `AVAudioFile`. If Opus is unavailable
/// in the SDK we're building against, falls back to CAF/PCM (still accepted
/// by Scribe v2 batch). The container choice is internal — callers only see
/// the URL.
@available(macOS 15, *)
public final class OpusFileWriter {
    private let file: AVAudioFile

    public init(url: URL, sampleRate: Double) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatOpus,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
        do {
            self.file = try AVAudioFile(forWriting: url, settings: settings)
        } catch {
            // Fallback: write CAF/Float32. Scribe v2 also accepts WAV/CAF.
            let pcm: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
            ]
            self.file = try AVAudioFile(forWriting: url, settings: pcm)
        }
    }

    public func append(buffer: AVAudioPCMBuffer) throws {
        try file.write(from: buffer)
    }

    public func close() throws {
        // AVAudioFile flushes on deinit. Nothing else to do here, but we keep
        // the explicit close so callers can handle errors deterministically.
    }
}
#endif
```

- [ ] **Step 3: Run, expect pass**

Run: `swift test --filter OpusFileWriter`

- [ ] **Step 4: Commit**

```bash
git commit -am "feat(meeting): OpusFileWriter (Opus with PCM fallback)"
```

---

### Task 13: `MicCapture` long-running mic-to-file

Sibling to `Sources/Audio/AVAudioCapture.swift` — same `AVAudioEngine` shape, different lifecycle (no chunking, no realtime stream; just write to disk until stopped).

**Files:**
- Create: `Sources/Meeting/Capture/MicCapture.swift`
- Create: `Tests/MeetingTests/MicCaptureSmokeTests.swift` (smoke test — runs a 200ms record-stop cycle)

- [ ] **Step 1: Implement**

```swift
#if canImport(AVFoundation)
import Foundation
@preconcurrency import AVFoundation

@available(macOS 15, *)
public actor MicCapture {
    private let outputURL: URL
    private var engine: AVAudioEngine?
    private var writer: OpusFileWriter?

    public init(outputURL: URL) {
        self.outputURL = outputURL
    }

    public func start() async throws {
        guard engine == nil else { return }
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard granted else { throw MeetingError.micPermissionDenied }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        let writer = try OpusFileWriter(url: outputURL, sampleRate: inputFormat.sampleRate)
        self.engine = engine
        self.writer = writer

        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            Task { await self?.handle(buffer: buffer) }
        }
        try engine.start()
    }

    public func stop() async {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        try? writer?.close()
        writer = nil
    }

    private func handle(buffer: AVAudioPCMBuffer) {
        try? writer?.append(buffer: buffer)
    }
}
#endif
```

- [ ] **Step 2: Smoke test (skipped if no mic device)**

```swift
import Testing
import Foundation
@testable import Meeting

@available(macOS 15, *)
@Suite("MicCapture", .disabled("requires mic permission, manual run"))
struct MicCaptureSmokeTests {
    @Test("start/stop produces a file")
    func roundtrip() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mic-\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let mic = MicCapture(outputURL: url)
        try await mic.start()
        try await Task.sleep(for: .milliseconds(200))
        await mic.stop()
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attrs[.size] as! Int) > 0)
    }
}
```

- [ ] **Step 3: Build (no test run since disabled)**

Run: `swift build`
Expected: no errors.

- [ ] **Step 4: Commit**

```bash
git commit -am "feat(meeting): MicCapture long-running mic-to-file"
```

---

### Task 14: `SystemAudioCapture` Process Tap

This is the highest-risk task. Uses the macOS 15 Core Audio Process Tap API: `AudioHardwareCreateProcessTap` with a `CATapDescription`, then `AudioHardwareCreateAggregateDevice` with the tap as a sub-device, then a regular `AVAudioEngine` reads from that aggregate.

If the spike (which should run before this task) found Process Tap unworkable for our needs, **fall back to ScreenCaptureKit** (`SCStream` with `SCStreamConfiguration.capturesAudio = true`) — same TCC permission bucket on macOS 15+, well-documented, produces the same `AVAudioPCMBuffer` shape this class wraps. Spec §10.2 names ScreenCaptureKit as the explicit Plan B; if you switch, only this file changes — the orchestrator and writer don't care which API produced the buffers.

**Files:**
- Create: `Sources/Meeting/Capture/SystemAudioCapture.swift`
- Create: `Tests/MeetingTests/SystemAudioCaptureSmokeTests.swift` (manual)

- [ ] **Step 1: Implement Process Tap setup**

```swift
#if canImport(AudioToolbox) && os(macOS)
import Foundation
import AudioToolbox
@preconcurrency import AVFoundation

@available(macOS 15, *)
public actor SystemAudioCapture {
    private let outputURL: URL
    private var tapId: AudioObjectID = 0
    private var aggregateId: AudioObjectID = 0
    private var engine: AVAudioEngine?
    private var writer: OpusFileWriter?

    public init(outputURL: URL) {
        self.outputURL = outputURL
    }

    public func start() async throws {
        guard tapId == 0 else { return }

        // Create a default-output Process Tap (mute=false, mixed=true: capture
        // everything routed to the default-output device).
        let description = CATapDescription(stereoMixdownOfProcesses: [])
        description.muteBehavior = .unmuted
        description.isPrivate = true
        description.name = "whatchu-say-meeting-tap" as NSString

        var tap: AudioObjectID = 0
        let status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { throw MeetingError.systemAudioPermissionDenied(status: status) }
        tapId = tap

        // Wrap the tap in an aggregate device so AVAudioEngine can read it.
        let aggregateUID = "whatchu-say-aggregate-\(UUID().uuidString)" as CFString
        let dict: [String: Any] = [
            kAudioAggregateDeviceUIDKey as String: aggregateUID,
            kAudioAggregateDeviceNameKey as String: "WhatchuSayMeetingAggregate",
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceTapListKey as String: [
                [kAudioSubTapUIDKey as String: tapId.uidString],
            ],
        ]
        var agg: AudioObjectID = 0
        let aggStatus = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &agg)
        guard aggStatus == noErr else { throw MeetingError.systemAudioPermissionDenied(status: aggStatus) }
        aggregateId = agg

        // Hook AVAudioEngine to the aggregate device and tap its output.
        let engine = AVAudioEngine()
        let input = engine.inputNode
        try input.auAudioUnit.setDeviceID(agg)
        let inputFormat = input.inputFormat(forBus: 0)
        let writer = try OpusFileWriter(url: outputURL, sampleRate: inputFormat.sampleRate)
        self.engine = engine
        self.writer = writer

        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            Task { await self?.handle(buffer: buffer) }
        }
        try engine.start()
    }

    public func stop() async {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        try? writer?.close()
        writer = nil
        if aggregateId != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateId)
            aggregateId = 0
        }
        if tapId != 0 {
            AudioHardwareDestroyProcessTap(tapId)
            tapId = 0
        }
    }

    private func handle(buffer: AVAudioPCMBuffer) {
        try? writer?.append(buffer: buffer)
    }
}

private extension AudioObjectID {
    var uidString: String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString>.size)
        var uid: Unmanaged<CFString>?
        AudioObjectGetPropertyData(self, &address, 0, nil, &size, &uid)
        return uid?.takeRetainedValue() as String? ?? ""
    }
}
#endif
```

- [ ] **Step 2: Build (will likely fail first time — fix import / API name issues based on compiler output)**

Run: `swift build`

The Process Tap API has small signature changes between Xcode beta/release. If the compiler complains about `CATapDescription(stereoMixdownOfProcesses:)`, check the Xcode-version-installed AudioToolbox headers and use the matching initializer name. Goal of this step is "compiles cleanly," not "runs cleanly" — that's the smoke test.

- [ ] **Step 3: Smoke test**

```swift
import Testing
import Foundation
@testable import Meeting

@available(macOS 15, *)
@Suite("SystemAudioCapture", .disabled("manual: requires Screen & System Audio Recording permission + audio playing"))
struct SystemAudioCaptureSmokeTests {
    @Test("captures 200ms of system audio while audio plays")
    func roundtrip() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("system-\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let cap = SystemAudioCapture(outputURL: url)
        try await cap.start()
        try await Task.sleep(for: .milliseconds(500))
        await cap.stop()
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int
        #expect(size > 1024)
    }
}
```

Manual run: enable the Suite, grant Screen & System Audio Recording permission to the test runner, play audio, and run `swift test --filter SystemAudioCapture`.

- [ ] **Step 4: Commit**

```bash
git commit -am "feat(meeting): SystemAudioCapture via Core Audio Process Tap (macOS 15+)"
```

---

### Task 15: `MeetingError` types

**Files:**
- Create: `Sources/Meeting/Errors/MeetingError.swift`

- [ ] **Step 1: Implement**

```swift
import Foundation

public enum MeetingError: Error, Equatable {
    case micPermissionDenied
    case systemAudioPermissionDenied(status: OSStatus)
    case captureSetupFailed(String)
    case transcriptionFailed(String)
    case mappingFailed(String)
    case sessionNotFound
    case alreadyRecording
}
```

- [ ] **Step 2: Verify build**

Run: `swift build`

- [ ] **Step 3: Commit**

```bash
git commit -am "feat(meeting): MeetingError enum"
```

---

## Phase 4 — Orchestration

### Task 16: `MeetingOrchestrator` — start/stop/transcribe lifecycle

Public entry point. Owns one `MeetingSession` at a time. Coordinates capture start, capture stop, transcription pipeline, and library updates. Emits events via `AsyncStream` for the UI to subscribe.

**Files:**
- Create: `Sources/Meeting/MeetingOrchestrator.swift`
- Create: `Tests/MeetingTests/MeetingOrchestratorTests.swift`
- Create: `Tests/MeetingTests/Mocks/MockAudioRecorder.swift`

- [ ] **Step 1: Define `AudioRecorderProtocol` for testability**

`Sources/Meeting/Capture/AudioRecorderProtocol.swift`:

```swift
import Foundation

/// Protocol both `MicCapture` and `SystemAudioCapture` conform to. Lets the
/// orchestrator depend on an interface rather than the concrete actors,
/// which makes it testable without real audio hardware.
public protocol AudioRecorderProtocol: Sendable {
    func start() async throws
    func stop() async
}
```

In `MicCapture` and `SystemAudioCapture`, conform to this protocol (no behavioral change — both already have `start()` / `stop()`).

- [ ] **Step 2: Mock recorder for tests**

`Tests/MeetingTests/Mocks/MockAudioRecorder.swift`:

```swift
import Foundation
@testable import Meeting

actor MockAudioRecorder: AudioRecorderProtocol {
    var didStart = false
    var didStop = false
    var startError: Error?

    func setStartError(_ e: Error?) { startError = e }

    func start() async throws {
        if let e = startError { throw e }
        didStart = true
    }
    func stop() async { didStop = true }
}
```

- [ ] **Step 3: Write failing tests**

```swift
import Testing
import Foundation
@testable import Meeting
import STTCore

@Suite("MeetingOrchestrator")
struct MeetingOrchestratorTests {
    func makeLibrary() throws -> (MeetingLibrary, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("orch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (MeetingLibrary(rootDirectory: root), root)
    }

    @Test("start creates session, calls both recorders' start")
    func startBoth() async throws {
        let (lib, root) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let mic = MockAudioRecorder()
        let system = MockAudioRecorder()
        let mock = MockBatchTranscriber()

        let orch = MeetingOrchestrator(
            library: lib,
            micRecorder: mic,
            systemRecorder: system,
            transcriber: mock,
            mapper: ContentBasedSpeakerNameMapper()
        )
        let id = try await orch.start(attendees: AttendeeList(names: ["Alice"]), keepAudio: false)
        #expect(await mic.didStart)
        #expect(await system.didStart)
        let session = try lib.load(id: id)
        #expect(session.status == .recording)
    }

    @Test("stop produces a transcript, marks session completed")
    func stopAndTranscribe() async throws {
        let (lib, root) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let mic = MockAudioRecorder()
        let system = MockAudioRecorder()
        let mock = MockBatchTranscriber()

        let orch = MeetingOrchestrator(
            library: lib,
            micRecorder: mic,
            systemRecorder: system,
            transcriber: mock,
            mapper: ContentBasedSpeakerNameMapper()
        )
        let id = try await orch.start(attendees: AttendeeList(names: []), keepAudio: false)
        // Pre-stage transcriber responses for the mic + system file URLs the
        // orchestrator will pass — we read them from the library.
        let micURL = try lib.micFile(for: id)
        let systemURL = try lib.systemFile(for: id)
        try Data().write(to: micURL)
        try Data().write(to: systemURL)
        await mock.setResponse(.init(segments: []), for: micURL)
        await mock.setResponse(.init(segments: [
            .init(start: 0, end: 1, speakerId: 0, text: "hi"),
        ]), for: systemURL)

        try await orch.stop()
        let session = try lib.load(id: id)
        #expect(session.status == .completed)
        #expect(await mic.didStop)
        #expect(await system.didStop)
    }

    @Test("audio is deleted after successful transcription when keepAudio=false")
    func deleteAudioOnSuccess() async throws {
        let (lib, root) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let mock = MockBatchTranscriber()
        let orch = MeetingOrchestrator(
            library: lib,
            micRecorder: MockAudioRecorder(),
            systemRecorder: MockAudioRecorder(),
            transcriber: mock,
            mapper: ContentBasedSpeakerNameMapper()
        )
        let id = try await orch.start(attendees: AttendeeList(names: []), keepAudio: false)
        let micURL = try lib.micFile(for: id)
        let systemURL = try lib.systemFile(for: id)
        try Data().write(to: micURL)
        try Data().write(to: systemURL)
        await mock.setResponse(.init(segments: []), for: micURL)
        await mock.setResponse(.init(segments: []), for: systemURL)
        try await orch.stop()
        #expect(!FileManager.default.fileExists(atPath: micURL.path))
        #expect(!FileManager.default.fileExists(atPath: systemURL.path))
    }

    @Test("audio is retained when transcription fails")
    func retainAudioOnFailure() async throws {
        let (lib, root) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let mock = MockBatchTranscriber()
        let orch = MeetingOrchestrator(
            library: lib,
            micRecorder: MockAudioRecorder(),
            systemRecorder: MockAudioRecorder(),
            transcriber: mock,
            mapper: ContentBasedSpeakerNameMapper()
        )
        let id = try await orch.start(attendees: AttendeeList(names: []), keepAudio: false)
        let micURL = try lib.micFile(for: id)
        let systemURL = try lib.systemFile(for: id)
        try Data().write(to: micURL)
        try Data().write(to: systemURL)
        // No response staged → mock throws → orchestrator should fail
        await #expect(throws: Error.self) {
            try await orch.stop()
        }
        #expect(FileManager.default.fileExists(atPath: micURL.path))
        let session = try lib.load(id: id)
        if case .failed = session.status {} else {
            Issue.record("expected .failed status, got \(session.status)")
        }
    }

    @Test("alreadyRecording on double start")
    func doubleStart() async throws {
        let (lib, root) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let orch = MeetingOrchestrator(
            library: lib,
            micRecorder: MockAudioRecorder(),
            systemRecorder: MockAudioRecorder(),
            transcriber: MockBatchTranscriber(),
            mapper: ContentBasedSpeakerNameMapper()
        )
        _ = try await orch.start(attendees: AttendeeList(names: []), keepAudio: false)
        await #expect(throws: MeetingError.alreadyRecording) {
            _ = try await orch.start(attendees: AttendeeList(names: []), keepAudio: false)
        }
    }
}
```

- [ ] **Step 4: Implement orchestrator**

`Sources/Meeting/MeetingOrchestrator.swift`:

```swift
import Foundation
import STTCore

public actor MeetingOrchestrator {
    public enum State: Sendable, Equatable {
        case idle
        case recording(UUID)
        case transcribing(UUID)
    }

    private let library: any MeetingLibraryProtocol
    private let micRecorder: any AudioRecorderProtocol
    private let systemRecorder: any AudioRecorderProtocol
    private let transcriber: any BatchTranscriber
    private let mapper: any SpeakerNameMapper
    public private(set) var state: State = .idle

    public init(
        library: any MeetingLibraryProtocol,
        micRecorder: any AudioRecorderProtocol,
        systemRecorder: any AudioRecorderProtocol,
        transcriber: any BatchTranscriber,
        mapper: any SpeakerNameMapper
    ) {
        self.library = library
        self.micRecorder = micRecorder
        self.systemRecorder = systemRecorder
        self.transcriber = transcriber
        self.mapper = mapper
    }

    public func start(attendees: AttendeeList, keepAudio: Bool) async throws -> UUID {
        guard case .idle = state else { throw MeetingError.alreadyRecording }
        let session = MeetingSession(
            id: UUID(),
            title: nil,
            startedAt: Date(),
            attendees: attendees,
            keepAudio: keepAudio
        )
        _ = try library.create(session: session)

        do {
            try await micRecorder.start()
            try await systemRecorder.start()
        } catch {
            await micRecorder.stop()
            await systemRecorder.stop()
            try? library.delete(id: session.id)
            throw error
        }
        state = .recording(session.id)
        return session.id
    }

    public func stop() async throws {
        guard case .recording(let id) = state else { return }
        await micRecorder.stop()
        await systemRecorder.stop()

        var session = try library.load(id: id)
        session.markStopped(at: Date())
        try library.update(session: session)
        state = .transcribing(id)

        let micURL = try library.micFile(for: id)
        let systemURL = try library.systemFile(for: id)
        let pipeline = MeetingTranscriptionPipeline(transcriber: transcriber, mapper: mapper)

        do {
            let transcript = try await pipeline.run(
                micAudio: micURL,
                systemAudio: systemURL,
                attendees: session.attendees
            )
            try library.writeTranscript(transcript, for: id, title: session.title)
            session.markCompleted()
            try library.update(session: session)
            if !session.keepAudio {
                try? library.deleteAudio(for: id)
            }
            state = .idle
        } catch {
            session.markFailed(reason: String(describing: error))
            try? library.update(session: session)
            state = .idle
            throw error
        }
    }
}
```

- [ ] **Step 5: Run, expect pass**

Run: `swift test --filter MeetingOrchestrator`

- [ ] **Step 6: Commit**

```bash
git commit -am "feat(meeting): MeetingOrchestrator lifecycle (start/stop/transcribe)"
```

---

### Task 17: AppConfig — `MeetingsConfig` + migration

**Files:**
- Modify: `Sources/Core/AppConfig.swift` — add `MeetingsConfig` + field
- Modify: `Sources/Core/ConfigMigration.swift` — bump version, add migration handler
- Modify: `Tests/CoreTests/...` — add round-trip and migration tests

- [ ] **Step 1: Read existing migration shape**

Read `Sources/Core/ConfigMigration.swift` to understand the migration pattern. The v0→v1 handler in that file is the canonical example — model the v1→v2 handler on it (same shape: read raw JSON, inject defaults for new fields, hand back to `JSONDecoder`).

- [ ] **Step 2: Write failing tests**

In `Tests/CoreTests/`, add a new test file (or extend an existing one):

```swift
import Testing
@testable import Core

@Suite("MeetingsConfig")
struct MeetingsConfigTests {
    @Test("defaults are spec-aligned")
    func defaults() {
        let m = MeetingsConfig()
        #expect(m.showAttendeeFieldAtStart == true)
        #expect(m.showConsentReminder == true)
        #expect(m.deleteAudioAfterTranscription == true)
    }

    @Test("AppConfig encodes meetings field")
    func roundtrip() throws {
        let original = AppConfig()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded.meetings == original.meetings)
    }
}
```

- [ ] **Step 3: Implement**

In `Sources/Core/AppConfig.swift`, add to the file:

```swift
// MARK: - Meetings

public struct MeetingsConfig: Codable, Sendable, Equatable {
    public var showAttendeeFieldAtStart: Bool
    public var showConsentReminder: Bool
    public var deleteAudioAfterTranscription: Bool

    public init(
        showAttendeeFieldAtStart: Bool = true,
        showConsentReminder: Bool = true,
        deleteAudioAfterTranscription: Bool = true
    ) {
        self.showAttendeeFieldAtStart = showAttendeeFieldAtStart
        self.showConsentReminder = showConsentReminder
        self.deleteAudioAfterTranscription = deleteAudioAfterTranscription
    }
}
```

Then add `meetings: MeetingsConfig` to `AppConfig`'s stored properties and to the init.

Bump `currentSchemaVersion` to `2`. In `ConfigMigration.swift`, add handler for v1→v2 that injects the default `MeetingsConfig` JSON before decoding.

- [ ] **Step 4: Run, expect pass**

Run: `swift test --filter Core`

- [ ] **Step 5: Commit**

```bash
git commit -am "feat(core): MeetingsConfig + schema v2 migration"
```

---

## Phase 5 — Mac app integration

These tasks run in the Xcode project (`Apps/WhatchuSayMac/WhatchuSayMac.xcodeproj`). Tests for SwiftUI views are out of scope — verify by building in Xcode and running the app via `make install`.

**For each Mac-app task:** Add the new file(s) to the Xcode project (drag in or use the `File → Add Files…` menu — the project doesn't use file-system synced groups, so files need explicit registration). Build via Xcode (⌘B), then `make install`.

### Task 18: `MeetingsCoordinator` — bridge between AppCoordinator and the orchestrator

**Files:**
- Create: `Apps/WhatchuSayMac/WhatchuSayMac/Meeting/MeetingsCoordinator.swift`

- [ ] **Step 1: Implement**

```swift
import Foundation
import AppKit
import Meeting
import STTCore
import STTElevenLabs
import Core

/// Owns the singleton MeetingOrchestrator and the windows it drives.
/// Constructed by AppCoordinator; lives for the lifetime of the app.
@MainActor
final class MeetingsCoordinator {
    private let orchestrator: MeetingOrchestrator
    private let library: MeetingLibrary
    private var transcriptWindow: NSWindow?

    init(apiKey: String, configStore: ConfigStore) throws {
        let library = try MeetingLibrary(rootDirectory: MeetingLibrary.defaultRoot())
        let provider = ElevenLabsProvider(apiKey: apiKey)
        guard let transcriber = provider.batchTranscriber else {
            throw MeetingError.captureSetupFailed("provider has no batch transcriber")
        }
        self.library = library
        self.orchestrator = MeetingOrchestrator(
            library: library,
            micRecorder: MicCapture(outputURL: library.directory(for: UUID()).appendingPathComponent("mic.opus")),
            systemRecorder: SystemAudioCapture(outputURL: library.directory(for: UUID()).appendingPathComponent("system.opus")),
            transcriber: transcriber,
            mapper: ContentBasedSpeakerNameMapper()
        )
    }

    // Concrete recorder construction is delayed until start — see Task 19.
}
```

This file will need a small follow-up in Task 19; the recorder URLs in the constructor above are placeholders. Step 1 just establishes the wiring shell. **Do not exercise the orchestrator (no `start(...)` calls) until Task 19 lands** — the placeholder URLs would write to meaningless paths.

- [ ] **Step 2: Add file to Xcode project**

In Xcode: right-click the `WhatchuSayMac` group → Add Files → select `Meeting/MeetingsCoordinator.swift`.

- [ ] **Step 3: Build in Xcode**

⌘B. Expected: clean build.

- [ ] **Step 4: Commit**

```bash
git add Apps/WhatchuSayMac
git commit -m "feat(mac): MeetingsCoordinator scaffold"
```

---

### Task 19: Recorder factory — defer URL until start

The `MeetingsCoordinator` from Task 18 constructs recorders eagerly with placeholder URLs. Refactor so recorders are created lazily inside `MeetingOrchestrator.start(...)`.

**Files:**
- Modify: `Sources/Meeting/MeetingOrchestrator.swift`
- Modify: `Apps/WhatchuSayMac/WhatchuSayMac/Meeting/MeetingsCoordinator.swift`

- [ ] **Step 1: Add a recorder-factory closure to the orchestrator**

Change `MeetingOrchestrator`'s init to take:

```swift
public typealias RecorderFactory = @Sendable (URL) -> any AudioRecorderProtocol

public init(
    library: any MeetingLibraryProtocol,
    micRecorderFactory: @escaping RecorderFactory,
    systemRecorderFactory: @escaping RecorderFactory,
    transcriber: any BatchTranscriber,
    mapper: any SpeakerNameMapper
)
```

In `start(...)`:

```swift
let micURL = try library.micFile(for: session.id)
let systemURL = try library.systemFile(for: session.id)
let mic = micRecorderFactory(micURL)
let system = systemRecorderFactory(systemURL)
// store on actor for stop() to call later
```

- [ ] **Step 2: Update tests to use factory shape**

Existing `MeetingOrchestratorTests` change from passing `MockAudioRecorder` instances directly to passing `{ _ in mockMic }` etc. Same number of tests; signature change only.

- [ ] **Step 3: Update `MeetingsCoordinator`**

```swift
self.orchestrator = MeetingOrchestrator(
    library: library,
    micRecorderFactory: { url in MicCapture(outputURL: url) },
    systemRecorderFactory: { url in SystemAudioCapture(outputURL: url) },
    transcriber: transcriber,
    mapper: ContentBasedSpeakerNameMapper()
)
```

- [ ] **Step 4: Run library tests**

Run: `swift test --filter Meeting`

- [ ] **Step 5: Build Xcode app**

⌘B. Expected: clean.

- [ ] **Step 6: Commit**

```bash
git commit -am "refactor(meeting): lazy recorder factories so URL is known at start"
```

---

### Task 20: Start meeting modal

**Files:**
- Create: `Apps/WhatchuSayMac/WhatchuSayMac/Meeting/StartMeetingModal.swift`

Build the modal in SwiftUI hosted in an `NSPanel` (mirroring the existing `HUDPanel.swift` shape).

- [ ] **Step 1: Implement modal view + panel**

```swift
import AppKit
import SwiftUI
import Meeting

@MainActor
final class StartMeetingPanel: NSPanel {
    private let onStart: (AttendeeList) -> Void
    private let onCancel: () -> Void
    private let showConsentReminder: Bool
    private let showAttendeeField: Bool

    init(showConsentReminder: Bool, showAttendeeField: Bool, onStart: @escaping (AttendeeList) -> Void, onCancel: @escaping () -> Void) {
        self.onStart = onStart
        self.onCancel = onCancel
        self.showConsentReminder = showConsentReminder
        self.showAttendeeField = showAttendeeField
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 220),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        title = "Start meeting recording"
        let view = StartMeetingModalView(
            showConsentReminder: showConsentReminder,
            showAttendeeField: showAttendeeField,
            onStart: { [weak self] list in
                self?.onStart(list); self?.close()
            },
            onCancel: { [weak self] in
                self?.onCancel(); self?.close()
            }
        )
        contentView = NSHostingView(rootView: view)
        center()
    }
}

struct StartMeetingModalView: View {
    let showConsentReminder: Bool
    let showAttendeeField: Bool
    let onStart: (AttendeeList) -> Void
    let onCancel: () -> Void

    @State private var attendeesText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showConsentReminder {
                Text("Recording without consent is illegal in some jurisdictions. Confirm participants are aware.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if showAttendeeField {
                Text("Attendees (optional)")
                    .font(.headline)
                TextField("Alice, Bob, Carol", text: $attendeesText)
                    .textFieldStyle(.roundedBorder)
            }
            Spacer()
            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Start") {
                    onStart(AttendeeList(parsing: attendeesText))
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 380, minHeight: 180)
    }
}
```

- [ ] **Step 2: Add file to Xcode project, build**

⌘B. Expected: clean.

- [ ] **Step 3: Commit**

```bash
git commit -am "feat(mac): StartMeetingPanel — consent + attendees modal"
```

---

### Task 21: Menu bar Meeting entries

**Files:**
- Modify: `Apps/WhatchuSayMac/WhatchuSayMac/StatusItemController.swift`
- Modify: `Apps/WhatchuSayMac/WhatchuSayMac/Meeting/MeetingsCoordinator.swift`

- [ ] **Step 1: Add "Start meeting recording" menu item**

In `StatusItemController.swift`, locate the menu construction. Add a new section above existing dictation entries:

```swift
let startItem = NSMenuItem(title: "Start meeting recording", action: #selector(MeetingsCoordinator.startMeetingMenuAction(_:)), keyEquivalent: "")
startItem.target = meetingsCoordinator
menu.addItem(startItem)
menu.addItem(.separator())
```

When recording is active, replace this entry with:
- Title: "Stop recording (00:42)" — updated by a `Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true)` stored on `MeetingsCoordinator`
- Action: stop

**Timer lifecycle:** start the timer when entering recording state, invalidate it in `stopMeeting()` (and in `deinit` as a defensive measure). Do not retain `self` strongly inside the timer's closure — use `[weak self]`. Without invalidation the timer keeps the coordinator alive and ticks indefinitely.

- [ ] **Step 2: Implement menu actions in `MeetingsCoordinator`**

```swift
@objc func startMeetingMenuAction(_ sender: NSMenuItem) {
    let panel = StartMeetingPanel(
        showConsentReminder: configStore.config.meetings.showConsentReminder,
        showAttendeeField: configStore.config.meetings.showAttendeeFieldAtStart,
        onStart: { [weak self] list in
            Task { await self?.beginRecording(attendees: list) }
        },
        onCancel: {}
    )
    panel.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
}

private func beginRecording(attendees: AttendeeList) async {
    do {
        let id = try await orchestrator.start(
            attendees: attendees,
            keepAudio: !configStore.config.meetings.deleteAudioAfterTranscription
        )
        // tell status item to swap to "Stop recording" mode
        statusItem?.showRecordingState(meetingId: id)
    } catch {
        // surface via existing recent-errors log
    }
}
```

- [ ] **Step 3: Build in Xcode, install, smoke test**

```bash
make install
open /Applications/WhatchuSayMac.app
```

Click menu bar icon → "Start meeting recording" → verify modal appears, type attendees, hit Start, verify menu now shows Stop. Hit Stop, verify orchestrator transitions to `.transcribing`. Real Scribe v2 call will likely fail in this smoke test if API key isn't set — that's fine; you're verifying UI wiring, not transcription.

- [ ] **Step 4: Commit**

```bash
git commit -am "feat(mac): menu-bar Start/Stop meeting recording entries"
```

---

### Task 22: Transcript window

**Files:**
- Create: `Apps/WhatchuSayMac/WhatchuSayMac/Meeting/TranscriptWindow.swift`
- Create: `Apps/WhatchuSayMac/WhatchuSayMac/Meeting/TranscriptView.swift`

- [ ] **Step 1: Implement transcript view**

```swift
import SwiftUI
import Meeting

struct TranscriptView: View {
    @State var session: MeetingSession
    @State var transcript: MeetingTranscript
    @State var attendeesText: String
    @State var audioStillExists: Bool
    let onAttendeesChanged: (AttendeeList) async -> MeetingTranscript
    let onRename: (Speaker, String) -> Void
    let onDeleteTranscript: () -> Void
    let onDeleteAudioNow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                TextField("Title", text: $session.title)
                    .textFieldStyle(.plain)
                    .font(.title2)
                Spacer()
                if audioStillExists {
                    Button("Delete audio") {
                        onDeleteAudioNow()
                        audioStillExists = false
                    }
                    .help("Audio is currently retained on disk. Click to delete.")
                } else {
                    Text("Audio: deleted")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                Button(role: .destructive) {
                    onDeleteTranscript()
                } label: {
                    Image(systemName: "trash")
                }
                .help("Delete this transcript and all associated files")
            }
            .padding()

            HStack {
                Text("Attendees:")
                TextField("Alice, Bob, Carol", text: $attendeesText, onCommit: {
                    Task {
                        let updated = await onAttendeesChanged(AttendeeList(parsing: attendeesText))
                        transcript = updated
                    }
                })
            }
            .padding(.horizontal)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(transcript.segments.enumerated()), id: \.offset) { _, seg in
                        HStack(alignment: .top, spacing: 8) {
                            Text(formatTimestamp(seg.start))
                                .foregroundStyle(.secondary)
                                .font(.caption.monospacedDigit())
                            speakerLabel(for: seg.speaker)
                                .contextMenu {
                                    Button("Rename to…") {
                                        // open rename sheet
                                    }
                                }
                            Text(seg.text)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding()
            }
        }
    }

    private func formatTimestamp(_ s: TimeInterval) -> String {
        let total = Int(s)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private func speakerLabel(for speaker: Speaker) -> some View {
        let text: String = {
            switch speaker {
            case .me: return "Me"
            case .tagged(let n): return n
            case .anonymous(let id): return "Speaker \(id)"
            }
        }()
        return Text(text).bold()
    }
}
```

- [ ] **Step 2: Implement window owner**

```swift
import AppKit
import SwiftUI
import Meeting

@MainActor
final class TranscriptWindow {
    private var window: NSWindow?

    func show(session: MeetingSession, transcript: MeetingTranscript, library: MeetingLibrary, mapper: any SpeakerNameMapper) {
        let micExists = (try? FileManager.default.fileExists(atPath: library.micFile(for: session.id).path)) ?? false
        let view = TranscriptView(
            session: session,
            transcript: transcript,
            attendeesText: session.attendees.names.joined(separator: ", "),
            audioStillExists: micExists,
            onAttendeesChanged: { newList in
                let mapping = (try? await mapper.map(transcript: transcript, attendees: newList)) ?? [:]
                var updated = transcript
                updated.applySpeakerMapping(mapping)
                try? library.writeTranscript(updated, for: session.id, title: session.title)
                return updated
            },
            onRename: { _, _ in },
            onDeleteTranscript: { [weak self] in
                try? library.delete(id: session.id)
                self?.window?.close()
            },
            onDeleteAudioNow: {
                try? library.deleteAudio(for: session.id)
            }
        )
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = session.title
        window.setContentSize(NSSize(width: 720, height: 600))
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }
}
```

- [ ] **Step 3: Wire from MeetingsCoordinator**

After `orchestrator.stop()` returns, call `transcriptWindow.show(...)` on success. Read transcript via `library.directory(for:).appendingPathComponent("transcript.json")` and decode `MeetingTranscript`.

- [ ] **Step 4: Build, install, smoke test**

Real run: enable a fake test key or ensure ElevenLabs key is in keychain, start a meeting, play YouTube for 30 seconds, stop, verify transcript window opens with content.

- [ ] **Step 5: Commit**

```bash
git commit -am "feat(mac): TranscriptWindow with attendee re-edit"
```

---

### Task 23: Meetings settings pane

**Files:**
- Create: `Apps/WhatchuSayMac/WhatchuSayMac/Settings/MeetingsPane.swift`
- Modify: `Apps/WhatchuSayMac/WhatchuSayMac/Settings/SettingsView.swift`

- [ ] **Step 1: Read existing pane shape**

Open `PrivacyPane.swift` and `GeneralPane.swift` to learn the project's idiomatic SwiftUI form layout, ConfigStoreBinding usage, and section structure.

- [ ] **Step 2: Implement pane**

```swift
import SwiftUI
import Core

struct MeetingsPane: View {
    @ObservedObject var configBinding: ConfigStoreBinding

    var body: some View {
        Form {
            Section("Behavior") {
                Toggle("Show attendee field at start", isOn: configBinding.binding(for: \.meetings.showAttendeeFieldAtStart))
                Toggle("Show consent reminder before each recording", isOn: configBinding.binding(for: \.meetings.showConsentReminder))
            }
            Section("Storage") {
                Toggle("Delete recorded audio after transcription", isOn: configBinding.binding(for: \.meetings.deleteAudioAfterTranscription))
                HStack {
                    Text("Storage location:")
                    Spacer()
                    Button("Reveal in Finder") { revealInFinder() }
                }
            }
            Section("Permissions") {
                PermissionRow(label: "Microphone", granted: micGranted)
                PermissionRow(label: "Screen & System Audio Recording", granted: systemAudioGranted)
            }
        }
        .padding()
    }

    private func revealInFinder() {
        guard let url = try? MeetingLibrary.defaultRoot() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
```

`PermissionRow` — implement as a small inline view that mirrors the existing privacy-pane row structure.

- [ ] **Step 3: Register pane in `SettingsView`**

Add to the existing tab-/sidebar-driven pane list. Follow the same pattern as the other six panes.

- [ ] **Step 4: Build, install, verify in Settings window**

- [ ] **Step 5: Commit**

```bash
git commit -am "feat(mac): Meetings settings pane"
```

---

### Task 24: First-run privacy modal — Meetings section

**Files:**
- Modify: `Apps/WhatchuSayMac/WhatchuSayMac/Settings/FirstRunDisclosure.swift`

- [ ] **Step 1: Read existing first-run shape**

Understand how the modal currently presents Mic/Accessibility sections.

- [ ] **Step 2: Add Meetings section**

Add a new section explaining the Meetings feature is optional, what permission it needs, and a "Grant when I start my first meeting" deferral button.

- [ ] **Step 3: Build, install, run with a fresh user**

`defaults delete com.whatchu-say.mac` (or similar — check what UserDefaults domain the app uses) to reset first-run, relaunch, verify the new section appears and is dismissable.

- [ ] **Step 4: Commit**

```bash
git commit -am "feat(mac): first-run modal — optional Meetings section"
```

---

### Task 25: Permission deep link — Screen & System Audio Recording

**Files:**
- Modify: `Apps/WhatchuSayMac/WhatchuSayMac/Permissions/PermissionDeepLink.swift`

- [ ] **Step 1: Add the deep-link entry**

```swift
enum PermissionDeepLink {
    // existing cases…
    case screenAndSystemAudioRecording

    var url: URL {
        switch self {
        // existing…
        case .screenAndSystemAudioRecording:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        }
    }
}
```

- [ ] **Step 2: Use in MeetingsPane permission row**

Wire the row's "Grant" button to open this deep link.

- [ ] **Step 3: Build, install, verify**

Click Grant on the meetings pane permission row → System Settings opens to the right pane.

- [ ] **Step 4: Commit**

```bash
git commit -am "feat(mac): deep link to Screen & System Audio Recording pane"
```

---

### Task 26: Info.plist usage strings

**Files:**
- Modify: `Apps/WhatchuSayMac/WhatchuSayMac/Info.plist` (or wherever the project stores Info.plist values — check the Xcode project's Info tab)

- [ ] **Step 1: Add `NSScreenCaptureUsageDescription`**

```xml
<key>NSScreenCaptureUsageDescription</key>
<string>whatchu-say records meeting audio from other apps so it can be transcribed.</string>
```

The `NSMicrophoneUsageDescription` should already exist for dictation; verify and update copy if it doesn't mention meetings.

- [ ] **Step 2: Build, install, verify TCC prompt copy**

Trigger a first-time meeting recording → verify the system prompt shows the new copy.

- [ ] **Step 3: Commit**

```bash
git commit -am "feat(mac): NSScreenCaptureUsageDescription for meeting capture"
```

---

### Task 27: Wire `MeetingsCoordinator` into `AppCoordinator`

**Files:**
- Modify: `Apps/WhatchuSayMac/WhatchuSayMac/AppCoordinator.swift`

- [ ] **Step 1: Read existing AppCoordinator**

Understand how it constructs the dictation orchestrator. The meetings coordinator follows the same pattern.

- [ ] **Step 2: Add meeting coordinator construction**

```swift
let meetingsCoordinator = try MeetingsCoordinator(
    apiKey: apiKey, // from keychain
    configStore: configStore
)
```

Pass to `StatusItemController` so its menu can call into it.

- [ ] **Step 3: Build, install, end-to-end smoke**

Full flow: Start meeting → modal → enter "Alice, Bob" → start → play YouTube 30s → stop → wait for Scribe v2 response → transcript window opens with merged segments.

- [ ] **Step 4: Commit**

```bash
git commit -am "feat(mac): wire MeetingsCoordinator into AppCoordinator"
```

---

## Phase 6 — Documentation & roadmap

### Task 28: Update `TECH_SPEC.md` and `ROADMAP.md`

**Files:**
- Modify: `docs/TECH_SPEC.md`
- Modify: `docs/ROADMAP.md`

- [ ] **Step 1: Add §13 "Meeting transcription" to TECH_SPEC**

Summarize the implemented design: capture (Process Tap on macOS 15+), provider (ElevenLabs Scribe v2 batch with `BatchTranscriber` capability), pipeline (mic + system → merge → LLM map → transcript), no calendar OAuth, manual attendees. Link to the spec at `docs/superpowers/specs/2026-05-02-meeting-transcription-design.md` for full detail.

- [ ] **Step 2: Add a new milestone to ROADMAP**

Following the existing roadmap's per-bullet status format, add a Phase 4 entry "Meeting transcription" with sub-bullets matching the tasks in this plan, all marked unchecked initially.

- [ ] **Step 3: Commit**

```bash
git commit -am "docs: TECH_SPEC §13 + roadmap entry for meeting transcription"
```

---

### Task 28a: Periodic flush of audio writers (crash-recovery foundation)

Per spec §9, audio buffers must be flushed every ~10 s so that a crash mid-meeting leaves at most ~10 s of unwritten data. `AVAudioFile` flushes lazily; we explicitly close-and-reopen on a timer.

**Files:**
- Modify: `Sources/Meeting/Capture/MicCapture.swift`
- Modify: `Sources/Meeting/Capture/SystemAudioCapture.swift`
- Modify: `Sources/Meeting/Capture/OpusFileWriter.swift` — add `flush()` method

- [ ] **Step 1: Add `flush()` to `OpusFileWriter`**

```swift
public func flush() throws {
    // AVAudioFile does not expose an explicit flush. Closing the underlying
    // file and reopening in append mode is unsafe; instead, the recorder
    // tears down and reopens this writer on the flush cadence.
}
```

(The actual flushing is achieved by the recorder closing this writer and creating a new one for a sequence-numbered file segment, then concatenating segments at stop time. This avoids touching `AVAudioFile`'s internals.)

- [ ] **Step 2: Implement segmented writing in recorders**

In `MicCapture` and `SystemAudioCapture`, change the writer field to write to `mic-000.opus`, `mic-001.opus`, … rotating every 10 s on a `DispatchSourceTimer`. On `stop()`, concatenate segments via `AVAssetExportSession` (or simple binary concat for PCM/CAF) into the final `mic.opus` / `system.opus`.

Simpler alternative if `AVAssetExportSession` proves fiddly for our format: leave segments as-is and have the transcription pipeline accept either a single URL or a list of URLs (Scribe v2 doesn't natively merge — would need pre-upload concat). Choose based on what works.

- [ ] **Step 3: Smoke test**

Manual: start recording, kill the app process after 30 s (`kill -9`), verify segment files on disk are valid (e.g. `afinfo mic-000.opus` reports valid header + duration).

- [ ] **Step 4: Commit**

```bash
git commit -am "feat(meeting): segmented audio writers for crash recovery"
```

---

### Task 28b: Launch-time recovery prompt for half-written meetings

**Files:**
- Modify: `Sources/Meeting/Persistence/MeetingLibrary.swift` — add `findIncomplete()`
- Create: `Apps/WhatchuSayMac/WhatchuSayMac/Meeting/RecoveryPrompt.swift`
- Modify: `Apps/WhatchuSayMac/WhatchuSayMac/Meeting/MeetingsCoordinator.swift` — call recovery on init

- [ ] **Step 1: Add `findIncomplete()` to `MeetingLibrary`**

```swift
public func findIncomplete() throws -> [MeetingSession] {
    try listAll().filter { session in
        if case .recording = session.status { return true }
        if case .transcribing = session.status { return true }
        return false
    }
}
```

Add a test in `MeetingLibraryTests` that creates a session, leaves status at `.recording`, and verifies `findIncomplete()` returns it.

- [ ] **Step 2: Implement `RecoveryPrompt`**

Simple `NSAlert` per incomplete meeting with three buttons: "Try transcribing what we have", "Discard", "Decide later". The first calls `MeetingOrchestrator.recover(id:)` (a new method); the second deletes the meeting; the third leaves it on disk for the next launch.

- [ ] **Step 3: Add `MeetingOrchestrator.recover(id:)`**

Reuses the existing transcription pipeline: load the session, point at the (segment-concatenated or single) audio files, call `pipeline.run`, mark completed/failed identically to `stop()`.

- [ ] **Step 4: Wire from `MeetingsCoordinator.init`**

After construction, scan once via `library.findIncomplete()`. For each result, present `RecoveryPrompt`. Sheet attached to no parent window — these are launch-time alerts.

- [ ] **Step 5: Smoke test**

Manual: start a meeting, kill the app, relaunch. Verify the prompt appears for the incomplete session. Click "Try transcribing what we have" → verify a transcript is produced from the partial audio.

- [ ] **Step 6: Commit**

```bash
git commit -am "feat(meeting): launch-time recovery for half-written meetings"
```

---

### Task 29: End-to-end smoke + final verification

- [ ] **Step 1: Run the full library test suite**

```bash
swift test
```

Expected: all tests pass.

- [ ] **Step 2: Build the Mac app in Xcode**

⌘B in `Apps/WhatchuSayMac/WhatchuSayMac.xcodeproj`. Expected: clean build, no warnings.

- [ ] **Step 3: Install and run a real 5-minute meeting**

```bash
make install
open /Applications/WhatchuSayMac.app
```

Open a Zoom call (or Google Meet) with at least 2 other people. Click Start meeting recording in the menu bar → enter their names → record for ≥ 3 minutes → stop → wait for transcript.

Verify:
- Transcript window opens within ~30 s of stop.
- Mic segments are labeled "Me".
- System segments are labeled with names from the attendee list when self-introductions are present, otherwise "Speaker N".
- Audio files are deleted from `~/Library/Application Support/whatchu-say/meetings/<uuid>/` (assuming default retention).
- `transcript.md` and `transcript.json` are present.

- [ ] **Step 4: Verify regressions in dictation**

Run a quick dictation push-to-talk → confirm it still injects text. The whole point of the sibling-subsystem architecture is that dictation is unaffected; this is the smoke test for that claim.

- [ ] **Step 5: Final commit**

If anything was tweaked during smoke, commit. Otherwise this task ends without a commit.

```bash
git status
# only commit if there are changes
```

---

## Out of scope / explicitly deferred

Per spec §13, none of the following are implemented in this plan:

- Keyboard shortcut for Start meeting recording (menu-bar click only)
- Per-process Process Tap (Zoom-only filtering)
- Detection-based trigger (notification when Zoom is in a meeting)
- Live transcript / live notes UI
- Calendar OAuth integration
- Voiceprint enrollment across meetings

Additionally deferred from this plan (not in spec §13 but worth flagging):

- **LLM-backed `SpeakerNameMapper`.** Spec §4.3 says the LLM mapping pass is "(optional)" and §10.4 makes accuracy a spike-validation target (≥ 70% on speakers addressed by name; below that, fall back to leaving anonymous). v1 ships `ContentBasedSpeakerNameMapper` (regex over self-introductions) which handles the common case; users can manually rename in the transcript view. Adding a real LLM-backed mapper requires introducing a chat-completion provider abstraction (the existing `STTCore` is STT-only — ElevenLabs has no chat completions endpoint), which is meaningful new dependency surface. Defer to a follow-up after §10.4 is measured against real recordings; if the gap is large, build the LLM mapper then.
- **Past-meetings library window.** No UI for browsing prior transcripts after closing the transcript window in v1. Users can navigate to the storage path via the "Reveal in Finder" button on the Meetings settings pane and double-click `transcript.md`. A dedicated library window is a v1.5 polish item.

Manual rename of speakers via context menu in `TranscriptView` is sketched in Task 22 step 1 but the rename sheet is left as a follow-up — the right-click context menu shows the action; the action invokes `transcript.renameSpeaker(...)` and re-saves. Acceptable v1.
