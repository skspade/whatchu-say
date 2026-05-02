import SwiftUI
import AppKit
import Core
import Meeting

struct MeetingsPane: View {
    let store: ConfigStore

    @State private var showAttendeeFieldAtStart: Bool
    @State private var showConsentReminder: Bool
    @State private var deleteAudioAfterTranscription: Bool

    init(store: ConfigStore) {
        self.store = store
        let m = store.config.meetings
        _showAttendeeFieldAtStart = State(initialValue: m.showAttendeeFieldAtStart)
        _showConsentReminder = State(initialValue: m.showConsentReminder)
        _deleteAudioAfterTranscription = State(initialValue: m.deleteAudioAfterTranscription)
    }

    var body: some View {
        Form {
            Section("Behavior") {
                Toggle("Show attendee field at start", isOn: $showAttendeeFieldAtStart)
                    .onChange(of: showAttendeeFieldAtStart) { _, newValue in
                        store.update { $0.meetings.showAttendeeFieldAtStart = newValue }
                    }
                Toggle("Show consent reminder before each recording", isOn: $showConsentReminder)
                    .onChange(of: showConsentReminder) { _, newValue in
                        store.update { $0.meetings.showConsentReminder = newValue }
                    }
            }

            Section("Storage") {
                Toggle("Delete recorded audio after transcription", isOn: $deleteAudioAfterTranscription)
                    .onChange(of: deleteAudioAfterTranscription) { _, newValue in
                        store.update { $0.meetings.deleteAudioAfterTranscription = newValue }
                    }
                HStack {
                    Text("Storage location:")
                    Spacer()
                    Button("Reveal in Finder") { revealInFinder() }
                }
            }

            Section("Permissions") {
                LabeledContent("Microphone") {
                    Button("Open System Settings…") {
                        PermissionLauncher.open(.microphone)
                    }
                }
                LabeledContent("Screen & System Audio Recording") {
                    Button("Open System Settings…") {
                        PermissionLauncher.open(.screenAndSystemAudioRecording)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func revealInFinder() {
        guard let url = try? MeetingLibrary.defaultRoot() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
