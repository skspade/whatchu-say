import SwiftUI
import AppKit
import Core

/// First-run privacy disclosure presented before the menubar becomes
/// interactive (per docs/PLAN_SETTINGS.md §4.9). Reuses `DisclosureContent`
/// from the Privacy pane so the prose has a single source of truth.
struct FirstRunDisclosureView: View {
    let providerInfo: ProviderInfo?
    let onAcknowledge: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Welcome to whatchu-say")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Before you start dictating, please review how your data is handled.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            DisclosureContent(providerInfo: providerInfo)

            Spacer(minLength: 8)

            HStack {
                Button("Quit", action: onQuit)
                Spacer()
                Button("I understand", action: onAcknowledge)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520, height: 400)
    }
}

/// Modal-window helper for `FirstRunDisclosureView`. Blocks the caller
/// until the user picks "I understand" or "Quit"; returns the choice.
///
/// The window has no close button — the only exits are the two explicit
/// actions, which removes the "what happens if I just close it?"
/// ambiguity. Cmd-Q still routes through the menubar so users aren't
/// trapped in a broken state.
enum FirstRunDisclosure {
    enum Outcome { case acknowledged, quit }

    /// Present modally. Caller is responsible for terminating the app on
    /// `.quit` (we don't `NSApp.terminate` from here so the call site can
    /// log/flush before exit).
    @MainActor
    static func presentBlocking(providerInfo: ProviderInfo?) -> Outcome {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "whatchu-say"
        window.isReleasedWhenClosed = false
        window.center()

        var outcome: Outcome = .quit
        let view = FirstRunDisclosureView(
            providerInfo: providerInfo,
            onAcknowledge: {
                outcome = .acknowledged
                NSApp.stopModal()
            },
            onQuit: {
                outcome = .quit
                NSApp.stopModal()
            }
        )
        window.contentViewController = NSHostingController(rootView: view)

        NSApp.activate(ignoringOtherApps: true)
        NSApp.runModal(for: window)
        window.orderOut(nil)
        return outcome
    }
}
