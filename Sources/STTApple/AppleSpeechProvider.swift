import AVFoundation
import Foundation
import Speech
import STTCore

/// An on-device realtime transcription provider backed by Apple's
/// `SpeechAnalyzer` and `SpeechTranscriber` APIs.
///
/// The provider deliberately accepts the app's existing 16 kHz mono Int16
/// audio stream, so adding Apple Speech does not alter capture or
/// orchestrator behavior.
@available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
public struct AppleSpeechProvider: SttProvider {
    public let name = "apple"
    public let capabilities = Capabilities(
        partials: true,
        punctuation: true,
        languages: .deviceSupported,
        sampleRates: [16_000],
        maxSessionSeconds: nil,
        supportsClientEndpointing: true
    )

    public init() {}

    /// Downloads the assets required by the current configuration, if needed.
    /// Call this before accepting a dictation hotkey so the first use does not
    /// spend its recording window waiting on a model download.
    public static func prepare(config: SessionConfig) async throws {
        _ = try await makeSetup(config: config)
    }

    /// Returns the locales available to the current device, including locales
    /// whose assets are downloadable but not installed yet.
    public static func supportedLanguages() async -> [String] {
        await SpeechTranscriber.supportedLocales
            .map(\.identifier)
            .sorted()
    }

    public func open(config: SessionConfig) async throws -> any SttSession {
        let setup = try await Self.makeSetup(config: config)
        let session = AppleSpeechSession(
            progressiveTranscriber: setup.progressiveTranscriber,
            finalTranscriber: setup.finalTranscriber,
            inputFormat: setup.inputFormat,
            context: Self.makeContext(hints: config.hints)
        )
        try await session.start()
        return session
    }

    static func resolveLocale(language: String?) async throws -> Locale {
        guard SpeechTranscriber.isAvailable else {
            throw AppleSpeechError.unavailable
        }

        let requestedLocale = language.map(Locale.init(identifier:)) ?? Locale.current
        guard let supportedLocale = await SpeechTranscriber.supportedLocale(
            equivalentTo: requestedLocale
        ) else {
            throw AppleSpeechError.unsupportedLanguage(requestedLocale.identifier)
        }
        return supportedLocale
    }

    static func makeContext(hints: [String]) -> AnalysisContext {
        let context = AnalysisContext()
        let nonEmptyHints = hints.filter { !$0.isEmpty }
        if !nonEmptyHints.isEmpty {
            context.contextualStrings[.general] = nonEmptyHints
        }
        return context
    }

    private static func makeSetup(config: SessionConfig) async throws -> Setup {
        let locale = try await resolveLocale(language: config.language)
        let progressiveTranscriber = SpeechTranscriber(
            locale: locale,
            preset: .progressiveTranscription
        )
        let finalTranscriber = SpeechTranscriber(
            locale: locale,
            preset: .transcriptionWithAlternatives
        )
        let modules: [any SpeechModule] = [progressiveTranscriber, finalTranscriber]

        do {
            if let installationRequest = try await AssetInventory.assetInstallationRequest(
                supporting: modules
            ) {
                try await installationRequest.downloadAndInstall()
            }
        } catch {
            throw AppleSpeechError.assetPreparationFailed(error.localizedDescription)
        }

        guard let inputFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: modules
        ) else {
            throw AppleSpeechError.noCompatibleAudioFormat
        }

        guard inputFormat.sampleRate == 16_000,
              inputFormat.channelCount == 1,
              inputFormat.commonFormat == .pcmFormatInt16
        else {
            throw AppleSpeechError.unsupportedAudioFormat(inputFormat.description)
        }

        return Setup(
            progressiveTranscriber: progressiveTranscriber,
            finalTranscriber: finalTranscriber,
            inputFormat: inputFormat
        )
    }

    private struct Setup {
        let progressiveTranscriber: SpeechTranscriber
        let finalTranscriber: SpeechTranscriber
        let inputFormat: AVAudioFormat
    }
}

@available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
public enum AppleSpeechError: Error, Sendable, LocalizedError, Equatable {
    case unavailable
    case unsupportedLanguage(String)
    case assetPreparationFailed(String)
    case noCompatibleAudioFormat
    case unsupportedAudioFormat(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Apple Speech transcription is unavailable on this device."
        case .unsupportedLanguage(let language):
            return "Apple Speech does not support \(language) on this device."
        case .assetPreparationFailed(let message):
            return "Could not prepare Apple Speech assets: \(message)"
        case .noCompatibleAudioFormat:
            return "Apple Speech has no compatible audio format installed."
        case .unsupportedAudioFormat(let format):
            return "Apple Speech selected an unsupported input format: \(format)"
        }
    }
}
