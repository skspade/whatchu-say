import SwiftUI
import Core

struct ShortcutsPane: View {
    let store: ConfigStore

    var body: some View {
        Form {
            Section("Activation") {
                LabeledContent("Hotkey") {
                    HStack(spacing: 8) {
                        HotkeyRecorderField(
                            keyCode: store.binding(for: \.hotkey.keyCode),
                            modifiers: store.binding(for: \.hotkey.modifiers),
                            placeholder: "Click to record"
                        )
                        .frame(minWidth: 220)
                        Button("Reset", action: resetActivation)
                    }
                }
            }

            Section("Cancellation") {
                LabeledContent("Cancel key") {
                    HStack(spacing: 8) {
                        HotkeyRecorderField(
                            keyCode: store.binding(for: \.hotkey.cancelKeyCode),
                            modifiers: store.binding(for: \.hotkey.cancelModifiers),
                            placeholder: "Click to record"
                        )
                        .frame(minWidth: 220)
                        Button("Reset", action: resetCancel)
                    }
                }
            }

            Section("Timing") {
                Stepper(
                    value: pressHoldBinding,
                    in: 50...1000,
                    step: 25
                ) {
                    LabeledContent(
                        "Press-hold threshold",
                        value: "\(store.config.hotkey.pressHoldThresholdMs) ms"
                    )
                }
                Stepper(
                    value: doubleTapBinding,
                    in: 100...1000,
                    step: 25
                ) {
                    LabeledContent(
                        "Double-tap window",
                        value: "\(store.config.hotkey.doubleTapWindowMs) ms"
                    )
                }
            }

            Section {
                Text("The platform layer fully supports modifier-only activations (right/left Option) and regular keys; rebinding to an arbitrary chord may not match all events until the chord-detection path lands. Hotkey changes take effect on the next coordinator restart — saving a new API key is the easiest trigger.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Bindings

    private var pressHoldBinding: Binding<Int> {
        Binding(
            get: { Int(store.config.hotkey.pressHoldThresholdMs) },
            set: { newValue in store.update { $0.hotkey.pressHoldThresholdMs = UInt32(max(0, newValue)) } }
        )
    }

    private var doubleTapBinding: Binding<Int> {
        Binding(
            get: { Int(store.config.hotkey.doubleTapWindowMs) },
            set: { newValue in store.update { $0.hotkey.doubleTapWindowMs = UInt32(max(0, newValue)) } }
        )
    }

    // MARK: - Reset actions

    /// Restore the activation hotkey to right Option (modifier-only),
    /// matching the default `HotkeyConfig`. Useful for users who recorded a
    /// chord and want to revert without resetting the entire app.
    private func resetActivation() {
        store.update {
            $0.hotkey.keyCode = HotkeyConfig.defaultKeyCode
            $0.hotkey.modifiers = []
        }
    }

    private func resetCancel() {
        store.update {
            $0.hotkey.cancelKeyCode = HotkeyConfig.defaultCancelKeyCode
            $0.hotkey.cancelModifiers = []
        }
    }
}
