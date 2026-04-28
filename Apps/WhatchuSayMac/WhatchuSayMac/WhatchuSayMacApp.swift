import SwiftUI
import AppKit
import PlatformApple

@main
struct WhatchuSayMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(
                state: appDelegate.state,
                recentTranscripts: appDelegate.recentTranscripts,
                onSetKey: appDelegate.runSetKeyFlow,
                onCopyTranscript: AppCoordinator.copyToPasteboard,
                onClearTranscripts: appDelegate.runClearRecentTranscripts
            )
        } label: {
            MenuBarLabelView(state: appDelegate.state)
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()
    let recentTranscripts = RecentTranscriptsStore()
    private let keychain = KeychainAPIKeyStore()
    private let provider = "elevenlabs"
    private var coordinator: AppCoordinator?
    private var currentKey: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("[WhatchuSay] applicationDidFinishLaunching")
        Task { @MainActor in
            await self.bootstrap()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        recentTranscripts.flushPendingWrites()
    }

    /// Resolve an API key from Keychain (preferred) or the env var
    /// (development fallback), then bring up the coordinator. If neither
    /// source has a key, land in `.needsSetup` and wait for the user to set
    /// one via the menu.
    private func bootstrap() async {
        guard coordinator == nil else { return }

        await recentTranscripts.load()

        let stored = await readStoredKey()
        let envKey = ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"]?.nonEmpty
        guard let apiKey = stored ?? envKey else {
            print("[WhatchuSay] no API key found; entering needsSetup")
            state.status = .needsSetup
            state.lastError = nil
            return
        }
        await bringUpCoordinator(apiKey: apiKey)
    }

    /// Show a confirm alert; on accept, wipe the recent-transcripts buffer
    /// from memory and disk. Routed from the menu item.
    func runClearRecentTranscripts() {
        let alert = NSAlert()
        alert.messageText = "Clear all recent transcripts?"
        alert.informativeText = "This deletes the local list of your recent dictation transcripts. The action can't be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        recentTranscripts.clear()
    }

    /// Show the API-key prompt and, on save, write to Keychain and restart
    /// the coordinator. Routed from the menu item.
    func runSetKeyFlow() {
        let suffix = currentKey.flatMap(APIKeyPrompt.suffix(of:))
        let config = currentKey == nil
            ? APIKeyPrompt.setKey()
            : APIKeyPrompt.updateKey(currentSuffix: suffix)
        guard let newKey = APIKeyPrompt.show(config) else { return }

        Task { @MainActor in
            do {
                try await keychain.write(provider: provider, key: newKey)
            } catch {
                presentError("Could not save API key", message: String(describing: error))
                return
            }
            await bringUpCoordinator(apiKey: newKey)
        }
    }

    // MARK: - Coordinator lifecycle

    private func bringUpCoordinator(apiKey: String) async {
        if let existing = coordinator {
            await existing.shutdown()
            coordinator = nil
        }
        currentKey = apiKey
        let coord = AppCoordinator(apiKey: apiKey, state: state, recentTranscripts: recentTranscripts)
        coordinator = coord
        // Optimistically clear prior errors; AppCoordinator.start() will
        // overwrite to .startupFailed if hotkey tap install fails.
        state.lastError = nil
        if state.status == .needsSetup { state.status = .idle }
        await coord.start()
        print("[WhatchuSay] coordinator started; awaiting hotkey events")
    }

    private func readStoredKey() async -> String? {
        do {
            return try await keychain.read(provider: provider)?.nonEmpty
        } catch {
            print("[WhatchuSay] keychain read failed: \(error)")
            return nil
        }
    }

    private func presentError(_ title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: - Menu views

private struct MenuBarLabelView: View {
    let state: AppState
    var body: some View {
        Image(systemName: iconName(for: state.status))
            .foregroundStyle(iconTint(for: state.status))
    }
}

private struct MenuContentView: View {
    let state: AppState
    let recentTranscripts: RecentTranscriptsStore
    let onSetKey: () -> Void
    let onCopyTranscript: (TranscriptEntry) -> Void
    let onClearTranscripts: () -> Void

    var body: some View {
        Text(statusLabel(for: state.status))
        Divider()
        Button(setKeyMenuTitle(for: state.status)) { onSetKey() }
        Divider()
        RecentTranscriptsMenu(
            entries: recentTranscripts.entries,
            onCopy: onCopyTranscript,
            onClear: onClearTranscripts
        )
        if let error = state.lastError {
            Divider()
            Text("Error: \(error)").font(.caption).foregroundStyle(.red)
        }
        Divider()
        Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

// MARK: - Status display helpers

private func iconName(for status: AppState.Status) -> String {
    switch status {
    case .idle:           return "mic.slash"
    case .listening:      return "mic.fill"
    case .needsSetup:     return "key.fill"
    case .startupFailed:  return "exclamationmark.triangle.fill"
    }
}

private func iconTint(for status: AppState.Status) -> Color {
    switch status {
    case .needsSetup, .startupFailed: return .yellow
    default:                          return .primary
    }
}

private func statusLabel(for status: AppState.Status) -> String {
    switch status {
    case .idle:                       return "Idle"
    case .listening:                  return "Listening…"
    case .needsSetup:                 return "Set your ElevenLabs API key to begin"
    case .startupFailed(let message): return "Startup failed: \(message)"
    }
}

private func setKeyMenuTitle(for status: AppState.Status) -> String {
    switch status {
    case .needsSetup: return "Set ElevenLabs API Key…"
    default:          return "Update API Key…"
    }
}

// MARK: - String

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
