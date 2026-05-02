import AppKit
import SwiftUI
import Meeting

/// Modal panel shown when the user clicks "Start meeting recording".
/// Displays the consent reminder (if enabled) and an optional attendees
/// chip-input. On Start, calls the provided closure with the parsed list.
@MainActor
final class StartMeetingPanel: NSPanel {
    private let onStart: (AttendeeList) -> Void
    private let onCancel: () -> Void

    init(
        showConsentReminder: Bool,
        showAttendeeField: Bool,
        onStart: @escaping (AttendeeList) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onStart = onStart
        self.onCancel = onCancel
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 220),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        title = "Start meeting recording"
        let view = StartMeetingModalView(
            showConsentReminder: showConsentReminder,
            showAttendeeField: showAttendeeField,
            onStart: { [weak self] list in
                self?.onStart(list)
                self?.close()
            },
            onCancel: { [weak self] in
                self?.onCancel()
                self?.close()
            }
        )
        contentView = NSHostingView(rootView: view)
        center()
    }
}

private struct StartMeetingModalView: View {
    let showConsentReminder: Bool
    let showAttendeeField: Bool
    let onStart: (AttendeeList) -> Void
    let onCancel: () -> Void

    @State private var attendeesText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showConsentReminder {
                Text("Recording without consent is illegal in some jurisdictions. Confirm participants are aware.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if showAttendeeField {
                Text("Attendees (optional)")
                    .font(.headline)
                TextField("Alice, Bob, Carol", text: $attendeesText)
                    .textFieldStyle(.roundedBorder)
            }
            Spacer()
            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Start") {
                    onStart(AttendeeList(parsing: attendeesText))
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 380, minHeight: 180)
    }
}
