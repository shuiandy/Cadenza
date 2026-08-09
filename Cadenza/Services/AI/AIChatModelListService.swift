import Foundation

struct AIChatModelListService: Sendable {
    typealias FetchData = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    static let maximumModelCount = 500
    static let maximumModelIDByteCount = 256

    private let transport: HardenedAITransport?
    private let fetchData: FetchData?

    init(transport: HardenedAITransport = .modelList) {
        self.transport = transport
        self.fetchData = nil
    }

    init(fetchData: @escaping FetchData) {
        self.transport = nil
        self.fetchData = fetchData
    }

    func fetchPresets(for provider: AIProvider, apiKey: String) async throws -> [AIChatModelPreset] {
        switch provider {
        case .openai:
            try await fetchOpenAIModels(apiKey: apiKey)
        case .claude:
            try await fetchClaudeModels(apiKey: apiKey)
        case .gemini:
            try await fetchGeminiModels(apiKey: apiKey)
        case .minimax:
            try await fetchMiniMaxModels(apiKey: apiKey)
        case .apple, .whisperLocal:
            AIChatModelCatalog.fallbackPresets(for: provider)
        }
    }

    func validateCredential(for provider: AIProvider, apiKey: String) async throws {
        guard var request = try Self.modelListRequest(for: provider, apiKey: apiKey) else {
            return
        }
        request.timeoutInterval = 10
        _ = try await validatedData(for: request, provider: provider, apiKey: apiKey)
    }

    // MARK: - Provider Fetching

    private func fetchOpenAIModels(apiKey: String) async throws -> [AIChatModelPreset] {
        let request = try Self.requiredModelListRequest(for: .openai, apiKey: apiKey)

        let data = try await validatedData(for: request, provider: .openai, apiKey: apiKey)
        let response = try JSONDecoder().decode(OpenAIModelsResponse.self, from: data)
        let modelIDs = try Self.validatedModelIDs(response.data.map(\.id))
            .filter(Self.isOpenAIChatModel)
        return AIChatModelCatalog.modelPresets(modelIDs)
    }

    private func fetchClaudeModels(apiKey: String) async throws -> [AIChatModelPreset] {
        let request = try Self.requiredModelListRequest(for: .claude, apiKey: apiKey)

        let data = try await validatedData(for: request, provider: .claude, apiKey: apiKey)
        let response = try JSONDecoder().decode(ClaudeModelsResponse.self, from: data)
        let modelIDs = try Self.validatedModelIDs(response.data.map(\.id))
            .filter { $0.lowercased().hasPrefix("claude-") }
        return AIChatModelCatalog.modelPresets(modelIDs)
    }

    private func fetchGeminiModels(apiKey: String) async throws -> [AIChatModelPreset] {
        let request = try Self.requiredModelListRequest(for: .gemini, apiKey: apiKey)

        let data = try await validatedData(for: request, provider: .gemini, apiKey: apiKey)
        let response = try JSONDecoder().decode(GeminiModelsResponse.self, from: data)
        guard response.models.count <= Self.maximumModelCount else {
            throw AITransportError.modelListItemLimitExceeded
        }
        let fetchedModelIDs = response.models.compactMap { model -> String? in
            let methods = model.supportedGenerationMethods ?? []
            guard methods.contains("generateContent") else { return nil }
            return model.baseModelID ?? Self.stripGeminiModelPrefix(model.name)
        }
        let modelIDs = try Self.validatedModelIDs(fetchedModelIDs)
        return AIChatModelCatalog.modelPresets(modelIDs)
    }

    private func fetchMiniMaxModels(apiKey: String) async throws -> [AIChatModelPreset] {
        let request = try Self.requiredModelListRequest(for: .minimax, apiKey: apiKey)

        let data = try await validatedData(for: request, provider: .minimax, apiKey: apiKey)
        let response = try JSONDecoder().decode(OpenAIModelsResponse.self, from: data)
        let modelIDs = try Self.validatedModelIDs(response.data.map(\.id))
            .filter { $0.lowercased().hasPrefix("minimax-") }
        return AIChatModelCatalog.modelPresets(modelIDs)
    }

