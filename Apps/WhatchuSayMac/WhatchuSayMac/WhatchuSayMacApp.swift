import SwiftUI
import AppKit
import PlatformApple

@main
struct WhatchuSayMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// SwiftUI's `App` requires a `Scene`; with `LSUIElement = YES` and an
    /// AppKit-owned `NSStatusItem`, we have nothing to put in a window. An
    /// empty `Settings` scene satisfies the type system without ever being
    /// presented (no Settings menu in agent apps).
    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()
    let recentTranscripts = RecentTranscriptsStore()
    let errorLog = ErrorLogStore()
    private let keychain = KeychainAPIKeyStore()
    private let provider = "elevenlabs"
    private var coordinator: AppCoordinator?
    private var statusItemController: StatusItemController?
    private var currentKey: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("[WhatchuSay] applicationDidFinishLaunching")
        installStatusItem()
        Task { @MainActor in
            await self.bootstrap()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        recentTranscripts.flushPendingWrites()
        errorLog.flushPendingWrites()
        statusItemController?.uninstall()
    }

    /// Manually clear the persistent error indicator (yellow menubar icon
    /// + "Error: …" line). Routed from the menu when the user knows about
    /// the error and wants the icon clean without proving recovery via a
    /// successful dictation. Also clears any paired permission issue so
    /// the fix-it deep-link button disappears alongside the error.
    func dismissLastError() {
        state.lastError = nil
        state.permissionIssue = nil
    }

    /// Build and install the menu-bar status item synchronously so the
    /// icon is visible immediately — even before `bootstrap()` finishes
    /// reading the keychain or hydrating the stores. The menu rebuilds on
    /// every open via `NSMenuDelegate`, so it will reflect fresh state as
    /// soon as bootstrap completes.
    private func installStatusItem() {
        let controller = StatusItemController(
            state: state,
            recentTranscripts: recentTranscripts,
            errorLog: errorLog,
            handlers: StatusItemController.Handlers(
                onSetKey: { [weak self] in self?.runSetKeyFlow() },
                onCopyTranscript: AppCoordinator.copyToPasteboard,
                onClearTranscripts: { [weak self] in self?.runClearRecentTranscripts() },
                onCopyErrorEntry: AppCoordinator.copyToPasteboard,
                onClearErrorLog: { [weak self] in self?.runClearErrorLog() },
                onDismissError: { [weak self] in self?.dismissLastError() },
                onOpenPermission: PermissionLauncher.open
            )
        )
        controller.install()
        statusItemController = controller
    }

    /// Resolve an API key from Keychain (preferred) or the env var
    /// (development fallback), then bring up the coordinator. If neither
    /// source has a key, land in `.needsSetup` and wait for the user to set
    /// one via the menu.
    private func bootstrap() async {
        guard coordinator == nil else { return }

        await recentTranscripts.load()
        await errorLog.load()

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

    /// Show a confirm alert; on accept, wipe the error-log buffer from
    /// memory and disk.
    func runClearErrorLog() {
        let alert = NSAlert()
        alert.messageText = "Clear all recent errors?"
        alert.informativeText = "This deletes the local error log. The action can't be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        errorLog.clear()
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
                let message = String(describing: error)
                errorLog.record(text: "Keychain write failed: \(message)")
                presentError("Could not save API key", message: message)
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
        let coord = AppCoordinator(
            apiKey: apiKey,
            state: state,
            recentTranscripts: recentTranscripts,
            errorLog: errorLog
        )
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

// MARK: - String

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
