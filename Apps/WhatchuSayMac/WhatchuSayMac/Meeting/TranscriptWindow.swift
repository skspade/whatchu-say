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

        let view = TranscriptView(
            session: session,
            transcript: transcript,
            attendeesText: session.attendees.names.joined(separator: ", "),
            audioStillExists: micExists,
            onAttendeesChanged: { [weak self] newList in
                let mapping = (try? await mapper.map(transcript: transcript, attendees: newList)) ?? [:]
                var updated = transcript
                updated.applySpeakerMapping(mapping)
                try? library.writeTranscript(updated, for: session.id, title: session.title)
                _ = self  // keep window alive while async runs
                return updated
            },
            onRename: { [weak self] from, to in
                var updated = transcript
                updated.renameSpeaker(from, to: to)
                try? library.writeTranscript(updated, for: session.id, title: session.title)
                _ = self
            },
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
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }
}

private struct TranscriptView: View {
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
            headerRow
            Divider()
            attendeesRow
            Divider()
            transcriptList
        }
    }

    private var headerRow: some View {
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
    }

    private var attendeesRow: some View {
        HStack {
            Text("Attendees:")
            TextField("Alice, Bob, Carol", text: $attendeesText, onCommit: {
                Task {
                    let updated = await onAttendeesChanged(AttendeeList(parsing: attendeesText))
                    transcript = updated
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
