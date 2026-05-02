import AppKit
import Meeting

/// Modal alert presented at app launch for each half-written meeting found
/// on disk. Lets the user salvage, discard, or defer per spec §9.
@MainActor
enum RecoveryPrompt {
    enum Choice {
        case recover
        case discard
        case later
    }

    static func present(for session: MeetingSession) -> Choice {
        let alert = NSAlert()
        alert.messageText = "Recover unfinished meeting?"
        alert.informativeText = """
        "\(session.title)" was recording when whatchu-say last quit. \
        We can try to transcribe what was captured, discard it, or leave it for next launch.
        """
        alert.addButton(withTitle: "Try transcribing")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Decide later")
        alert.alertStyle = .warning

        switch alert.runModal() {
        case .alertFirstButtonReturn: return .recover
        case .alertSecondButtonReturn: return .discard
        default: return .later
        }
    }
}
