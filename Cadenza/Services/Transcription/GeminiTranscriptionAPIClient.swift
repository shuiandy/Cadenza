import Foundation

struct GeminiTranscriptionAPIClient: Sendable {
    private static let allowedModelCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
    )

    private let access: AIProviderAccess
    private let model: String
    private let transport: HardenedAITransport

    init(
        access: AIProviderAccess,
        model: String,
        transport: HardenedAITransport = .transcription
    ) {
        self.access = AIProviderAccess(provider: .gemini, route: access.route)
        self.model = model
        self.transport = transport
    }

    init(
        apiKey: String,
        model: String,
        transport: HardenedAITransport = .transcription
    ) {
        self.init(access: .direct(.gemini, apiKey: apiKey), model: model, transport: transport)
    }

    func generateContent(body: Data) async throws -> Data {
        try await post(body, to: try generateContentURL())
    }

    /// `POST /v1beta/interactions`, the surface the gemini-3.5-transcribe
    /// family speaks. The model never reaches the URL here, but it is still
    /// validated so a malformed override fails locally instead of being
    /// echoed into a request body.
    func createInteraction(body: Data) async throws -> Data {
        try validateModel()
        // The Interactions API names the model in the body, so unlike
        // `generateContent` this endpoint is a fixed path.
        return try await post(body, to: try access.url(path: "/v1beta/interactions"))
    }

    private func post(_ body: Data, to url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        access.authorize(&request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 300

        return try await transport.data(
            for: request,
            provider: .gemini,
            redacting: access.secrets,
            viaCadenza: access.viaCadenza
        )
    }

    private func validateModel() throws {
        guard !model.isEmpty,
              model.utf8.count <= 256,
              model.unicodeScalars.allSatisfy(Self.allowedModelCharacters.contains) else {
            throw AITransportError.unsafeEndpoint
        }
    }

    private func generateContentURL() throws -> URL {
        try validateModel()
        return try access.url(path: "/v1beta/models/\(model):generateContent")
    }
}
