import SwiftUI
import Core

struct PrivacyPane: View {
    let store: ConfigStore

    var body: some View {
        Form {
            Section("Data flow") {
                DisclosureContent(providerInfo: providerInfo)
            }

            Section("Acknowledgment") {
                if store.config.privacy.hasReadDisclosure {
                    LabeledContent("Status") {
                        Text(acknowledgmentLabel)
                            .foregroundStyle(.secondary)
                    }
                    Button("Show disclosure again on next launch", action: revokeAcknowledgment)
                } else {
                    Text("You have not yet acknowledged the disclosure.")
                        .foregroundStyle(.secondary)
                    Button("I understand", action: acknowledge)
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var providerInfo: ProviderInfo? {
        ProviderRegistry.info(for: store.config.provider.providerName)
    }

    private var acknowledgmentLabel: String {
        guard let date = store.config.privacy.disclosureAcknowledgedAt else {
            return "Acknowledged"
        }
        return "Acknowledged \(date.formatted(date: .abbreviated, time: .omitted))"
    }

    private func acknowledge() {
        store.update {
            $0.privacy.hasReadDisclosure = true
            $0.privacy.disclosureAcknowledgedAt = Date()
        }
    }

    private func revokeAcknowledgment() {
        store.update {
            $0.privacy.hasReadDisclosure = false
            $0.privacy.disclosureAcknowledgedAt = nil
        }
    }
}

/// The privacy disclosure text — verbatim per TECH_SPEC §10.1. Extracted so
/// the first-run modal (PLAN_SETTINGS.md §6 step 6) can reuse it without
/// duplicating prose.
struct DisclosureContent: View {
    let providerInfo: ProviderInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            disclosureLine(dictationDisclosure)
            disclosureLine("Transcripts are stored locally in `~/Library/Application Support/whatchu-say/`.")
            disclosureLine("If you use meeting transcription, recordings are sent to ElevenLabs over an encrypted connection for transcription and diarization. An ElevenLabs API key is required for meetings regardless of your dictation provider.")
            disclosureLine("If configured, ElevenLabs API keys are stored in macOS Keychain and used only to authenticate with ElevenLabs.")
            disclosureLine("No usage analytics, crash reports, or telemetry are sent to whatchu-say developers.")

            if let info = providerInfo, let dataPolicyURL = info.dataPolicyURL {
                Link("\(info.displayName) data-handling policy", destination: dataPolicyURL)
                    .font(.callout)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var dictationDisclosure: String {
        guard let providerInfo else {
            return "Dictation audio is handled by your configured provider."
        }

        switch providerInfo.dictationDataHandling {
        case .onDevice:
            return "Dictation audio is processed on this Mac by \(providerInfo.displayName) and is not sent to Apple for transcription."
        case .remote:
            return "Dictation audio is streamed to \(providerInfo.displayName) over an encrypted WebSocket while you dictate."
        }
    }

    private func disclosureLine(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
    }
}
