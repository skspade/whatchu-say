import Testing
import Foundation
@testable import WhatchuSayMac
import Orchestrator
import Hotkey

@Suite("AppCoordinator: orchestrator → error-log routing")
@MainActor
struct AppCoordinatorErrorLogTests {
    private func makeStore() -> ErrorLogStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("whatchu-say-error-test-\(UUID().uuidString).json")
        return ErrorLogStore(fileURL: url, maxCount: 10)
    }

    @Test(".error event records to the store")
    func recordsOnError() {
        let store = makeStore()
        AppCoordinator.applyToErrorLog(.error(text: "connection lost"), store: store)
        #expect(store.entries.map(\.text) == ["connection lost"])
    }

    @Test("multiple .error events accumulate (newest first, no dedup)")
    func accumulatesMultipleErrors() {
        let store = makeStore()
        AppCoordinator.applyToErrorLog(.error(text: "first"), store: store)
        AppCoordinator.applyToErrorLog(.error(text: "second"), store: store)
        AppCoordinator.applyToErrorLog(.error(text: "second"), store: store)
        #expect(store.entries.map(\.text) == ["second", "second", "first"])
    }

    @Test("non-error events do not record")
    func ignoresNonErrorEvents() {
        let store = makeStore()
        AppCoordinator.applyToErrorLog(.sessionStarted(mode: .pressHold), store: store)
        AppCoordinator.applyToErrorLog(.partial(text: "hi"), store: store)
        AppCoordinator.applyToErrorLog(.finalizing, store: store)
        AppCoordinator.applyToErrorLog(.sessionEnded(injectedText: "hello"), store: store)
        AppCoordinator.applyToErrorLog(.sessionEnded(injectedText: nil), store: store)
        #expect(store.entries.isEmpty)
    }
}
