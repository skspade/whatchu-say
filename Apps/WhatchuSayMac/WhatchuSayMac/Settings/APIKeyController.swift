import Foundation
import Observation
import Core
import PlatformApple
import STTCore
import STTElevenLabs

/// SwiftUI-facing surface over Keychain reads/writes and the
/// "open a session, immediately close" handshake test from
/// docs/PLAN_SETTINGS.md §4.7.
///
/// Owned by `AppDelegate`; threaded through the Settings scene to
/// `ProviderPane`. Holds no key plaintext beyond what the Provider pane's
/// `SecureField` supplies; `savedKeySuffix` is the only persisted display
/// state (last-4 chars).
@MainActor
@Observable
final class APIKeyController {
    /// Last-4 of the currently-saved key, for "Update API Key (••••XXXX)"
    /// labels. `nil` means no key on file.
    var savedKeySuffix: String?

    /// Most recent Test Connection result. `nil` until the user runs one.
    /// Cleared on key change so a stale red ✗ doesn't sit next to a freshly-typed key.
    var lastTestResult: TestResult?

    /// Set to `true` while a Test Connection is in flight so the pane can
    /// disable the button.
    var isTestingConnection = false

    enum TestResult: Equatable {
        case success
        case failure(message: String)
    }

    @ObservationIgnored
    private let keychain: KeychainAPIKeyStore
    @ObservationIgnored
    private let providerName: String
    @ObservationIgnored
    private let onKeySaved: (String) async -> Void

    init(
        keychain: KeychainAPIKeyStore,
        providerName: String,
        onKeySaved: @escaping (String) async -> Void
    ) {
        self.keychain = keychain
        self.providerName = providerName
        self.onKeySaved = onKeySaved
    }

    /// Hydrate `savedKeySuffix` from Keychain. Call once at startup before
    /// the Settings window can be opened.
    func loadInitial() async {
        let key = try? await keychain.read(provider: providerName)
        savedKeySuffix = key.flatMap(APIKeyPrompt.suffix(of:))
    }

    /// Persist a new key and rebuild the orchestrator so it picks up the
    /// new credentials. Throws on Keychain failure.
    func save(_ newKey: String) async throws {
        try await keychain.write(provider: providerName, key: newKey)
        savedKeySuffix = APIKeyPrompt.suffix(of: newKey)
        lastTestResult = nil
        await onKeySaved(newKey)
    }

    /// Open a provider session against `apiKey` and `providerConfig`, then
    /// immediately close it. A successful return = handshake + auth OK.
    /// Updates `lastTestResult` so the pane can render an indicator.
    ///
    /// Hardcoded to `ElevenLabsProvider` — the only adapter that exists
    /// today. Multi-provider routing happens via `ProviderRegistry` when a
    /// second adapter lands.
    func testConnection(apiKey: String, providerConfig: ProviderConfig) async {
        isTestingConnection = true
        defer { isTestingConnection = false }

        let provider = ElevenLabsProvider(apiKey: apiKey)
        let sessionConfig = SessionConfig(
            language: providerConfig.language,
            model: providerConfig.model,
            hints: providerConfig.hints
        )
        do {
            let session = try await provider.open(config: sessionConfig)
            await session.close()
            lastTestResult = .success
        } catch {
            lastTestResult = .failure(message: friendlyMessage(from: error))
        }
    }

    private func friendlyMessage(from error: Error) -> String {
        if let stt = error as? SttError {
            return String(describing: stt)
        }
        return error.localizedDescription
    }
}
