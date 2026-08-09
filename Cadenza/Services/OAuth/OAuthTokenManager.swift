import Foundation

/// Manages OAuth token storage, retrieval, and refresh.
/// Stores tokens in Keychain via KeychainManager for security.
@Observable @MainActor
final class OAuthTokenManager {
    private let keychain = KeychainManager.shared
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    struct TokenData: Codable {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date?
        var tokenType: String?
        var scope: String?
    }

    // MARK: - Storage

    func store(tokens: TokenData, for provider: String) throws {
        let data = try encoder.encode(tokens)
        let encoded = data.base64EncodedString()
        try keychain.set(encoded, forKey: "oauth.tokens.\(provider)")
    }

    func tokens(for provider: String) -> TokenData? {
        // Try Keychain first
        if let encoded = keychain.get("oauth.tokens.\(provider)"),
           let data = Data(base64Encoded: encoded) {
            return try? decoder.decode(TokenData.self, from: data)
        }
        // Migrate from UserDefaults if present — only delete after Keychain write succeeds
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: "oauth.tokens.\(provider)"),
           let tokenData = try? decoder.decode(TokenData.self, from: data) {
            if let _ = try? store(tokens: tokenData, for: provider) {
                defaults.removeObject(forKey: "oauth.tokens.\(provider)")
            }
            return tokenData
        }
        return nil
    }

    func removeTokens(for provider: String) throws {
        try keychain.remove("oauth.tokens.\(provider)")
        // Also clean up any leftover UserDefaults entry
        UserDefaults.standard.removeObject(forKey: "oauth.tokens.\(provider)")
    }

    func isConnected(_ provider: String) -> Bool {
        tokens(for: provider) != nil
    }

    // MARK: - Access Token (with auto-refresh)

    func validAccessToken(
        for provider: String,
        refreshHandler: (String) async throws -> TokenData
    ) async throws -> String {
        guard var tokenData = tokens(for: provider) else {
            throw OAuthError.noRefreshToken
        }

        // Check if token is expired (with 60s buffer)
        if let expiresAt = tokenData.expiresAt, Date() >= expiresAt.addingTimeInterval(-60) {
            guard let refreshToken = tokenData.refreshToken else {
                throw OAuthError.noRefreshToken
            }
            tokenData = try await refreshHandler(refreshToken)
            try store(tokens: tokenData, for: provider)
        }

        return tokenData.accessToken
    }

    // MARK: - Token Exchange Helper

    static func exchangeCodeForTokens(
        tokenURL: URL,
        code: String,
        clientID: String,
        clientSecret: String? = nil,
        redirectURI: String,
        codeVerifier: String? = nil,
        additionalParams: [String: String] = [:]
    ) async throws -> TokenData {
        var body: [String: String] = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": clientID,
        ]
        if let secret = clientSecret { body["client_secret"] = secret }
        if let verifier = codeVerifier { body["code_verifier"] = verifier }
        body.merge(additionalParams) { _, new in new }

        let bodyString = body.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)" }
            .joined(separator: "&")

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.httpBody = Data(bodyString.utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw OAuthError.tokenExchangeFailed(errorBody)
        }

        return try parseTokenResponse(data)
    }

    static func refreshAccessToken(
        tokenURL: URL,
        refreshToken: String,
        clientID: String,
        clientSecret: String? = nil
    ) async throws -> TokenData {
        var body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ]
        if let secret = clientSecret { body["client_secret"] = secret }

        let bodyString = body.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)" }
            .joined(separator: "&")

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.httpBody = Data(bodyString.utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw OAuthError.refreshFailed
        }

        var tokens = try parseTokenResponse(data)
        // Some providers don't return a new refresh token; preserve the old one
        if tokens.refreshToken == nil {
            tokens.refreshToken = refreshToken
        }
        return tokens
    }

    private static func parseTokenResponse(_ data: Data) throws -> TokenData {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            throw OAuthError.invalidResponse
        }

        let refreshToken = json["refresh_token"] as? String
        let expiresIn = json["expires_in"] as? TimeInterval
        let tokenType = json["token_type"] as? String
        let scope = json["scope"] as? String

        return TokenData(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresIn.map { Date().addingTimeInterval($0) },
            tokenType: tokenType,
            scope: scope
        )
    }
}
