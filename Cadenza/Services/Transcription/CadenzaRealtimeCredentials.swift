import Foundation

/// Mints the provider credential for one realtime connection through the
/// Cadenza server, which signs it with the account's vault key. The device
/// then connects to the provider directly; the key itself never reaches it.
/// Each connection, reconnect and Gemini goAway rotation asks again: the
/// credentials are short-lived and single-use by design.
enum CadenzaRealtimeCredentials {
    static func mint(
        access: AIProviderAccess,
        model: String,
        transport: HardenedAITransport = .ephemeralToken
    ) async throws -> String {
        guard let url = access.realtimeCredentialsURL,
              let provider = AIProviderAccess.cadenzaName(for: access.provider) else {
            throw AITransportError.unsafeEndpoint
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        access.authorize(&request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["provider": provider, "model": model])

        let data = try await transport.data(
            for: request,
            provider: access.provider,
            redacting: access.secrets,
            viaCadenza: true
        )
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let credential = json["credential"] as? String,
              !credential.isEmpty else {
            throw AIServiceError.invalidResponse
        }
        return credential
    }
}
