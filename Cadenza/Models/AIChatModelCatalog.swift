import Foundation

struct AIChatModelPreset: Identifiable, Equatable, Sendable {
    let modelID: String

    var id: String { modelID }
    var title: String { modelID }
}

enum AIChatModelCatalog {
    private static let chatProviderKey = "chatProvider"

    static func presets(for provider: AIProvider) -> [AIChatModelPreset] {
        fallbackPresets(for: provider)
    }

    static func fallbackPresets(for provider: AIProvider) -> [AIChatModelPreset] {
        switch provider {
        case .apple, .whisperLocal:
            []
        case .openai, .claude, .gemini, .minimax:
            modelPresets([
                configuredModel(for: provider),
                provider.defaultChatModel,
                provider.defaultModel,
            ])
        }
    }

    static func configuredModel(for provider: AIProvider) -> String {
        configuredModel(key: chatModelKey(for: provider), default: provider.chatModel)
    }

    /// The last provider explicitly selected in an AI chat surface. This is
    /// intentionally separate from `defaultAIProvider`, which also controls
    /// post-processing summaries and recaps.
    static func configuredProvider() -> AIProvider {
        if let raw = UserDefaults.standard.string(forKey: chatProviderKey),
           let provider = AIProvider(rawValue: raw) {
            return provider
        }

        let fallbackRaw = UserDefaults.standard.string(forKey: "defaultAIProvider")
            ?? AIProvider.apple.rawValue
        return AIProvider(rawValue: fallbackRaw) ?? .apple
    }

    static func persist(provider: AIProvider) {
        UserDefaults.standard.set(provider.rawValue, forKey: chatProviderKey)
    }

    static func preferredAvailableProvider(from providers: [AIProvider]) -> AIProvider? {
        let configured = configuredProvider()
        return providers.contains(configured) ? configured : providers.first
    }

    static func persist(modelID: String, for provider: AIProvider) {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: chatModelKey(for: provider))
        } else {
            UserDefaults.standard.set(trimmed, forKey: chatModelKey(for: provider))
        }
    }

    static func selectedPreset(for provider: AIProvider, modelID: String) -> AIChatModelPreset? {
        presets(for: provider).first { $0.modelID == modelID }
    }

    static func displayTitle(for provider: AIProvider, modelID: String) -> String {
        modelID
    }

    static func preferredModel(
        for provider: AIProvider,
        presets: [AIChatModelPreset],
        currentModel: String? = nil
    ) -> String {
        let available = Set(presets.map(\.modelID))
        let candidates = [
            currentModel,
            configuredModel(for: provider),
            provider.defaultChatModel,
            provider.defaultModel,
        ].compactMap { $0 }

        for candidate in candidates {
            if available.contains(candidate) {
                return candidate
            }
        }
        return presets.first?.modelID ?? configuredModel(for: provider)
    }

    static func modelPresets(_ modelIDs: [String]) -> [AIChatModelPreset] {
        var seen = Set<String>()
        return modelIDs.compactMap { raw in
            let modelID = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !modelID.isEmpty, seen.insert(modelID).inserted else { return nil }
            return AIChatModelPreset(modelID: modelID)
        }
    }

    private static func chatModelKey(for provider: AIProvider) -> String {
        "chatModel.\(provider.rawValue)"
    }

    private static func configuredModel(key: String, default defaultModel: String) -> String {
        guard let raw = UserDefaults.standard.string(forKey: key),
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return defaultModel
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
