import Foundation

/// Zoom meeting integration via OAuth2 Authorization Code + PKCE (public client).
///
/// Cadenza ships as a Zoom Marketplace **public PKCE** OAuth app — the client
/// secret is intentionally absent from the binary (see `ZoomConfig`). The
/// authorization request carries a SHA-256 `code_challenge`; the token exchange
/// proves possession of the matching `code_verifier`. No `Authorization` header
/// is sent on token / refresh calls.
@Observable @MainActor
final class ZoomMeetingService {
    typealias TokenRemover = @MainActor () throws -> Void

    private let tokenManager: OAuthTokenManager
    private let tokenRemover: TokenRemover
    private let callbackServer = OAuthCallbackServer(port: 8485)

    var isConnecting = false
    var error: String?

    /// Closure to open a URL in the user's browser. Sendable so the caller
    /// (the loopback callback queue) can invoke it after the listener binds.
    var openURLHandler: (@Sendable (URL) -> Void)?

    /// Embedded public client ID — see `ZoomConfig`. No secret involved.
    var clientID: String { ZoomConfig.publicClientID }

    private let authURL = "https://zoom.us/oauth/authorize"
    private let tokenURL = URL(string: "https://zoom.us/oauth/token")!
    private let apiBase = "https://api.zoom.us/v2"

    var isConnected: Bool { tokenManager.isConnected("zoom") }

    init(
        tokenManager: OAuthTokenManager,
        tokenRemover: TokenRemover? = nil
    ) {
        self.tokenManager = tokenManager
        self.tokenRemover = tokenRemover ?? {
            try tokenManager.removeTokens(for: "zoom")
        }
        // Best-effort cleanup of legacy BYO-credentials state from prior versions.
        // (The user no longer enters their own client_id / client_secret.)
        Self.purgeLegacyCredentials()
    }

    // MARK: - OAuth2 Connect (PKCE)

    func connect() async throws {
        isConnecting = true
        error = nil
        defer { isConnecting = false }

        guard let handler = openURLHandler else {
            NSLog("[Zoom] ERROR: openURLHandler is nil, cannot open browser")
            throw OAuthError.tokenExchangeFailed("Cannot open browser — URL handler not configured")
        }

        // Per-attempt PKCE pair + opaque state for CSRF protection.
        let codeVerifier = PKCE.generateVerifier()
        let codeChallenge = PKCE.challenge(forVerifier: codeVerifier)
        let state = PKCE.generateVerifier()  // 32-byte URL-safe random; reused as state nonce.

        // Build authorization URL.
        var components = URLComponents(string: authURL)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: callbackServer.redirectURI),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        guard let authorizeURL = components.url else {
            throw OAuthError.tokenExchangeFailed("Failed to build authorize URL")
        }

        // Open the browser ONLY after the loopback listener has bound,
        // so a port conflict surfaces before the user is sent to Zoom.
        // The `onListenerReady` closure runs on the server's private queue;
        // hop back to MainActor before invoking the (MainActor) URL handler.
        let result = try await callbackServer.waitForCallback(expectedState: state) {
            Task { @MainActor in handler(authorizeURL) }
        }

        // CSRF defense: confirm the redirect carried the same state we sent.
        guard result.state == state else {
            throw OAuthError.stateMismatch
        }

