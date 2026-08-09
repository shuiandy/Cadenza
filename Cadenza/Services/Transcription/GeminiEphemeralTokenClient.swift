import Foundation

struct GeminiEphemeralTokenClient: Sendable {
    private static let endpoint = "https://generativelanguage.googleapis.com/v1alpha/auth_tokens"
    private static let sessionLifetime: TimeInterval = 2 * 60 * 60
    private static let newSessionLifetime: TimeInterval = 2 * 60

    private let apiKey: String
    private let transport: HardenedAITransport

    init(
        apiKey: String,
        transport: HardenedAITransport = .ephemeralToken
    ) {
        self.apiKey = apiKey
        self.transport = transport
    }

    func mint(at now: Date) async throws -> GeminiEphemeralToken {
        guard let endpointURL = URL(string: Self.endpoint) else {
            throw GeminiEphemeralTokenError.invalidResponse
        }

        let requestBody = GeminiEphemeralTokenRequest(
            uses: 0,
            expireTime: now.addingTimeInterval(Self.sessionLifetime),
            newSessionExpireTime: now.addingTimeInterval(Self.newSessionLifetime)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(requestBody)
        request.timeoutInterval = 10

        let data = try await transport.data(
            for: request,
            provider: .gemini,
            redacting: [apiKey]
        )

        guard let response = try? JSONDecoder().decode(
            GeminiEphemeralTokenResponse.self,
            from: data
        ) else {
            throw GeminiEphemeralTokenError.invalidResponse
        }
        guard GeminiEphemeralToken.isValidName(response.name) else {
            throw GeminiEphemeralTokenError.invalidToken
        }
        return GeminiEphemeralToken(
            name: response.name,
            newSessionExpireTime: requestBody.newSessionExpireTime
        )
    }
}

private struct GeminiEphemeralTokenRequest: Encodable {
    let uses: Int
    let expireTime: Date
    let newSessionExpireTime: Date
}

private struct GeminiEphemeralTokenResponse: Decodable {
    let name: String
}
