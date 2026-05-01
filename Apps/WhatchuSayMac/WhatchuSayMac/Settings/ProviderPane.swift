import SwiftUI
import Core

struct ProviderPane: View {
    let store: ConfigStore
    let apiKeys: APIKeyController

    @State private var apiKeyInput: String = ""
    @State private var showKey = false
    @State private var isSaving = false
    @State private var saveError: String?

    var body: some View {
        Form {
            Section("Provider") {
                Picker("Service", selection: store.binding(for: \.provider.providerName)) {
                    ForEach(ProviderRegistry.known, id: \.identifier) { info in
                        Text(info.displayName).tag(info.identifier)
                    }
                }

                TextField(
                    "Model",
                    text: optionalStringBinding(\.provider.model),
                    prompt: Text("Default")
                )

                TextField(
                    "Language",
                    text: optionalStringBinding(\.provider.language),
                    prompt: Text("Auto-detect")
                )

                TextField(
                    "Hints",
                    text: hintsBinding,
                    prompt: Text("comma-separated")
                )
            }

            Section("API key") {
                if let suffix = apiKeys.savedKeySuffix {
                    LabeledContent("Saved key", value: "••••\(suffix)")
                } else {
                    LabeledContent("Saved key", value: "(none)")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    keyEntryField
                    Toggle("Show", isOn: $showKey)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                }

                HStack {
                    Button(saveButtonTitle, action: runSave)
                        .disabled(saveDisabled)
                    Button(testButtonTitle, action: runTestConnection)
                        .disabled(testDisabled)
                    Spacer()
                    testResultIndicator
                }

                if let saveError {
                    Text(saveError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section {
                Text("Provider settings (model, language, hints) take effect on the next coordinator restart — saving a new API key is the easiest trigger.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Subviews

    @ViewBuilder
    private var keyEntryField: some View {
        if showKey {
            TextField("API key", text: $apiKeyInput, prompt: Text("Paste your key"))
                .textFieldStyle(.roundedBorder)
        } else {
            SecureField("API key", text: $apiKeyInput, prompt: Text("Paste your key"))
                .textFieldStyle(.roundedBorder)
        }
    }

    @ViewBuilder
    private var testResultIndicator: some View {
        if apiKeys.isTestingConnection {
            ProgressView().controlSize(.small)
        } else if let result = apiKeys.lastTestResult {
            switch result {
            case .success:
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failure(let message):
                Label(message, systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .help(message)
            }
        }
    }

    // MARK: - Actions

    private func runSave() {
        let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSaving = true
        saveError = nil
        Task { @MainActor in
            defer { isSaving = false }
            do {
                try await apiKeys.save(trimmed)
                apiKeyInput = ""
                showKey = false
            } catch {
                saveError = "Could not save key: \(error.localizedDescription)"
            }
        }
    }

    private func runTestConnection() {
        let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task { @MainActor in
            await apiKeys.testConnection(
                apiKey: trimmed,
                providerConfig: store.config.provider
            )
        }
    }

    // MARK: - Button state

    private var saveButtonTitle: String {
        apiKeys.savedKeySuffix == nil ? "Save key" : "Update key"
    }

    private var testButtonTitle: String {
        apiKeys.isTestingConnection ? "Testing…" : "Test Connection"
    }

    private var saveDisabled: Bool {
        isSaving || apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var testDisabled: Bool {
        apiKeys.isTestingConnection
            || apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Bindings

    /// Bridge `String?` config field to `TextField`'s `Binding<String>`.
    /// Empty input is normalised to `nil`.
    private func optionalStringBinding(
        _ keyPath: WritableKeyPath<AppConfig, String?>
    ) -> Binding<String> {
        Binding(
            get: { store.config[keyPath: keyPath] ?? "" },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                store.update { $0[keyPath: keyPath] = trimmed.isEmpty ? nil : trimmed }
            }
        )
    }

    /// Bridge `[String]` hints field to a comma-separated `Binding<String>`.
    private var hintsBinding: Binding<String> {
        Binding(
            get: { store.config.provider.hints.joined(separator: ", ") },
            set: { newValue in
                let parts = newValue
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                store.update { $0.provider.hints = parts }
            }
        )
    }
}
