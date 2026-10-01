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
        try await fetchPresets(for: provider, access: .direct(provider, apiKey: apiKey))
    }

    /// The provider's chat models, listed with the device's key or through
    /// the Cadenza account's vault key.
    func fetchPresets(for provider: AIProvider, access: AIProviderAccess) async throws -> [AIChatModelPreset] {
        let access = AIProviderAccess(provider: provider, route: access.route)
        switch provider {
        case .openai:
            return try await fetchOpenAIModels(access: access)
        case .claude:
            return try await fetchClaudeModels(access: access)
        case .gemini:
            return try await fetchGeminiModels(access: access)
        case .minimax:
            return try await fetchMiniMaxModels(access: access)
        case .apple, .whisperLocal:
            return AIChatModelCatalog.fallbackPresets(for: provider)
        }
    }

    /// Checks a key the user typed on this device against the provider. Keys
    /// stored in a Cadenza account are checked by the server instead.
    func validateCredential(for provider: AIProvider, apiKey: String) async throws {
        let access = AIProviderAccess.direct(provider, apiKey: apiKey)
        guard var request = try Self.modelListRequest(access: access) else {
            return
        }
        request.timeoutInterval = 10
        _ = try await validatedData(for: request, access: access)
    }

    // MARK: - Provider Fetching

    private func fetchOpenAIModels(access: AIProviderAccess) async throws -> [AIChatModelPreset] {
        let request = try Self.requiredModelListRequest(access: access)

        let data = try await validatedData(for: request, access: access)
        let response = try JSONDecoder().decode(OpenAIModelsResponse.self, from: data)
        let modelIDs = try Self.validatedModelIDs(response.data.map(\.id))
            .filter(Self.isOpenAIChatModel)
        return AIChatModelCatalog.modelPresets(modelIDs)
    }

    private func fetchClaudeModels(access: AIProviderAccess) async throws -> [AIChatModelPreset] {
        let request = try Self.requiredModelListRequest(access: access)

        let data = try await validatedData(for: request, access: access)
        let response = try JSONDecoder().decode(ClaudeModelsResponse.self, from: data)
        let modelIDs = try Self.validatedModelIDs(response.data.map(\.id))
            .filter { $0.lowercased().hasPrefix("claude-") }
        return AIChatModelCatalog.modelPresets(modelIDs)
    }

    private func fetchGeminiModels(access: AIProviderAccess) async throws -> [AIChatModelPreset] {
        let request = try Self.requiredModelListRequest(access: access)

        let data = try await validatedData(for: request, access: access)
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

    private func fetchMiniMaxModels(access: AIProviderAccess) async throws -> [AIChatModelPreset] {
        let request = try Self.requiredModelListRequest(access: access)

        let data = try await validatedData(for: request, access: access)
        let response = try JSONDecoder().decode(OpenAIModelsResponse.self, from: data)
        let modelIDs = try Self.validatedModelIDs(response.data.map(\.id))
            .filter { $0.lowercased().hasPrefix("minimax-") }
        return AIChatModelCatalog.modelPresets(modelIDs)
    }

    private func validatedData(
        for request: URLRequest,
        access: AIProviderAccess
    ) async throws -> Data {
        let provider = access.provider
        if let transport {
            return try await transport.data(
                for: request,
                provider: provider,
                redacting: access.secrets,
                viaCadenza: access.viaCadenza
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
        let pinned: AIProvider? = access.viaCadenza ? nil : provider
        guard let requestURL = request.url,
              let responseURL = http.url,
              try AIEndpointPolicy.validate(requestURL, provider: pinned)
                == AIEndpointPolicy.validate(responseURL, provider: pinned) else {
            throw AITransportError.responseOriginMismatch
        }
        guard (200..<300).contains(http.statusCode) else {
            let bounded = data.prefix(AITransportLimits.modelList.maxErrorResponseBytes)
            var errorText = String(decoding: bounded, as: UTF8.self)
            for secret in access.secrets where !secret.isEmpty {
                errorText = errorText.replacingOccurrences(of: secret, with: "[REDACTED]")
            }
            throw AIServiceError.httpError(http.statusCode, errorText)
        }
        return data
    }

    private static func requiredModelListRequest(access: AIProviderAccess) throws -> URLRequest {
        guard let request = try modelListRequest(access: access) else {
            throw AITransportError.unsafeEndpoint
        }
        return request
    }

    private static func modelListRequest(access: AIProviderAccess) throws -> URLRequest? {
        let path: String
        switch access.provider {
        case .openai, .claude, .minimax:
            path = "/v1/models"
        case .gemini:
            path = "/v1beta/models"
        case .apple, .whisperLocal:
            return nil
        }
        var request = URLRequest(url: try access.url(path: path))
        request.httpMethod = "GET"
        access.authorize(&request)
        if access.provider == .claude {
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
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
