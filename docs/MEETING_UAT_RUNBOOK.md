# Meeting transcription — UAT Runbook

User Acceptance Testing for the Phase 4 meeting transcription feature. Run this against `/Applications/WhatchuSayMac.app` after `make install` of a fresh Xcode build. Each phase has expected behavior and bug signals — record observations inline.

| Field | Value |
| --- | --- |
| Feature | Meeting transcription (Phase 4) |
| Spec | [`docs/superpowers/specs/2026-05-02-meeting-transcription-design.md`](./superpowers/specs/2026-05-02-meeting-transcription-design.md) |
| Built from | (record git SHA + Xcode build timestamp) |
| Tester | |
| Run date | |

---

## 0. Pre-flight

- [ ] Quit any running `WhatchuSayMac` (menu bar icon → Quit, or `killall WhatchuSayMac`).
- [ ] Confirm fresh build was installed: `stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S' /Applications/WhatchuSayMac.app/Contents/MacOS/WhatchuSayMac` matches today's Xcode build.
- [ ] Launch: `open /Applications/WhatchuSayMac.app`. Menu bar icon appears.
- [ ] Open Settings → check there's no spurious entry in the recent-errors log.

> First launch after the meeting feature lands: the app declares `NSScreenCaptureUsageDescription` in Info.plist but the permission has not been *granted*. The TCC prompt fires the first time you click Start meeting recording.

---

## Phase A — Cosmetic smoke (1 min)

Verify the new UI surfaces are present and look right. No actual recording yet.

- [ ] Click menu bar icon. **"Start meeting recording…"** appears (placement: above existing dictation entries).
- [ ] Open Settings (⌘,). New tab **"Meetings"** with `person.3.sequence` icon is the rightmost tab.
- [ ] Click the Meetings tab. Verify:
  - [ ] Section "Behavior" with two toggles, both ON: *Show attendee field at start*, *Show consent reminder before each recording*
  - [ ] Section "Storage" with toggle (default ON) *Delete recorded audio after transcription*, plus a *Reveal in Finder* button
  - [ ] Section "Permissions" with two rows: Microphone, Screen & System Audio Recording — each with *Open System Settings…* button

**Bug signals:** Tab missing, toggles flipped, layout broken, anything new in recent-errors log.

**Observed:** _____

---

## Phase B — First-time recording + TCC grant (2–3 min)

Establishes the Screen & System Audio Recording permission and verifies the start-modal flow.

- [ ] Menu bar → "Start meeting recording…"
- [ ] Modal appears with:
  - [ ] Title "Start meeting recording"
  - [ ] Consent reminder text (because the toggle is on)
  - [ ] "Attendees (optional)" label + text field
  - [ ] Cancel + Start buttons
- [ ] Type `Alice, Bob` → click **Start**.
- [ ] **macOS prompts** for "Screen & System Audio Recording". Grant via System Settings.
- [ ] **Fully quit the app** (Cmd-Q or menu → Quit). TCC requires a restart for newly-granted Screen Recording.
- [ ] Relaunch: `open /Applications/WhatchuSayMac.app`
- [ ] Repeat: menu → Start → attendees → Start.

**Expected this time:** Modal closes, menu bar item swaps to **"Stop recording (00:01)"** ticking up each second.

**Bug signals:**
- Alert "Could not start recording" — capture error text. Most likely cause: Process Tap creation failed (`MeetingError.systemAudioPermissionDenied(status:)` with the OSStatus code). Could mean TCC not yet effective (try restart) or Process Tap incompatible on this Mac (would require ScreenCaptureKit fallback per spec §10.2).
- No prompt for permission, but recording still fails — Info.plist key may not have been picked up.
- Modal hangs / Start does nothing.

**Observed:** _____

---

## Phase C — Golden-path recording (3 min)

End-to-end happy path: capture, transcribe, render.

- [ ] While menu shows "Stop recording (00:NN)":
  - [ ] Open YouTube, play a ~60-second clip with multiple speakers (panel, podcast, news segment).
  - [ ] Speak into your mic at least once: *"Hi everyone, I'm Sean."*
- [ ] After ~60 seconds, click menu bar → "Stop recording (01:NN)".
- [ ] Menu reverts to "Start meeting recording…" while transcription runs.
- [ ] Wait 10–60s for Scribe v2 to return.
- [ ] Transcript window opens.

Verify the transcript window contains:
- [ ] Editable title (defaults to "Meeting — 2026-05-02 HH:MM")
- [ ] "Audio: deleted" indicator (retention is on, audio cleaned up post-transcription)
- [ ] Trash button (top right)
- [ ] Attendees row showing "Alice, Bob"
- [ ] Chronological list of `[mm:ss] **Speaker:** text` rows
- [ ] Your "I'm Sean" line labeled **Me**
- [ ] YouTube speakers labeled **Speaker 0**, **Speaker 1**, …
- [ ] If a speaker introduced themselves as Alice or Bob, their `Speaker N` label maps to the attendee name (content-based mapper)

**Bug signals:**
- Empty transcript / window doesn't open
- Mic content under a `Speaker N` label instead of `Me`
- Transcript order isn't chronological
- Alert: "Transcription failed" — capture error

**Observed:** _____

---

## Phase D — Transcript features (2 min)

