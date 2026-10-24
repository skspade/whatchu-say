import SwiftUI
import AppKit
import Core
import PlatformApple

@main
struct WhatchuSayMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// SwiftUI's `App` requires a `Scene`. The Settings scene satisfies that
    /// requirement without creating a visible window on launch. The actual
    /// settings window is managed by AppDelegate via NSHostingController
    /// because agent apps (LSUIElement) can't use `showSettingsWindow:` on
    /// modern macOS — the system requires SettingsLink / OpenSettingsAction,
    /// neither of which is available from AppKit menu actions.
    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()
    let recentTranscripts = RecentTranscriptsStore()
    let errorLog = ErrorLogStore()
    let configStore = ConfigStore()
    lazy var apiKeys: APIKeyController = APIKeyController(
        keychain: keychain,
        providerName: provider,
        onKeySaved: { [weak self] newKey in
            await self?.bringUpCoordinator(apiKey: newKey)
        }
    )
    private let keychain = KeychainAPIKeyStore()
    private let provider = "elevenlabs"
    private var coordinator: AppCoordinator?
    private var statusItemController: StatusItemController?
    private var settingsWindow: NSWindow?
    private var currentKey: String?
    /// The most recent coordinator rebuild. Each rebuild waits for the one
    /// before it, so overlapping key saves (menu prompt + Provider pane)
    /// can't interleave across their awaits and leave two live coordinators.
    private var coordinatorRebuild: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("[WhatchuSay] applicationDidFinishLaunching")
        installStatusItem()
        guard runFirstRunDisclosureIfNeeded() else { return }
        Task { @MainActor in
            await self.bootstrap()
        }
    }

    /// Present the privacy disclosure modally when the user has not yet
    /// acknowledged it. Blocks bootstrap until the user picks an outcome.
    /// Returns `true` if launch should proceed; `false` if the app is
    /// terminating (after a flush) and the caller should bail out.
    private func runFirstRunDisclosureIfNeeded() -> Bool {
        guard !configStore.config.privacy.hasReadDisclosure else { return true }

        let providerInfo = ProviderRegistry.info(for: configStore.config.provider.providerName)
        let outcome = FirstRunDisclosure.presentBlocking(providerInfo: providerInfo)

        switch outcome {
        case .acknowledged:
            configStore.update {
                $0.privacy.hasReadDisclosure = true
                $0.privacy.disclosureAcknowledgedAt = Date()
            }
            // Persist immediately so a crash before the next debounce tick
            // doesn't lose the acknowledgment and re-prompt on next launch.
            configStore.flush()
            return true
        case .quit:
            configStore.flush()
            NSApp.terminate(nil)
            return false
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        recentTranscripts.flushPendingWrites()
        errorLog.flushPendingWrites()
        configStore.flush()
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

    /// Open the settings window. Agent apps (`LSUIElement = YES`) can't use
    /// SwiftUI's `showSettingsWindow:` selector on modern macOS (the system
    /// requires `SettingsLink` / `OpenSettingsAction`, which aren't available
    /// from AppKit menu actions). We host `SettingsView` in our own NSWindow
    /// via NSHostingController instead.
    func runOpenSettings() {
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSRunningApplication.current.activate(options: .activateAllWindows)
            return
        }
        let controller = NSHostingController(
            rootView: SettingsView(store: configStore, apiKeys: apiKeys)
        )
        let window = NSWindow(contentViewController: controller)
        window.title = "WhatchuSay Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSRunningApplication.current.activate(options: .activateAllWindows)
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
                onOpenPermission: PermissionLauncher.open,
                onOpenSettings: { [weak self] in self?.runOpenSettings() }
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
        // Hydrate APIKeyController so the Provider pane shows the saved-key
        // suffix the first time the Settings window opens (otherwise it
        // would render "(none)" until the user types).
        await apiKeys.loadInitial()

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

    /// Show the API-key prompt and, on save, persist via `apiKeys.save(...)`
    /// — which writes to Keychain and triggers the coordinator restart via
    /// the `onKeySaved` callback. Routed from the menu item; the Provider
    /// pane drives the same `apiKeys.save(...)` call.
    func runSetKeyFlow() {
        let suffix = currentKey.flatMap(APIKeyPrompt.suffix(of:))
        let config = currentKey == nil
            ? APIKeyPrompt.setKey()
            : APIKeyPrompt.updateKey(currentSuffix: suffix)
        guard let newKey = APIKeyPrompt.show(config) else { return }

        Task { @MainActor in
            do {
                try await apiKeys.save(newKey)
            } catch {
                let message = String(describing: error)
                errorLog.record(text: "Keychain write failed: \(message)")
                presentError("Could not save API key", message: message)
            }
        }
    }

    // MARK: - Coordinator lifecycle

    private func bringUpCoordinator(apiKey: String) async {
        let previous = coordinatorRebuild
        let rebuild = Task { @MainActor in
            await previous?.value
            await self.rebuildCoordinator(apiKey: apiKey)
        }
        coordinatorRebuild = rebuild
        await rebuild.value
    }

    private func rebuildCoordinator(apiKey: String) async {
        // A meeting that's recording survives the rebuild: a fresh
        // MeetingsCoordinator would drop its Stop item and taps, and its
        // launch-recovery prompt would offer to discard the live session.
        var carriedMeetings: MeetingsCoordinator?
        if let existing = coordinator {
            if existing.meetingsCoordinator?.isRecording == true {
                carriedMeetings = existing.meetingsCoordinator
            }
            await existing.shutdown()
            coordinator = nil
            statusItemController?.meetingsCoordinator = nil
        }
        currentKey = apiKey
        let coord = AppCoordinator(
            apiKey: apiKey,
            state: state,
            configStore: configStore,
            recentTranscripts: recentTranscripts,
            errorLog: errorLog,
            reusingMeetings: carriedMeetings
        )
        coordinator = coord
        statusItemController?.meetingsCoordinator = coord.meetingsCoordinator
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
            // Surface in the error log the user actually checks — a silent
            // print here is why a revoked-signature keychain failure looked
            // like "no key" with no explanation. The raw OSStatus lands in
            // the log; the entry itself is left intact (a denied prompt or
            // locked keychain is recoverable), and saving the key again
            // clears an entry tied to a dead signature.
            errorLog.record(text: "Keychain read failed: \(error)")
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
