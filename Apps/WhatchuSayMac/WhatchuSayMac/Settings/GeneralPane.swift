import SwiftUI
import AppKit
import Core

struct GeneralPane: View {
    let store: ConfigStore

    @State private var showingResetAlert = false

    var body: some View {
        Form {
            Section("Startup") {
                Toggle(
                    "Launch at Login",
                    isOn: store.binding(for: \.startup.launchAtLogin) { newValue in
                        LaunchAtLogin.setEnabled(newValue)
                    }
                )
            }

            Section("Floating Overlay") {
                Toggle("Show overlay while dictating", isOn: store.binding(for: \.overlay.enabled))

                Picker("Anchor", selection: store.binding(for: \.overlay.anchor)) {
                    Text("Near cursor").tag(OverlayAnchor.nearCursor)
                    Text("Bottom of screen").tag(OverlayAnchor.screenBottom)
                }
                .disabled(!store.config.overlay.enabled)

                if store.config.overlay.anchor == .screenBottom {
                    ScreenAnchorPicker(store: store)
                        .disabled(!store.config.overlay.enabled)
                }
            }

            Section("Menubar") {
                Picker("Usage indicator", selection: store.binding(for: \.usage.menubarIndicator)) {
                    Text("Off").tag(MenubarIndicator.off)
                    Text("Minutes").tag(MenubarIndicator.minutes)
                    Text("Cost").tag(MenubarIndicator.cost)
                }
                .pickerStyle(.segmented)

                Text("Usage chart and monthly totals arrive in v1.5.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Spacer()
                    Button(role: .destructive) {
                        showingResetAlert = true
                    } label: {
                        Text("Reset to Defaults…")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .alert("Reset all settings to defaults?", isPresented: $showingResetAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Reset", role: .destructive, action: performReset)
        } message: {
            Text("Provider, hotkey, output, history, overlay, and startup settings revert to their initial values. Your API key and privacy acknowledgment are preserved. Some changes take effect on the next coordinator restart (e.g. after saving a new API key) or relaunch.")
        }
    }

    /// Replace the persisted config with `AppConfig()` defaults, but
    /// preserve the privacy acknowledgment so the first-run modal doesn't
    /// re-prompt. The API key lives in Keychain — untouched by this reset.
    private func performReset() {
        let preservedPrivacy = store.config.privacy
        store.update { config in
            config = AppConfig()
            config.privacy = preservedPrivacy
        }
        // Persist immediately so a crash before the next debounce tick
        // doesn't leave the user mid-reset.
        store.flush()
    }
}

/// Picker for the screen the overlay should anchor against when
/// `OverlayAnchor.screenBottom` is selected. "Active screen" leaves
/// `screenAnchorScreen == nil` so the overlay picks the active screen at
/// session start.
private struct ScreenAnchorPicker: View {
    let store: ConfigStore

    var body: some View {
        Picker("Screen", selection: screenBinding) {
            Text("Active screen at start").tag(String?.none)
            ForEach(NSScreen.screens, id: \.identifier) { screen in
                Text(screen.localizedDisplayName).tag(Optional(screen.identifier))
            }
        }
    }

    private var screenBinding: Binding<String?> {
        store.binding(for: \.overlay.screenAnchorScreen)
    }
}

private extension NSScreen {
    /// Stable per-screen identifier suitable for persistence. Mirrors the
    /// `displayUUID` slot in `OverlayConfig.screenAnchorScreen`.
    var identifier: String {
        let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return number.map { "screen-\($0.uint32Value)" } ?? "screen-unknown"
    }

    /// Best-effort display name. macOS 14+ ships `localizedName` directly.
    var localizedDisplayName: String { localizedName }
}