Inside the open transcript window from Phase C.

- [ ] Edit the title field, click outside. Title persists.
- [ ] Modify attendees to `Alice, Bob, Carol` and press Return. Brief delay, transcript re-renders.
- [ ] Verify "Audio: deleted" indicator (retention default keeps audio off-disk after success).
- [ ] Click the trash button. Window closes immediately, no confirmation dialog.
- [ ] Verify on disk: Settings → Meetings → "Reveal in Finder". The deleted meeting's UUID directory is gone.

**Bug signals:** Title doesn't persist, attendees re-edit doesn't trigger a remap, trash leaves files behind.

**Observed:** _____

---

## Phase E — Retention toggle (3 min)

- [ ] Settings → Meetings → toggle OFF *Delete recorded audio after transcription*. Close Settings.
- [ ] Run another short meeting (~30s, repeat Phase C).
- [ ] In the resulting transcript window, the indicator now shows a **"Delete audio"** button (instead of "Audio: deleted").
- [ ] Click "Delete audio". Indicator changes to "Audio: deleted".
- [ ] Reveal in Finder. Meeting directory contains only `meta.json`, `transcript.json`, `transcript.md` — no `.opus` files.
- [ ] Toggle the retention setting back ON.

**Bug signals:** Toggle doesn't change behavior, "Delete audio" button doesn't actually delete.

**Observed:** _____

---

## Phase F — Crash recovery (3 min)

The launch-time recovery flow per spec §9.

For each of the three buttons, repeat these steps:

- [ ] Start a recording (menu → Start → attendees → Start). Wait ~10 seconds.
- [ ] Force-quit the app: `killall -9 WhatchuSayMac`
- [ ] Relaunch: `open /Applications/WhatchuSayMac.app`
- [ ] Modal alert "Recover unfinished meeting?" appears with three buttons.

Verify each button's behavior:

- [ ] **"Try transcribing"** — produces a transcript window from the partial audio. Length depends on how much was captured before the kill.
- [ ] **"Discard"** — meeting directory deleted, no further prompts on subsequent launches.
- [ ] **"Decide later"** — alert dismisses without action; the prompt re-appears on the *next* launch for the same meeting.

**Bug signals:** No prompt appears at launch, prompt repeats per launch even after Discard, "Try transcribing" returns an empty transcript on a recoverable audio file, prompt fires for already-completed meetings.

**Observed:** _____

---

## Phase G — Dictation regression (1 min)

The sibling-subsystem architecture should leave dictation untouched.

- [ ] Use your usual dictation hotkey (push-to-talk).
- [ ] Speak a sentence, release the hotkey.
- [ ] Text injects at cursor as before.
- [ ] Try a slightly longer dictation (~10s of speech) to verify the orchestrator is healthy under sustained use.

**Bug signals:** Hotkey doesn't fire, audio capture fails, text doesn't inject, recent-errors log gets a new entry. Any of these means the sibling boundary leaked.

**Observed:** _____

---

## Phase H — Settings persistence (1 min)

- [ ] In Settings → Meetings, flip all three toggles to non-default values.
- [ ] Quit the app fully, relaunch.
- [ ] Re-open Settings → Meetings. Toggles should still be at the values you set.
- [ ] Restore defaults (all three ON).

**Bug signals:** Toggles reset to defaults on relaunch — would mean the schema-v2 migration handler isn't correctly persisting `MeetingsConfig`.

**Observed:** _____

---

## Phase I — Optional: deeper checks

These aren't required for sign-off but catch edge cases:

- [ ] **Empty attendees:** Run a meeting with no attendees entered. Verify all speakers stay as `Speaker N` (no LLM mapping attempted, no errors).
- [ ] **Skip the consent modal field:** Toggle off *Show attendee field at start*. Run a meeting. Modal should not show the attendees field; recording starts and behaves identically.
- [ ] **Skip both toggles:** Toggle off both *Show attendee field at start* and *Show consent reminder*. Modal should be near-empty (just Cancel + Start). Recording works.
- [ ] **Manual rename in transcript:** Right-click a `Speaker N` label in the transcript window. (Note: per the plan, the rename sheet is sketched but the right-click-to-rename UX may be incomplete — accept partial behavior here for v1.)

**Observed:** _____

---

## Sign-off

- [ ] All required phases (A–H) pass with no blocking bugs
- [ ] Any non-blocking observations are filed
- [ ] Branch ready to call done; close the loop on `feat/meeting-transcription` (already merged to main)

If anything failed, capture:
1. The exact phase + step
2. Error text (alerts, recent-errors log)
3. The transcript directory contents at `~/Library/Application Support/whatchu-say/meetings/<uuid>/`
4. The Xcode console log if reproducible

---

## Quick reference

```bash
# Launch
open /Applications/WhatchuSayMac.app

# Force quit
killall -9 WhatchuSayMac

# Storage location
open ~/Library/Application\ Support/whatchu-say/meetings/

# Verify installed binary timestamp
stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S' \
  /Applications/WhatchuSayMac.app/Contents/MacOS/WhatchuSayMac

# Reset TCC for re-testing first-time prompts (requires admin)
tccutil reset ScreenCapture s900mhz.WhatchuSayMac
tccutil reset Microphone    s900mhz.WhatchuSayMac
```
