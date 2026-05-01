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
            disclosureLine("Audio is streamed to \(providerName) over an encrypted WebSocket while you dictate.")
            disclosureLine("Transcripts are stored locally in `~/Library/Application Support/whatchu-say/` and never sent anywhere except your configured provider.")
            disclosureLine("API keys are stored in macOS Keychain and never leave your machine except when authenticating with your provider.")
            disclosureLine("No usage analytics, crash reports, or telemetry are sent to whatchu-say developers.")

            if let info = providerInfo {
                Link("\(info.displayName) data-handling policy", destination: info.dataPolicyURL)
                    .font(.callout)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var providerName: String {
        providerInfo?.displayName ?? "your provider"
    }

    private func disclosureLine(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
    }
}
