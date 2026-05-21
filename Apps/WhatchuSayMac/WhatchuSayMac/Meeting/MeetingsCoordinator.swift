import Foundation
import AppKit
import Core
import Meeting
import STTCore
import STTElevenLabs

/// Owns the singleton `MeetingOrchestrator` and the windows it drives.
/// Constructed by `AppCoordinator`; lives for the lifetime of the app.
///
/// Keeps the dictation orchestrator untouched — meeting flow runs entirely
/// through this coordinator and its dependencies.
@MainActor
@Observable
final class MeetingsCoordinator {
    private let orchestrator: MeetingOrchestrator
    private let library: MeetingLibrary
    private let configStore: ConfigStore
    private let transcriptWindow = TranscriptWindow()
    private var elapsedTimer: Timer?

    /// Mutated on the main actor; observed by the menu bar to swap
    /// "Start meeting recording" for "Stop recording (00:42)" while a
    /// session is live.
    var isRecording: Bool = false
    var elapsedSeconds: Int = 0
    var recordingMeetingID: UUID?

    init(apiKey: String, configStore: ConfigStore) throws {
        guard #available(macOS 15, *) else {
            throw MeetingError.captureSetupFailed("macOS 15+ required for meeting transcription")
        }
        let library = try MeetingLibrary(rootDirectory: MeetingLibrary.defaultRoot())
        let provider = ElevenLabsProvider(
            apiKey: apiKey,
            noVerbatim: configStore.config.provider.noVerbatim
        )
        guard let transcriber = provider.batchTranscriber else {
            throw MeetingError.captureSetupFailed("provider has no batch transcriber")
        }
        self.library = library
        self.configStore = configStore
        self.orchestrator = MeetingOrchestrator(
            library: library,
            micRecorderFactory: { url in MicCapture(outputURL: url) },
            systemRecorderFactory: { url in SystemAudioCapture(outputURL: url) },
            transcriber: transcriber,
            mapper: ContentBasedSpeakerNameMapper()
        )

        Task { @MainActor in
            await self.runRecoveryPromptIfNeeded()
        }
    }

    @objc func startMeetingMenuAction(_ sender: NSMenuItem) {
        let panel = StartMeetingPanel(
            showConsentReminder: configStore.config.meetings.showConsentReminder,
            showAttendeeField: configStore.config.meetings.showAttendeeFieldAtStart,
            onStart: { [weak self] list in
                Task { @MainActor in await self?.beginRecording(attendees: list) }
            },
            onCancel: {}
        )
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func stopMeetingMenuAction(_ sender: NSMenuItem) {
        Task { @MainActor in await self.endRecording() }
    }

    private func beginRecording(attendees: AttendeeList) async {
        do {
            let id = try await orchestrator.start(
                attendees: attendees,
                keepAudio: !configStore.config.meetings.deleteAudioAfterTranscription
            )
            isRecording = true
            elapsedSeconds = 0
            recordingMeetingID = id
            startTimer()
        } catch {
            presentError("Could not start recording", error)
        }
    }

    private func endRecording() async {
        stopTimer()
        let id = recordingMeetingID
        isRecording = false
        recordingMeetingID = nil
        do {
            try await orchestrator.stop()
            if let id { showTranscript(for: id) }
        } catch {
            presentError("Transcription failed", error)
        }
    }

    private func startTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.elapsedSeconds += 1 }
        }
    }

    private func stopTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    private func showTranscript(for id: UUID) {
        do {
            let session = try library.load(id: id)
            let dir = try library.directory(for: id)
            let json = try Data(contentsOf: dir.appendingPathComponent("transcript.json"))
            let transcript = try JSONDecoder().decode(MeetingTranscript.self, from: json)
            transcriptWindow.show(
                session: session,
                transcript: transcript,
                library: library,
                mapper: ContentBasedSpeakerNameMapper()
            )
        } catch {
            presentError("Could not load transcript", error)
        }
    }

    private func runRecoveryPromptIfNeeded() async {
        let incomplete: [MeetingSession]
        do {
            incomplete = try library.findIncomplete()
        } catch {
            return
        }
        guard !incomplete.isEmpty else { return }
        for session in incomplete {
            switch RecoveryPrompt.present(for: session) {
            case .recover:
                do {
                    try await orchestrator.recover(id: session.id)
                    showTranscript(for: session.id)
                } catch {
                    presentError("Could not transcribe \(session.title)", error)
                }
            case .discard:
                try? library.delete(id: session.id)
            case .later:
                continue
            }
        }
    }

    private func presentError(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = String(describing: error)
        alert.alertStyle = .warning
        alert.runModal()
    }
}
