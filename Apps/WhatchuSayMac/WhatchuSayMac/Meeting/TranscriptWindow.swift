import AppKit
import SwiftUI
import Meeting

@MainActor
final class TranscriptWindow {
    private var window: NSWindow?

    func show(
        session: MeetingSession,
        transcript: MeetingTranscript,
        library: MeetingLibrary,
        mapper: any SpeakerNameMapper
    ) {
        let micExists = (try? FileManager.default.fileExists(
            atPath: library.micFile(for: session.id).path
        )) ?? false

        // The window this call opens. Callbacks use it rather than
        // `self.window`, so a late save from an earlier window can't retitle
        // or close a newer one.
        weak var shownWindow: NSWindow?

        let view = TranscriptView(
            session: session,
            transcript: transcript,
            savedTitle: session.title,
            attendeesText: session.attendees.names.joined(separator: ", "),
            audioStillExists: micExists,
            onAttendeesChanged: { current, newList in
                let mapping = (try? await mapper.map(transcript: current, attendees: newList)) ?? [:]
                var updated = current
                updated.applySpeakerMapping(mapping)
                return updated
            },
            onSave: { edited, editedTranscript in
                do {
                    try library.update(session: edited)
                    try library.writeTranscript(editedTranscript, for: edited.id, title: edited.title)
                } catch {
                    print("[TranscriptWindow] save failed for \(edited.id): \(error)")
                    return false
                }
                shownWindow?.title = edited.title
                return true
            },
            onDeleteTranscript: {
                do {
                    try library.delete(id: session.id)
                } catch {
                    print("[TranscriptWindow] delete failed for \(session.id): \(error)")
                    return
                }
                shownWindow?.close()
            },
            onDeleteAudioNow: {
                do {
                    try library.deleteAudio(for: session.id)
                    return true
                } catch {
                    print("[TranscriptWindow] audio delete failed for \(session.id): \(error)")
                    return false
                }
            }
        )
        let hosting = NSHostingController(rootView: view)
        // One transcript window at a time: close the previous one rather
        // than leave it on screen once its reference is replaced.
        self.window?.close()
        let window = NSWindow(contentViewController: hosting)
        // Owned by `self.window`; AppKit's default release-on-close would
        // over-release it and crash when it's closed and another is shown.
        window.isReleasedWhenClosed = false
        window.title = session.title
        window.setContentSize(NSSize(width: 720, height: 600))
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.makeKeyAndOrderFront(nil)
        shownWindow = window
        self.window = window
    }
}

private struct TranscriptView: View {
    @State var session: MeetingSession
    @State var transcript: MeetingTranscript
    /// Title as last persisted; an empty or failed edit reverts to it.
    @State var savedTitle: String
    @State var attendeesText: String
    @State var audioStillExists: Bool
    /// Returns `transcript` with speakers re-mapped for the new attendees.
    let onAttendeesChanged: (MeetingTranscript, AttendeeList) async -> MeetingTranscript
    /// Persists the session and transcript; false if the write failed.
    let onSave: (MeetingSession, MeetingTranscript) -> Bool
    let onDeleteTranscript: () -> Void
    let onDeleteAudioNow: () -> Bool

    @FocusState private var titleFocused: Bool
    @State private var renamingSpeaker: Speaker?
    @State private var renameText = ""
    @State private var isRenaming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
            Divider()
            attendeesRow
            Divider()
            transcriptList
        }
        .alert("Rename speaker", isPresented: $isRenaming) {
            TextField("Name", text: $renameText)
            Button("Rename") { commitRename() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Renames every line from this speaker.")
        }
    }

    private var headerRow: some View {
        HStack {
            TextField("Title", text: $session.title)
                .textFieldStyle(.plain)
                .font(.title2)
                .focused($titleFocused)
                .onSubmit(commitTitle)
                .onChange(of: titleFocused) { _, focused in
                    if !focused { commitTitle() }
                }
                .onDisappear(perform: commitTitle)
            Spacer()
            if audioStillExists {
                Button("Delete audio") {
                    audioStillExists = !onDeleteAudioNow()
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
    }

    private var attendeesRow: some View {
        HStack {
            Text("Attendees:")
            TextField("Alice, Bob, Carol", text: $attendeesText, onCommit: {
                Task {
                    let attendees = AttendeeList(parsing: attendeesText)
                    let updated = await onAttendeesChanged(transcript, attendees)
                    var edited = session
                    edited.attendees = attendees
                    if onSave(edited, updated) {
                        session = edited
                        transcript = updated
                    }
                }
            })
            .textFieldStyle(.roundedBorder)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var transcriptList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(Array(transcript.segments.enumerated()), id: \.offset) { _, seg in
                    HStack(alignment: .top, spacing: 8) {
                        Text(formatTimestamp(seg.start))
                            .foregroundStyle(.secondary)
                            .font(.caption.monospacedDigit())
                            .frame(width: 50, alignment: .leading)
                        speakerLabel(for: seg.speaker)
                            .frame(width: 100, alignment: .leading)
                            .contextMenu {
                                Button("Rename \u{201C}\(speakerName(seg.speaker))\u{201D}\u{2026}") {
                                    beginRename(seg.speaker)
                                }
                            }
                            .help("Right-click to rename this speaker")
                        Text(seg.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding()
        }
    }

    private func formatTimestamp(_ s: TimeInterval) -> String {
        let total = Int(s)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private func speakerLabel(for speaker: Speaker) -> some View {
        Text(speakerName(speaker)).bold()
    }

    private func speakerName(_ speaker: Speaker) -> String {
        switch speaker {
        case .me: return "Me"
        case .tagged(let n): return n
        case .anonymous(let id): return "Speaker \(id)"
        }
    }

    private func beginRename(_ speaker: Speaker) {
        renamingSpeaker = speaker
        renameText = speakerName(speaker)
        isRenaming = true
    }

    private func commitRename() {
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let speaker = renamingSpeaker, !name.isEmpty else { return }
        var updated = transcript
        updated.renameSpeaker(speaker, to: name)
        if onSave(session, updated) {
            transcript = updated
        }
    }

    /// Persists the title on submit, when the field loses focus, or when the
    /// window closes. Runs for each, so it's a no-op when nothing changed.
    private func commitTitle() {
        let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != savedTitle else {
            session.title = savedTitle
            return
        }
        var edited = session
        edited.title = title
        if onSave(edited, transcript) {
            session = edited
            savedTitle = title
        } else {
            session.title = savedTitle
        }
    }
}