    private func validatedData(
        for request: URLRequest,
        provider: AIProvider,
        apiKey: String
    ) async throws -> Data {
        if let transport {
            return try await transport.data(
                for: request,
                provider: provider,
                redacting: [apiKey]
            )
        }

        guard let fetchData else {
            throw AITransportError.invalidHTTPResponse
        }
        let (data, response) = try await fetchData(request)
        guard data.count <= AITransportLimits.modelList.maxBufferedResponseBytes else {
            throw AITransportError.bufferedResponseTooLarge
        }
        guard let http = response as? HTTPURLResponse else {
            throw AITransportError.invalidHTTPResponse
        }
        guard let requestURL = request.url,
              let responseURL = http.url,
              try AIEndpointPolicy.validate(requestURL, provider: provider)
                == AIEndpointPolicy.validate(responseURL, provider: provider) else {
            throw AITransportError.responseOriginMismatch
        }
        guard (200..<300).contains(http.statusCode) else {
            let bounded = data.prefix(AITransportLimits.modelList.maxErrorResponseBytes)
            var errorText = String(decoding: bounded, as: UTF8.self)
            if !apiKey.isEmpty {
                errorText = errorText.replacingOccurrences(of: apiKey, with: "[REDACTED]")
            }
            throw AIServiceError.httpError(http.statusCode, errorText)
        }
        return data
    }

    private static func requiredModelListRequest(
        for provider: AIProvider,
        apiKey: String
    ) throws -> URLRequest {
        guard let request = try modelListRequest(for: provider, apiKey: apiKey) else {
            throw AITransportError.unsafeEndpoint
        }
        return request
    }

    private static func modelListRequest(
        for provider: AIProvider,
        apiKey: String
    ) throws -> URLRequest? {
        let endpoint: String
        switch provider {
        case .openai:
            endpoint = "https://api.openai.com/v1/models"
        case .claude:
            endpoint = "https://api.anthropic.com/v1/models"
        case .gemini:
            endpoint = "https://generativelanguage.googleapis.com/v1beta/models"
        case .minimax:
            endpoint = "https://api.minimax.io/v1/models"
        case .apple, .whisperLocal:
            return nil
        }

        guard let url = URL(string: endpoint) else {
            throw AITransportError.unsafeEndpoint
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        switch provider {
        case .openai, .minimax:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        case .claude:
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .gemini:
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        case .apple, .whisperLocal:
            break
        }
        return request
    }

    // MARK: - Filtering

    private static func isOpenAIChatModel(_ modelID: String) -> Bool {
        let lower = modelID.lowercased()
        let excludedFragments = [
            "audio",
            "dall-e",
            "embedding",
            "image",
            "moderation",
            "realtime",
            "tts",
            "transcribe",
            "whisper",
        ]
        guard !excludedFragments.contains(where: { lower.contains($0) }) else {
            return false
        }
        return lower.hasPrefix("gpt-")
            || lower.hasPrefix("chatgpt-")
            || lower.hasPrefix("o")
    }

    private static func stripGeminiModelPrefix(_ modelName: String) -> String {
        if modelName.hasPrefix("models/") {
            return String(modelName.dropFirst("models/".count))
        }
        return modelName
    }

    private static func validatedModelIDs(_ modelIDs: [String]) throws -> [String] {
        guard modelIDs.count <= maximumModelCount else {
            throw AITransportError.modelListItemLimitExceeded
        }
        guard modelIDs.allSatisfy({ modelID in
            !modelID.isEmpty && modelID.utf8.count <= maximumModelIDByteCount
        }) else {
            throw AITransportError.invalidModelIdentifier
        }
        return modelIDs
    }
}

// MARK: - DTOs

private struct OpenAIModelsResponse: Decodable {
    struct Model: Decodable {
        let id: String
    }

    let data: [Model]
}

private struct ClaudeModelsResponse: Decodable {
    struct Model: Decodable {
        let id: String
    }

    let data: [Model]
}

private struct GeminiModelsResponse: Decodable {
    struct Model: Decodable {
        let name: String
        let baseModelID: String?
        let supportedGenerationMethods: [String]?

        private enum CodingKeys: String, CodingKey {
            case name
            case baseModelID = "baseModelId"
            case supportedGenerationMethods
        }
    }

    let models: [Model]
}
