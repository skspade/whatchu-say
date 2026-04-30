#if os(iOS)
import Foundation
import Injector
import UIKit

/// `Injector` for iOS keyboard extensions. Wraps a weak reference to the
/// host `UIInputViewController` and inserts text via its
/// `textDocumentProxy`.
///
/// Unlike `InjectorMac`, there is no type-vs-paste decision: `insertText`
/// is atomic, instant, and routes through the host app's text view exactly
/// as if the user typed. The `InjectionHint` parameter is therefore
/// ignored.
///
/// MainActor-isolated because `textDocumentProxy` and `UIInputViewController`
/// are. The protocol method is `nonisolated` and hops back via
/// `MainActor.run` so callers (the orchestrator actor) don't need to know.
@MainActor
public final class KeyboardExtensionInjector: Injector {
    private weak var inputController: UIInputViewController?

    public init(inputController: UIInputViewController) {
        self.inputController = inputController
    }

    public nonisolated func inject(text: String, hint: InjectionHint) async throws {
        await MainActor.run {
            self.inputController?.textDocumentProxy.insertText(text)
        }
    }
}
#endif
