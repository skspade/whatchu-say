import Core
import STTApple
import STTCore
import STTElevenLabs

/// Builds the selected dictation provider while keeping the separate
/// ElevenLabs batch capability available for meetings.
@MainActor
enum ProviderFactory {
    enum Error: LocalizedError {
        case missingElevenLabsAPIKey
        case unknownProvider(String)
        case appleRequiresMacOS26

        var errorDescription: String? {
            switch self {
            case .missingElevenLabsAPIKey:
                return "Set an ElevenLabs API key to use ElevenLabs dictation."
            case .unknownProvider(let identifier):
                return "This build does not recognize the \(identifier) provider."
            case .appleRequiresMacOS26:
                return "Apple Speech requires macOS 26 or later."
            }
        }
    }

    static func sessionConfig(from config: ProviderConfig) -> SessionConfig {
        SessionConfig(
            language: config.language,
            model: config.model,
            hints: config.hints,
            noVerbatim: config.noVerbatim
        )
    }

    static func makeDictationProvider(
        config: ProviderConfig,
        elevenLabsAPIKey: String?
    ) async throws -> any SttProvider {
        switch config.providerName {
        case ProviderRegistry.elevenlabs.identifier:
            guard let elevenLabsAPIKey, !elevenLabsAPIKey.isEmpty else {
                throw Error.missingElevenLabsAPIKey
            }
            return ElevenLabsProvider(
                apiKey: elevenLabsAPIKey,
                noVerbatim: config.noVerbatim
            )

        case ProviderRegistry.apple.identifier:
            guard #available(macOS 26.0, *) else {
                throw Error.appleRequiresMacOS26
            }
            try await AppleSpeechProvider.prepare(config: sessionConfig(from: config))
            return AppleSpeechProvider()

        default:
            throw Error.unknownProvider(config.providerName)
        }
    }

    static func makeMeetingTranscriber(
        elevenLabsAPIKey: String?,
        providerConfig: ProviderConfig
    ) -> (any BatchTranscriber)? {
        guard let elevenLabsAPIKey, !elevenLabsAPIKey.isEmpty else { return nil }
        return ElevenLabsProvider(
            apiKey: elevenLabsAPIKey,
            noVerbatim: providerConfig.noVerbatim
        ).batchTranscriber
    }
}
