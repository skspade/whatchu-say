import SwiftUI
import AppKit
import Core

struct OutputPane: View {
    let store: ConfigStore

    @State private var showingAddSheet = false

    var body: some View {
        Form {
            Section("Default strategy") {
                Picker("Strategy", selection: store.binding(for: \.injection.defaultStrategy)) {
                    Text("Auto").tag(InjectionStrategy.auto)
                    Text("Always paste").tag(InjectionStrategy.paste)
                    Text("Always type").tag(InjectionStrategy.type)
                }
                .pickerStyle(.segmented)

                Stepper(
                    value: typeMaxCharsBinding,
                    in: 0...64,
                    step: 1
                ) {
                    LabeledContent("Type up to", value: "\(store.config.injection.typeMaxCharsForAuto) chars")
                }
                .disabled(store.config.injection.defaultStrategy != .auto)

                Toggle(
                    "Leave injected text on clipboard (don't restore)",
                    isOn: store.binding(for: \.injection.leaveOnClipboard)
                )
            }

            Section("Per-app overrides") {
                let entries = sortedOverrideEntries
                if entries.isEmpty {
                    Text("No per-app overrides. Use \"Add from running apps…\" to set a strategy for a specific app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(entries, id: \.bundleID) { entry in
                        OverrideRow(
                            entry: entry,
                            strategyBinding: strategyBinding(for: entry.bundleID),
                            onDelete: { removeOverride(entry.bundleID) }
                        )
                    }
                }

                Button("Add from running apps…") {
                    showingAddSheet = true
                }
            }

            Section {
                Text("Output settings take effect on the next coordinator restart — saving a new API key is the easiest trigger.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .sheet(isPresented: $showingAddSheet) {
            RunningAppPicker(
                existingBundleIDs: Set(store.config.injection.perAppOverrides.keys),
                onPick: { bundleID in
                    addOverride(bundleID, strategy: .paste)
                }
            )
        }
    }

    // MARK: - Derived state

    /// Sort overrides by display name for stable rendering. The
    /// `AppMetadata` lookup is cached implicitly by the OS — repeated calls
    /// for the same bundle ID are cheap.
    private var sortedOverrideEntries: [AppMetadata] {
        store.config.injection.perAppOverrides.keys
            .map(AppMetadata.init(bundleID:))
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    // MARK: - Bindings

    private var typeMaxCharsBinding: Binding<Int> {
        Binding(
            get: { Int(store.config.injection.typeMaxCharsForAuto) },
            set: { newValue in
                store.update { $0.injection.typeMaxCharsForAuto = UInt32(max(0, newValue)) }
            }
        )
    }

    private func strategyBinding(for bundleID: String) -> Binding<InjectionStrategy> {
        Binding(
            get: { store.config.injection.perAppOverrides[bundleID] ?? .auto },
            set: { newValue in
                store.update { $0.injection.perAppOverrides[bundleID] = newValue }
            }
        )
    }

    // MARK: - Actions

    private func addOverride(_ bundleID: String, strategy: InjectionStrategy) {
        store.update { $0.injection.perAppOverrides[bundleID] = strategy }
    }

    private func removeOverride(_ bundleID: String) {
        store.update { $0.injection.perAppOverrides.removeValue(forKey: bundleID) }
    }
}

// MARK: - Override row

private struct OverrideRow: View {
    let entry: AppMetadata
    let strategyBinding: Binding<InjectionStrategy>
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let icon = entry.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 20, height: 20)
            } else {
                Image(systemName: "app.dashed")
                    .frame(width: 20, height: 20)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(entry.displayName)
                Text(entry.bundleID)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: strategyBinding) {
                Text("Auto").tag(InjectionStrategy.auto)
                Text("Paste").tag(InjectionStrategy.paste)
                Text("Type").tag(InjectionStrategy.type)
            }
            .labelsHidden()
            .frame(width: 110)
            Button(action: onDelete) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove override")
        }
    }
}

// MARK: - App picker sheet

/// Presents currently-running regular apps for the user to pick. Apps that
/// already have an override are filtered out so the user can't add a
/// duplicate.
private struct RunningAppPicker: View {
    let existingBundleIDs: Set<String>
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Add app override")
                    .font(.headline)
                Spacer()
                Button("Cancel", action: { dismiss() })
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            List(apps, id: \.bundleIdentifier) { app in
                Button {
                    if let bundleID = app.bundleIdentifier {
                        onPick(bundleID)
                        dismiss()
                    }
                } label: {
                    HStack(spacing: 8) {
                        if let icon = app.icon {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 24, height: 24)
                        }
                        VStack(alignment: .leading, spacing: 0) {
                            Text(app.localizedName ?? app.bundleIdentifier ?? "—")
                            if let bundleID = app.bundleIdentifier {
                                Text(bundleID)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 420, height: 480)
    }

    /// Regular-policy apps with a bundle ID, alphabetised, minus any that
    /// already have an override.
    private var apps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { app in
                guard app.activationPolicy == .regular,
                      let bundleID = app.bundleIdentifier else { return false }
                return !existingBundleIDs.contains(bundleID)
            }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }
}

// MARK: - Bundle metadata lookup

/// Resolves a bundle ID to a display name + icon for the override row.
/// Falls back gracefully when the app isn't installed (uninstalled since
/// the override was added). `bundleID` becomes the displayed name in that
/// case; the icon slot stays nil.
struct AppMetadata: Sendable {
    let bundleID: String
    let displayName: String
    let icon: NSImage?

    init(bundleID: String) {
        self.bundleID = bundleID
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            self.displayName = bundleID
            self.icon = nil
            return
        }
        let bundle = Bundle(url: url)
        let info = bundle?.localizedInfoDictionary ?? bundle?.infoDictionary
        let name = info?["CFBundleDisplayName"] as? String
            ?? info?["CFBundleName"] as? String
            ?? url.deletingPathExtension().lastPathComponent
        self.displayName = name
        self.icon = NSWorkspace.shared.icon(forFile: url.path)
    }
}