        // Public-PKCE token exchange: no client_secret, no Authorization header.
        let tokens = try await exchangeCode(result.code, codeVerifier: codeVerifier)
        do {
            try tokenManager.store(tokens: tokens, for: "zoom")
        } catch {
            NSLog("[Zoom] token persistence failed: %@", String(describing: error))
            throw OAuthError.tokenExchangeFailed(String(describing: error))
        }
    }

    func disconnect() throws {
        do {
            try tokenRemover()
            error = nil
        } catch {
            self.error = String(localized: "Zoom could not be disconnected because its secure tokens could not be removed. Please try again.")
            throw error
        }
    }

    // MARK: - Fetch Meetings

    func fetchUpcomingMeetings() async throws -> [MeetingEvent] {
        let accessToken: String
        do {
            accessToken = try await tokenManager.validAccessToken(for: "zoom") { refreshToken in
                try await self.refreshToken(refreshToken)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let oauthError as OAuthError {
            throw oauthError
        } catch {
            NSLog("[Zoom] token refresh failed: %@", String(describing: error))
            throw OAuthError.networkFailure
        }

        var request = URLRequest(url: URL(string: "\(apiBase)/users/me/meetings?type=upcoming&page_size=50")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            NSLog("[Zoom] meeting request failed: %@", String(describing: error))
            throw OAuthError.networkFailure
        }
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw OAuthError.invalidResponse
        }

        return parseMeetings(from: data)
    }

    // MARK: - Token Exchange (Public PKCE — no secret, no Auth header)

    private func exchangeCode(_ code: String, codeVerifier: String) async throws -> OAuthTokenManager.TokenData {
        let body = formEncode([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": callbackServer.redirectURI,
            "client_id": clientID,
            "code_verifier": codeVerifier,
        ])

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            NSLog("[Zoom] token exchange request failed: %@", String(describing: error))
            throw OAuthError.networkFailure
        }
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw OAuthError.tokenExchangeFailed(errorBody)
        }

        return try parseTokenResponse(data)
    }

    private func refreshToken(_ refreshToken: String) async throws -> OAuthTokenManager.TokenData {
        let body = formEncode([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ])

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            NSLog("[Zoom] token refresh request failed: %@", String(describing: error))
            throw OAuthError.networkFailure
        }
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw OAuthError.refreshFailed
        }

        var tokens = try parseTokenResponse(data)
        if tokens.refreshToken == nil {
            tokens.refreshToken = refreshToken
        }
        return tokens
    }

    /// Strict `application/x-www-form-urlencoded` body builder.
    /// `.urlQueryAllowed` leaves `+`, `&`, `=` unescaped, which corrupts form
    /// bodies — a Zoom code or refresh token containing `+` would decode to
    /// space on the server. Use the unreserved-only set per RFC 3986 §2.3.
    private func formEncode(_ params: [String: String]) -> String {
        let unreserved = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return params.map { key, value in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: unreserved) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
            return "\(encodedKey)=\(encodedValue)"
        }.joined(separator: "&")
    }

    private func parseTokenResponse(_ data: Data) throws -> OAuthTokenManager.TokenData {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            throw OAuthError.invalidResponse
        }

        return OAuthTokenManager.TokenData(
            accessToken: accessToken,
            refreshToken: json["refresh_token"] as? String,
            expiresAt: (json["expires_in"] as? TimeInterval).map { Date().addingTimeInterval($0) },
            tokenType: json["token_type"] as? String,
            scope: json["scope"] as? String
        )
    }

    // MARK: - Legacy cleanup

    /// Removes the BYO client_id / client_secret state used by Cadenza < 0.2.
    /// Idempotent and silent — runs once per launch.
    private static func purgeLegacyCredentials() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "zoom.clientID") != nil {
            defaults.removeObject(forKey: "zoom.clientID")
        }
        // Keychain copy of the secret (and any UserDefaults migration leftover).
        try? KeychainManager.shared.remove("zoom.clientSecret")
        if defaults.object(forKey: "zoom.clientSecret") != nil {
            defaults.removeObject(forKey: "zoom.clientSecret")
        }
    }

    // MARK: - Parse Meetings

    private func parseMeetings(from data: Data) -> [MeetingEvent] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let meetings = json["meetings"] as? [[String: Any]] else { return [] }

        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoBasic = ISO8601DateFormatter()
        isoBasic.formatOptions = [.withInternetDateTime]

        return meetings.compactMap { meeting -> MeetingEvent? in
            guard let id = meeting["id"] as? Int,
                  let topic = meeting["topic"] as? String,
                  let startTimeStr = meeting["start_time"] as? String,
                  let duration = meeting["duration"] as? Int,
                  let startDate = isoFractional.date(from: startTimeStr) ?? isoBasic.date(from: startTimeStr) else { return nil }

            let endDate = startDate.addingTimeInterval(TimeInterval(duration * 60))
            let joinURL = (meeting["join_url"] as? String).flatMap { URL(string: $0) }

            return MeetingEvent(
                id: "zoom_\(id)",
                title: topic,
                startDate: startDate,
                endDate: endDate,
                meetingURL: joinURL,
                meetingApp: .zoom,
                calendarName: "Zoom",
                notes: meeting["agenda"] as? String,
                source: .zoom
            )
        }
    }
}
