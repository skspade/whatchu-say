import SwiftUI
import Core

struct HistoryPane: View {
    let store: ConfigStore

    var body: some View {
        Form {
            Section("Transcript History") {
                Toggle(
                    "Save transcripts to history",
                    isOn: store.binding(for: \.history.enabled)
                )

                Stepper(
                    value: retentionDaysBinding,
                    in: 1...365,
                    step: 1
                ) {
                    LabeledContent("Retention", value: "\(store.config.history.retentionDays) days")
                }
                .disabled(!store.config.history.enabled)

                Stepper(
                    value: maxEntriesBinding,
                    in: 100...100_000,
                    step: 100
                ) {
                    LabeledContent("Max entries", value: "\(store.config.history.maxEntries)")
                }
                .disabled(!store.config.history.enabled)

                Text("Persistent transcript history arrives in v1.5. These preferences are saved now and applied when it ships. Recent transcripts (menubar dropdown) are unaffected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Bridge `UInt32` config field to `Stepper`'s `Binding<Int>`. Clamping
    /// to non-negative is enforced by the stepper range.
    private var retentionDaysBinding: Binding<Int> {
        Binding(
            get: { Int(store.config.history.retentionDays) },
            set: { newValue in
                store.update { $0.history.retentionDays = UInt32(max(0, newValue)) }
            }
        )
    }

    private var maxEntriesBinding: Binding<Int> {
        Binding(
            get: { Int(store.config.history.maxEntries) },
            set: { newValue in
                store.update { $0.history.maxEntries = UInt32(max(0, newValue)) }
            }
        )
    }
}
