import SwiftUI
import Core
import STTApple

struct ProviderPane: View {
    let store: ConfigStore
    let apiKeys: APIKeyController
    let applyProviderConfiguration: () async -> Void

    @State private var apiKeyInput: String = ""
    @State private var showKey = false
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var isApplyingProvider = false
    @State private var appleLanguages: [String] = []
    @State private var isLoadingAppleLanguages = false

    @State private var newHint: String = ""
    @State private var hintError: String?

    /// ElevenLabs realtime caps: 50 terms, 20 chars each. Keep the shared
    /// config within these limits so a user can switch back without edits.
    private static let maxHints = 50
    private static let maxHintLength = 20

    var body: some View {
        Form {
            Section("Provider") {
                Picker("Service", selection: providerNameBinding) {
                    ForEach(ProviderRegistry.known, id: \.identifier) { info in
                        Text(info.displayName).tag(info.identifier)
                    }
                }

                if isAppleSpeech {
                    appleLanguagePicker
                } else {
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
            }

            if !isAppleSpeech {
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
                Text(hintsFooter)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(apiKeySectionTitle) {
                Text(apiKeyPurpose)
                    .font(.caption)
                    .foregroundStyle(.secondary)

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
                HStack {
                    Button(isApplyingProvider ? "Applying…" : "Apply Provider Settings") {
                        applyProvider()
                    }
                    .disabled(isApplyingProvider)

                    if isAppleSpeech {
                        Text("Apple Speech downloads the selected language model when needed.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Restarts dictation with the current provider settings.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: store.config.provider.providerName) {
            await loadAppleLanguagesIfNeeded()
        }
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
    private var appleLanguagePicker: some View {
        if isLoadingAppleLanguages {
            LabeledContent("Language") {
                ProgressView()
                    .controlSize(.small)
            }
        } else if appleLanguages.isEmpty {
            LabeledContent("Language", value: "No supported languages found")
                .foregroundStyle(.secondary)
        } else {
            Picker("Language", selection: appleLanguageBinding) {
                Text("System Language").tag("")
                ForEach(appleLanguages, id: \.self) { identifier in
                    Text(localeLabel(for: identifier)).tag(identifier)
                }
            }
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

    private func applyProvider() {
        isApplyingProvider = true
        Task { @MainActor in
            defer { isApplyingProvider = false }
            await applyProviderConfiguration()
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

    private var isAppleSpeech: Bool {
        store.config.provider.providerName == ProviderRegistry.apple.identifier
    }

    private var apiKeySectionTitle: String {
        isAppleSpeech ? "ElevenLabs API key (meetings)" : "ElevenLabs API key"
    }

    private var apiKeyPurpose: String {
        if isAppleSpeech {
            return "Apple Speech dictation does not require a key. An ElevenLabs key enables meeting transcription and diarization."
        }
        return "Used for ElevenLabs dictation and meeting transcription."
    }

    private var hintsFooter: String {
        if isAppleSpeech {
            return "Passed to Apple Speech as contextual terms. Use short product names, technical jargon, and proper nouns."
        }
        return "Bias the model toward specific words — useful for product names, technical jargon, and proper nouns. Up to \(Self.maxHints) terms, \(Self.maxHintLength) characters each."
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

    private var providerNameBinding: Binding<String> {
        Binding(
            get: { store.config.provider.providerName },
            set: { providerName in
                store.update { $0.provider.providerName = providerName }
            }
        )
    }

    private var appleLanguageBinding: Binding<String> {
        Binding(
            get: { store.config.provider.language ?? "" },
            set: { identifier in
                store.update {
                    $0.provider.language = identifier.isEmpty ? nil : identifier
                }
            }
        )
    }

    private func loadAppleLanguagesIfNeeded() async {
        guard isAppleSpeech else { return }
        guard #available(macOS 26.0, *) else {
            appleLanguages = []
            return
        }

        isLoadingAppleLanguages = true
        appleLanguages = await AppleSpeechProvider.supportedLanguages()
        isLoadingAppleLanguages = false
    }

    private func localeLabel(for identifier: String) -> String {
        Locale(identifier: identifier).localizedString(forIdentifier: identifier) ?? identifier
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
