import Foundation

enum TranscriptionProviderMode: String, Sendable, Equatable {
    case postProcessing
    case realtime
}

struct LocalWhisperState: Sendable, Equatable {
    let model: String
    let isAvailable: Bool
}

struct TranscriptionProviderSelection: Sendable {
    let provider: AIProvider
    let apiKey: String?
    let model: String?
}

enum TranscriptionProviderResolutionError: Error, LocalizedError, Sendable, Equatable {
    case invalidStoredProvider(String)
    case unsupportedProvider(AIProvider, mode: TranscriptionProviderMode)
    case unsupportedLanguage(AIProvider, language: String)
    case localModelUnavailable(String)
    case missingAPIKey(AIProvider)

    var errorDescription: String? {
        switch self {
        case .invalidStoredProvider(let rawValue):
            String(
                format: String(localized: "The saved transcription provider “%@” is invalid. Choose a provider in Settings → Transcription."),
                Self.safeConfigurationLabel(rawValue)
            )
        case .unsupportedProvider(let provider, mode: .postProcessing):
            String(
                format: String(localized: "%@ cannot be used for post-recording transcription. Choose a transcription provider in Settings."),
                provider.displayName
            )
        case .unsupportedProvider(let provider, mode: .realtime):
            String(
                format: String(localized: "%@ cannot be used for realtime transcription. Choose Apple, OpenAI, or Gemini in Settings."),
                provider.displayName
            )
        case .unsupportedLanguage(let provider, let language):
            String(
                format: String(localized: "%@ does not support the selected language (%@). Cadenza will not switch providers automatically."),
                provider.displayName,
                Self.safeConfigurationLabel(language)
            )
        case .localModelUnavailable(let model):
            String(
                format: String(localized: "The local Whisper model “%@” is unavailable. Download it in Settings → Transcription."),
                Self.safeConfigurationLabel(model)
            )
        case .missingAPIKey(let provider):
            String(
                format: String(localized: "Add an API key for %@ in Settings. Cadenza will not use another transcription provider automatically."),
                provider.displayName
            )
        }
    }

    private static func safeConfigurationLabel(_ value: String) -> String {
        let singleLine = value.unicodeScalars.map { scalar -> Character in
            CharacterSet.controlCharacters.contains(scalar) ? "�" : Character(String(scalar))
        }
        let sanitized = String(singleLine)
        guard sanitized.count > 80 else { return sanitized }
        return String(sanitized.prefix(80)) + "…"
    }
}

@MainActor
struct TranscriptionProviderResolver {
    let apiKey: @MainActor @Sendable (AIProvider) -> String?
    let supportsAppleLanguage: @MainActor @Sendable (String) async -> Bool
    let localWhisperState: @MainActor @Sendable () -> LocalWhisperState

    func resolve(
        storedProviderRawValue: String?,
        defaultProvider: AIProvider,
        mode: TranscriptionProviderMode,
        language: String
    ) async throws -> TranscriptionProviderSelection {
        let provider: AIProvider
        if let storedProviderRawValue, !storedProviderRawValue.isEmpty {
            guard let storedProvider = AIProvider(rawValue: storedProviderRawValue) else {
                throw TranscriptionProviderResolutionError.invalidStoredProvider(storedProviderRawValue)
            }
            provider = storedProvider
        } else {
            provider = defaultProvider
        }

        guard Self.supports(provider: provider, in: mode) else {
            throw TranscriptionProviderResolutionError.unsupportedProvider(provider, mode: mode)
        }

        switch provider {
        case .apple:
            guard await supportsAppleLanguage(language) else {
                throw TranscriptionProviderResolutionError.unsupportedLanguage(provider, language: language)
            }
            return TranscriptionProviderSelection(provider: provider, apiKey: nil, model: nil)

        case .whisperLocal:
            let state = localWhisperState()
            guard state.isAvailable else {
                throw TranscriptionProviderResolutionError.localModelUnavailable(state.model)
            }
            return TranscriptionProviderSelection(provider: provider, apiKey: nil, model: state.model)

        case .openai, .gemini:
            let selectedKey = apiKey(provider)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !selectedKey.isEmpty else {
                throw TranscriptionProviderResolutionError.missingAPIKey(provider)
            }
            return TranscriptionProviderSelection(provider: provider, apiKey: selectedKey, model: nil)

        case .claude, .minimax:
            throw TranscriptionProviderResolutionError.unsupportedProvider(provider, mode: mode)
        }
    }

    static func live(
        apiKey: @escaping @MainActor @Sendable (AIProvider) -> String? = {
            KeychainManager.shared.readOnlyAPIKey(for: $0)
        }
    ) -> TranscriptionProviderResolver {
        TranscriptionProviderResolver(
            apiKey: apiKey,
            supportsAppleLanguage: { language in
                await AppleSpeechFactory.supportsLanguage(language)
            },
            localWhisperState: {
                let manager = WhisperModelManager.shared
                let model = manager.selectedModel
                return LocalWhisperState(model: model, isAvailable: manager.isAvailable(model))
            }
        )
    }

    private static func supports(provider: AIProvider, in mode: TranscriptionProviderMode) -> Bool {
        switch mode {
        case .postProcessing:
            switch provider {
            case .apple, .whisperLocal, .openai, .gemini:
                true
            case .claude, .minimax:
                false
            }
        case .realtime:
            switch provider {
            case .apple, .openai, .gemini:
                true
            case .whisperLocal, .claude, .minimax:
                false
            }
        }
    }
}
