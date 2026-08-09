import Foundation

struct GeminiTranscriptionAPIClient: Sendable {
    private static let baseURL = "https://generativelanguage.googleapis.com/v1beta/models"
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
        var request = URLRequest(url: try endpointURL())
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

    private func endpointURL() throws -> URL {
        guard !model.isEmpty,
              model.utf8.count <= 256,
              model.unicodeScalars.allSatisfy(Self.allowedModelCharacters.contains),
              var components = URLComponents(string: Self.baseURL) else {
            throw AITransportError.unsafeEndpoint
        }
        components.path += "/\(model):generateContent"
        guard let url = components.url else {
            throw AITransportError.unsafeEndpoint
        }
        return url
    }
}
