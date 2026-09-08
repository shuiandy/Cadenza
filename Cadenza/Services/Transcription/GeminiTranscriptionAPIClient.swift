import Foundation

struct GeminiTranscriptionAPIClient: Sendable {
    private static let baseURL = "https://generativelanguage.googleapis.com/v1beta/models"
    /// The Interactions API names the model in the body, so unlike
    /// `generateContent` this endpoint is a fixed path.
    private static let interactionsURL = "https://generativelanguage.googleapis.com/v1beta/interactions"
    private static let allowedModelCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
    )

    private let apiKey: String
    private let model: String
    private let transport: HardenedAITransport

    init(
        apiKey: String,
        model: String,
        transport: HardenedAITransport = .transcription
    ) {
        self.apiKey = apiKey
        self.model = model
        self.transport = transport
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
        guard let url = URL(string: Self.interactionsURL) else {
            throw AITransportError.unsafeEndpoint
        }
        return try await post(body, to: url)
    }

    private func post(_ body: Data, to url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 300

        return try await transport.data(
            for: request,
            provider: .gemini,
            redacting: [apiKey]
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
        guard var components = URLComponents(string: Self.baseURL) else {
            throw AITransportError.unsafeEndpoint
        }
        components.path += "/\(model):generateContent"
        guard let url = components.url else {
            throw AITransportError.unsafeEndpoint
        }
        return url
    }
}
