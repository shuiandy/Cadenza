import Foundation
import Testing
@testable import Cadenza

/// Every model the app talks to resolves through AIProvider's configured-model
/// accessors (UserDefaults override ?? code default). These tests pin the
/// override/fallback/empty-string semantics so a future refactor can't silently
/// reintroduce hardcoded model IDs ignoring user overrides.
@Suite("AIProviderModelConfig", .serialized)
struct AIProviderModelConfigTests {

    /// Keys these tests may write. Each test cleans up around itself so the
    /// suite never leaks overrides into the developer's real defaults domain.
    private static let touchedKeys = [
        "model.openai", "model.claude", "model.gemini", "model.minimax",
        "chatModel.openai", "chatModel.claude", "chatModel.gemini", "chatModel.minimax",
        "chatProvider", "defaultAIProvider",
        "transcriptionModel.gemini", "realtimeModel.openai", "realtimeModel.gemini",
    ]

    private func withCleanDefaults(_ body: () -> Void) {
        let defaults = UserDefaults.standard
        let saved = Self.touchedKeys.map { ($0, defaults.string(forKey: $0)) }
        Self.touchedKeys.forEach { defaults.removeObject(forKey: $0) }
        defer {
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        body()
    }

    @Test func summaryModelFallsBackToDefault() {
        withCleanDefaults {
            #expect(AIProvider.openai.summaryModel == AIProvider.openai.defaultModel)
            #expect(AIProvider.gemini.summaryModel == AIProvider.gemini.defaultModel)
        }
    }

    @Test func summaryModelHonorsOverride() {
        withCleanDefaults {
            UserDefaults.standard.set("gpt-6-preview", forKey: "model.openai")
            #expect(AIProvider.openai.summaryModel == "gpt-6-preview")
            // Chat shares the same override key…
            #expect(AIProvider.openai.chatModel == "gpt-6-preview")
        }
    }

    @Test func chatModelFallsBackToChatDefaultNotSummaryDefault() {
        withCleanDefaults {
            #expect(AIProvider.openai.chatModel == AIProvider.openai.defaultChatModel)
            #expect(AIProvider.openai.chatModel != AIProvider.openai.defaultModel)
        }
    }

    @Test func transcriptionModelHonorsOverrideAndFallback() {
        withCleanDefaults {
            #expect(AIProvider.gemini.transcriptionModel == AIProvider.gemini.defaultTranscriptionModel)
            UserDefaults.standard.set("gemini-4.0-flash", forKey: "transcriptionModel.gemini")
            #expect(AIProvider.gemini.transcriptionModel == "gemini-4.0-flash")
        }
    }

    @Test func realtimeModelHonorsOverrideAndFallback() {
        withCleanDefaults {
            #expect(AIProvider.openai.realtimeModel == "gpt-live-transcribe")
            #expect(AIProvider.gemini.realtimeModel == "gemini-3.5-transcribe-live")
            UserDefaults.standard.set("gemini-3.5-flash-live", forKey: "realtimeModel.gemini")
            #expect(AIProvider.gemini.realtimeModel == "gemini-3.5-flash-live")
        }
    }

    @Test func emptyAndWhitespaceOverridesFallBackToDefault() {
        withCleanDefaults {
            UserDefaults.standard.set("", forKey: "realtimeModel.openai")
            #expect(AIProvider.openai.realtimeModel == AIProvider.openai.defaultRealtimeModel)
            UserDefaults.standard.set("   ", forKey: "model.openai")
            #expect(AIProvider.openai.summaryModel == AIProvider.openai.defaultModel)
            // `defaults write` / paste can leave a trailing newline — still "unset".
            UserDefaults.standard.set("\n", forKey: "model.openai")
            #expect(AIProvider.openai.summaryModel == AIProvider.openai.defaultModel)
            UserDefaults.standard.set("gpt-6-preview\n", forKey: "model.openai")
            #expect(AIProvider.openai.summaryModel == "gpt-6-preview")
        }
    }

    @Test func overrideValueIsTrimmed() {
        withCleanDefaults {
            UserDefaults.standard.set("  gpt-6-preview  ", forKey: "model.openai")
            #expect(AIProvider.openai.summaryModel == "gpt-6-preview")
        }
    }

    @Test func fallbackChatPresetsUseConfiguredAndDefaultModelsOnly() {
        withCleanDefaults {
            let presets = AIChatModelCatalog.fallbackPresets(for: .openai)
            #expect(presets.map(\.modelID) == ["gpt-5.6-terra", "gpt-5.6-sol"])
            #expect(presets.map(\.title) == presets.map(\.modelID))
            #expect(AIChatModelCatalog.displayTitle(for: .openai, modelID: "gpt-5.4") == "gpt-5.4")
        }
    }

    @Test func fallbackChatPresetsDoNotInventProviderModels() {
        withCleanDefaults {
            #expect(AIChatModelCatalog.fallbackPresets(for: .claude).map(\.modelID) == [
                "claude-haiku-4-5",
                "claude-sonnet-4-6",
            ])
            // Chat and summary share one Gemini default, so the list dedups to one.
            #expect(AIChatModelCatalog.fallbackPresets(for: .gemini).map(\.modelID) == [
                "gemini-3.7-flash",
            ])
            #expect(AIChatModelCatalog.fallbackPresets(for: .minimax).map(\.modelID) == [
                "MiniMax-M2.7-highspeed",
                "MiniMax-M2.7",
            ])
        }
    }

    @Test func chatModelOverrideIsChatOnly() {
        withCleanDefaults {
            UserDefaults.standard.set("gpt-summary-custom", forKey: "model.openai")
            UserDefaults.standard.set("gpt-5.5", forKey: "chatModel.openai")

            #expect(AIChatModelCatalog.configuredModel(for: .openai) == "gpt-5.5")
            #expect(AIProvider.openai.summaryModel == "gpt-summary-custom")
        }
    }

    @Test func chatModelFallsBackToExistingProviderChatModel() {
        withCleanDefaults {
            UserDefaults.standard.set("gpt-existing-chat", forKey: "model.openai")
            #expect(AIChatModelCatalog.configuredModel(for: .openai) == "gpt-existing-chat")
        }
    }

    @Test func selectingChatPresetPersistsDedicatedChatModel() {
        withCleanDefaults {
            AIChatModelCatalog.persist(modelID: "gpt-5.4", for: .openai)
            #expect(UserDefaults.standard.string(forKey: "chatModel.openai") == "gpt-5.4")
            #expect(AIChatModelCatalog.configuredModel(for: .openai) == "gpt-5.4")

            AIChatModelCatalog.persist(modelID: "claude-sonnet-4-6", for: .claude)
            #expect(UserDefaults.standard.string(forKey: "chatModel.claude") == "claude-sonnet-4-6")
            #expect(AIChatModelCatalog.configuredModel(for: .claude) == "claude-sonnet-4-6")

            AIChatModelCatalog.persist(modelID: "gemini-3.5-pro", for: .gemini)
            #expect(UserDefaults.standard.string(forKey: "chatModel.gemini") == "gemini-3.5-pro")
            #expect(AIChatModelCatalog.configuredModel(for: .gemini) == "gemini-3.5-pro")
        }
    }

    @Test func chatProviderSelectionPersistsSeparatelyFromSummaryProvider() {
        withCleanDefaults {
            UserDefaults.standard.set(AIProvider.gemini.rawValue, forKey: "defaultAIProvider")

            AIChatModelCatalog.persist(provider: .openai)

            #expect(AIChatModelCatalog.configuredProvider() == .openai)
            #expect(UserDefaults.standard.string(forKey: "defaultAIProvider") == AIProvider.gemini.rawValue)
        }
    }

    @Test func chatProviderFallsBackToSummaryProviderWhenUnsetOrInvalid() {
        withCleanDefaults {
            UserDefaults.standard.set(AIProvider.gemini.rawValue, forKey: "defaultAIProvider")
            #expect(AIChatModelCatalog.configuredProvider() == .gemini)

            UserDefaults.standard.set("removed-provider", forKey: "chatProvider")
            #expect(AIChatModelCatalog.configuredProvider() == .gemini)
        }
    }

    @Test func availableProviderFallbackPrefersConfiguredChatProvider() {
        withCleanDefaults {
            AIChatModelCatalog.persist(provider: .openai)
            #expect(
                AIChatModelCatalog.preferredAvailableProvider(from: [.apple, .openai]) == .openai
            )
            #expect(
                AIChatModelCatalog.preferredAvailableProvider(from: [.apple, .gemini]) == .apple
            )
            #expect(AIChatModelCatalog.preferredAvailableProvider(from: []) == nil)
        }
    }

    @Test func modelListServiceFetchesOpenAIChatModels() async throws {
        let stub = ModelListFetchStub(json: """
        {
          "data": [
            { "id": "gpt-5.6-terra" },
            { "id": "text-embedding-3-small" },
            { "id": "gpt-5.6" },
            { "id": "whisper-1" }
          ]
        }
        """)
        let service = AIChatModelListService(fetchData: { request in
            try await stub.fetch(request)
        })

        let presets = try await service.fetchPresets(for: .openai, apiKey: "openai-key")
        let request = try #require(await stub.firstRequest())

        #expect(request.url?.absoluteString == "https://api.openai.com/v1/models")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer openai-key")
        #expect(presets.map(\.modelID) == ["gpt-5.6-terra", "gpt-5.6"])
    }

    @Test func modelListServiceFiltersGeminiGenerateContentModels() async throws {
        let stub = ModelListFetchStub(json: """
        {
          "models": [
            {
              "name": "models/gemini-3.5-flash",
              "baseModelId": "gemini-3.5-flash",
              "supportedGenerationMethods": ["generateContent"]
            },
            {
              "name": "models/gemini-3.5-pro",
              "baseModelId": "gemini-3.5-pro",
              "supportedGenerationMethods": ["embedContent"]
            },
            {
              "name": "models/text-embedding-004",
              "baseModelId": "text-embedding-004",
              "supportedGenerationMethods": ["embedContent"]
            }
          ]
        }
        """)
        let service = AIChatModelListService(fetchData: { request in
            try await stub.fetch(request)
        })

        let presets = try await service.fetchPresets(for: .gemini, apiKey: "gemini-key")
        let request = try #require(await stub.firstRequest())

        #expect(request.url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models")
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "gemini-key")
        #expect(presets.map(\.modelID) == ["gemini-3.5-flash"])
    }

    @Test func modelListServiceFetchesClaudeModels() async throws {
        let stub = ModelListFetchStub(json: """
        {
          "data": [
            { "id": "claude-haiku-4-5" },
            { "id": "not-a-chat-model" },
            { "id": "claude-sonnet-4-6" }
          ]
        }
        """)
        let service = AIChatModelListService(fetchData: { request in
            try await stub.fetch(request)
        })

        let presets = try await service.fetchPresets(for: .claude, apiKey: "claude-key")
        let request = try #require(await stub.firstRequest())

        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/models")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "claude-key")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(presets.map(\.modelID) == ["claude-haiku-4-5", "claude-sonnet-4-6"])
    }

    @Test func modelListServiceFetchesMiniMaxModels() async throws {
        let stub = ModelListFetchStub(json: """
        {
          "data": [
            { "id": "MiniMax-M3" },
            { "id": "image-01" },
            { "id": "MiniMax-M2.7-highspeed" }
          ]
        }
        """)
        let service = AIChatModelListService(fetchData: { request in
            try await stub.fetch(request)
        })

        let presets = try await service.fetchPresets(for: .minimax, apiKey: "minimax-key")
        let request = try #require(await stub.firstRequest())

        #expect(request.url?.absoluteString == "https://api.minimax.io/v1/models")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer minimax-key")
        #expect(presets.map(\.modelID) == ["MiniMax-M3", "MiniMax-M2.7-highspeed"])
    }

    @Test func modelListServiceRejectsOversizedResponseBeforeDecoding() async throws {
        let padding = String(
            repeating: "a",
            count: AITransportLimits.modelList.maxBufferedResponseBytes
        )
        let data = Data("{\"data\":[],\"padding\":\"\(padding)\"}".utf8)
        let service = AIChatModelListService(fetchData: { request in
            (data, Self.successResponse(for: request))
        })

        await #expect(throws: AITransportError.self) {
            _ = try await service.fetchPresets(for: .openai, apiKey: "openai-key")
        }
    }

    @Test func modelListServiceRejectsTooManyItems() async throws {
        let items = (0...500).map { ["id": "gpt-test-\($0)"] }
        let data = try JSONSerialization.data(withJSONObject: ["data": items])
        let service = AIChatModelListService(fetchData: { request in
            (data, Self.successResponse(for: request))
        })

        await #expect(throws: AITransportError.self) {
            _ = try await service.fetchPresets(for: .openai, apiKey: "openai-key")
        }
    }

    @Test func modelListServiceRejectsOversizedModelIdentifier() async throws {
        let longID = "gpt-" + String(repeating: "x", count: 257)
        let data = try JSONSerialization.data(withJSONObject: ["data": [["id": longID]]])
        let service = AIChatModelListService(fetchData: { request in
            (data, Self.successResponse(for: request))
        })

        await #expect(throws: AITransportError.self) {
            _ = try await service.fetchPresets(for: .openai, apiKey: "openai-key")
        }
    }

    @Test func preferredModelUsesRemoteListBeforeStalePersistedValue() {
        withCleanDefaults {
            UserDefaults.standard.set("gemini-3.5-pro", forKey: "chatModel.gemini")
            let remotePresets = [AIChatModelPreset(modelID: "gemini-3.5-flash")]

            #expect(AIChatModelCatalog.preferredModel(for: .gemini, presets: remotePresets) == "gemini-3.5-flash")
        }
    }

    private static func successResponse(for request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url ?? URL(string: "https://api.openai.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
    }
}

private actor ModelListFetchStub {
    private let json: String
    private var requests: [URLRequest] = []

    init(json: String) {
        self.json = json
    }

    func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let data = Data(json.utf8)
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (data, response)
    }

    func firstRequest() -> URLRequest? {
        requests.first
    }
}
