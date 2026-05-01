import SwiftUI
import AppKit
import Core

/// Click-to-record hotkey field. Captures the next `keyDown` event (with
/// any held modifiers) into the supplied bindings, then exits recording
/// mode automatically. Esc cancels recording without changing the binding.
///
/// Records *regular keys with modifier mask* — e.g. ⌘⇧9, F19,
/// Return. Modifier-only activations (right Option, fn, etc.) currently
/// only enter the config via the default value or the per-field "Reset"
/// affordance the caller provides; capturing a modifier-only press here
/// would require timer-based "tap detection" that's worth deferring until
/// dogfood proves it's needed.
struct HotkeyRecorderField: View {
    @Binding var keyCode: UInt16
    @Binding var modifiers: ModifierSet

    /// Visible inside the field when not recording. Useful for "Activation"
    /// vs "Cancel" disambiguation when two recorders are stacked.
    var placeholder: String = "Click to record"

    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button(action: toggleRecording) {
            HStack {
                Text(displayText)
                    .foregroundStyle(displayColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if recording {
                    Image(systemName: "record.circle")
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(recording ? Color.accentColor.opacity(0.15) : Color.gray.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(recording ? Color.accentColor : Color.gray.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onDisappear { stopRecording() }
    }

    // MARK: - Recording lifecycle

    private func toggleRecording() {
        recording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        guard !recording else { return }
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleKeyDown(event)
            // Returning nil swallows the event so the captured combo
            // doesn't leak through to the focused control (e.g. ⌘W
            // closing the Settings window mid-record).
            return nil
        }
    }

    private func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        recording = false
    }

    private func handleKeyDown(_ event: NSEvent) {
        // Esc cancels without changing the binding so users can back out.
        if event.keyCode == 0x35 && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            stopRecording()
            return
        }
        let captured = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        keyCode = event.keyCode
        modifiers = KeyCombo.modifierSet(from: captured)
        stopRecording()
    }

    // MARK: - Presentation

    private var displayText: String {
        if recording {
            return "Press a key combo… (Esc to cancel)"
        }
        let combo = KeyCombo.displayString(keyCode: keyCode, modifiers: modifiers)
        return combo.isEmpty ? placeholder : combo
    }

    private var displayColor: Color {
        recording ? .secondary : .primary
    }
}
