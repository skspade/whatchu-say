import SwiftUI

@main
struct WhatchuSayMacApp: App {
    @State private var appState = AppState()
    @State private var coordinator: AppCoordinator?

    var body: some Scene {
        MenuBarExtra {
            menuContent
        } label: {
            Image(systemName: iconName(for: appState.status))
        }
        .menuBarExtraStyle(.menu)
    }

    @ViewBuilder
    private var menuContent: some View {
        Text(statusLabel(for: appState.status))
        if let last = appState.lastTranscript, !last.isEmpty {
            Divider()
            Text("Last: \(last.prefix(60))").font(.caption)
        }
        if let error = appState.lastError {
            Divider()
            Text("Error: \(error)").font(.caption).foregroundStyle(.red)
        }
        Divider()
        Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
        Color.clear
            .frame(width: 0, height: 0)
            .task { await launchIfNeeded() }
    }

    private func launchIfNeeded() async {
        if coordinator != nil { return }
        guard let apiKey = ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"],
              !apiKey.isEmpty
        else {
            appState.status = .startupFailed("ELEVENLABS_API_KEY env var not set")
            appState.lastError = "Set ELEVENLABS_API_KEY in the scheme's Run → Arguments → Environment Variables."
            return
        }
        let coord = AppCoordinator(apiKey: apiKey, state: appState)
        coordinator = coord
        await coord.start()
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
}
