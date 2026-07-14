import SwiftUI
import Core

/// Root SwiftUI Settings window. TabView with one toolbar tab per pane.
///
/// Each pane is a placeholder until its content lands in subsequent steps of
/// `docs/PLAN_SETTINGS.md` §6 (steps 5–10). The scaffold's purpose is to
/// shake out the window lifecycle, the menubar wiring, and the
/// `ConfigStore` injection path before any field-level binding work.
struct SettingsView: View {
    let store: ConfigStore
    let apiKeys: APIKeyController
    let applyProviderConfiguration: () async -> Void

    var body: some View {
        TabView {
            GeneralPane(store: store)
                .tabItem { Label("General", systemImage: "gearshape") }
            ProviderPane(
                store: store,
                apiKeys: apiKeys,
                applyProviderConfiguration: applyProviderConfiguration
            )
                .tabItem { Label("Provider", systemImage: "cloud") }
            ShortcutsPane(store: store)
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
            OutputPane(store: store)
                .tabItem { Label("Output", systemImage: "text.cursor") }
            HistoryPane(store: store)
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
            PrivacyPane(store: store)
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
            MeetingsPane(store: store)
                .tabItem { Label("Meetings", systemImage: "person.3.sequence") }
        }
        .frame(minWidth: 520, minHeight: 360)
        .padding()
    }
}
