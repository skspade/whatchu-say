import SwiftUI
import Core

struct ProviderPane: View {
    let store: ConfigStore
    let apiKeys: APIKeyController

    @State private var apiKeyInput: String = ""
    @State private var showKey = false
    @State private var isSaving = false
    @State private var saveError: String?

    @State private var newHint: String = ""
    @State private var hintError: String?

    /// ElevenLabs realtime caps: 50 terms, 20 chars each.
    private static let maxHints = 50
    private static let maxHintLength = 20

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
            }

            Section {
                Toggle(
                    "Remove filler words",
                    isOn: store.binding(for: \.provider.noVerbatim)
                )
            } footer: {
                Text("Asks ElevenLabs to strip filler words (\u{201C}um\u{201D}, \u{201C}uh\u{201D}), false starts, and non-speech sounds from transcripts. Applies to dictation and meeting recordings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                hintsEditor
            } header: {
                HStack {
                    Text("Hints")
                    Spacer()
                    Text("\(store.config.provider.hints.count) / \(Self.maxHints)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            } footer: {
                Text("Bias the model toward specific words — useful for product names, technical jargon, and proper nouns. Up to \(Self.maxHints) terms, \(Self.maxHintLength) characters each.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

    // MARK: - Hints editor

    @ViewBuilder
    private var hintsEditor: some View {
        let hints = store.config.provider.hints

        if hints.isEmpty {
            Text("No hints added.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ForEach(Array(hints.enumerated()), id: \.offset) { index, hint in
                HStack {
                    Text(hint)
                    Spacer()
                    Button {
                        removeHint(at: index)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Remove")
                }
            }
        }

        HStack {
            TextField(
                "Add hint",
                text: $newHint,
                prompt: Text("e.g. Pantomath")
            )
            .onSubmit(addHint)
            Button("Add", action: addHint)
                .disabled(addDisabled)
        }

        if let hintError {
            Text(hintError)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private var addDisabled: Bool {
        let trimmed = newHint.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
            || store.config.provider.hints.count >= Self.maxHints
    }

    private func addHint() {
        let trimmed = newHint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if trimmed.count > Self.maxHintLength {
            hintError = "Hints must be \(Self.maxHintLength) characters or fewer (this one is \(trimmed.count))."
            return
        }

        let existing = store.config.provider.hints
        if existing.count >= Self.maxHints {
            hintError = "Hint limit reached (\(Self.maxHints))."
            return
        }
        if existing.contains(trimmed) {
            hintError = "Already added."
            return
        }

        store.update { $0.provider.hints.append(trimmed) }
        newHint = ""
        hintError = nil
    }

    private func removeHint(at index: Int) {
        store.update {
            guard $0.provider.hints.indices.contains(index) else { return }
            $0.provider.hints.remove(at: index)
        }
        hintError = nil
    }
}
