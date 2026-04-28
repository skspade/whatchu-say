import Testing
import Foundation
@testable import WhatchuSayMac
import Orchestrator
import Hotkey

@Suite("AppCoordinator: orchestrator → recent-transcripts recording")
@MainActor
struct AppCoordinatorRecentTranscriptsTests {
    private func makeStore() -> RecentTranscriptsStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("whatchu-say-test-\(UUID().uuidString).json")
        return RecentTranscriptsStore(fileURL: url, maxCount: 5)
    }

    @Test("sessionEnded with injected text records to the store")
    func recordsOnSessionEnded() {
        let store = makeStore()
        AppCoordinator.applyToRecentTranscripts(
            .sessionEnded(injectedText: "hello world"),
            store: store
        )
        #expect(store.entries.map(\.text) == ["hello world"])
    }

    @Test("sessionEnded with nil text does not record (cancelled / empty final)")
    func ignoresNilSessionEnded() {
        let store = makeStore()
        AppCoordinator.applyToRecentTranscripts(
            .sessionEnded(injectedText: nil),
            store: store
        )
        #expect(store.entries.isEmpty)
    }

    @Test("sessionStarted does not record")
    func ignoresSessionStarted() {
        let store = makeStore()
        AppCoordinator.applyToRecentTranscripts(
            .sessionStarted(mode: .pressHold),
            store: store
        )
        #expect(store.entries.isEmpty)
    }

    @Test("partial does not record")
    func ignoresPartial() {
        let store = makeStore()
        AppCoordinator.applyToRecentTranscripts(
            .partial(text: "hello"),
            store: store
        )
        #expect(store.entries.isEmpty)
    }

    @Test("finalizing does not record")
    func ignoresFinalizing() {
        let store = makeStore()
        AppCoordinator.applyToRecentTranscripts(.finalizing, store: store)
        #expect(store.entries.isEmpty)
    }

    @Test("error does not record")
    func ignoresError() {
        let store = makeStore()
        AppCoordinator.applyToRecentTranscripts(
            .error(text: "connection lost"),
            store: store
        )
        #expect(store.entries.isEmpty)
    }

    @Test("multiple sessionEnded events accumulate in store order")
    func accumulatesMultipleSessions() {
        let store = makeStore()
        AppCoordinator.applyToRecentTranscripts(
            .sessionEnded(injectedText: "first"),
            store: store
        )
        AppCoordinator.applyToRecentTranscripts(
            .sessionEnded(injectedText: "second"),
            store: store
        )
        AppCoordinator.applyToRecentTranscripts(
            .sessionEnded(injectedText: "third"),
            store: store
        )
        #expect(store.entries.map(\.text) == ["third", "second", "first"])
    }
}
