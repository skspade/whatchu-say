import SwiftUI
import AppKit

@main
struct WhatchuSayMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(state: appDelegate.state)
        } label: {
            MenuBarLabelView(state: appDelegate.state)
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()
    private var coordinator: AppCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("[WhatchuSay] applicationDidFinishLaunching")
        Task { @MainActor in
            await self.launch()
        }
    }

    private func launch() async {
        guard coordinator == nil else { return }
        guard let apiKey = ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"],
              !apiKey.isEmpty
        else {
            print("[WhatchuSay] ELEVENLABS_API_KEY missing; not starting")
            state.status = .startupFailed("ELEVENLABS_API_KEY env var not set")
            state.lastError = "Set ELEVENLABS_API_KEY in the scheme's Run → Arguments → Environment Variables."
            return
        }
        print("[WhatchuSay] launching coordinator")
        let coord = AppCoordinator(apiKey: apiKey, state: state)
        coordinator = coord
        await coord.start()
        print("[WhatchuSay] coordinator started; awaiting hotkey events")
    }
}

private struct MenuBarLabelView: View {
    let state: AppState
    var body: some View {
        Image(systemName: iconName(for: state.status))
    }
}

private struct MenuContentView: View {
    let state: AppState
    var body: some View {
        Text(statusLabel(for: state.status))
        if let last = state.lastTranscript, !last.isEmpty {
            Divider()
            Text("Last: \(last.prefix(60))").font(.caption)
        }
        if let error = state.lastError {
            Divider()
            Text("Error: \(error)").font(.caption).foregroundStyle(.red)
        }
        Divider()
        Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

private func iconName(for status: AppState.Status) -> String {
    switch status {
    case .idle:           return "mic.slash"
    case .listening:      return "mic.fill"
    case .startupFailed:  return "exclamationmark.triangle.fill"
    }
}

private func statusLabel(for status: AppState.Status) -> String {
    switch status {
    case .idle:                       return "Idle"
    case .listening:                  return "Listening…"
    case .startupFailed(let message): return "Startup failed: \(message)"
    }
}
