import Foundation

enum GoogleCalendarCredentialError: Error, LocalizedError, Equatable {
    case missingClientID

    var errorDescription: String? {
        switch self {
        case .missingClientID:
            return String(localized: "Google Client ID cannot be empty.")
        }
    }
}

struct GoogleCalendarConnectionPresentation: Equatable {
    enum Phase: Equatable {
        case connected
        case connecting
        case disconnected
        case error
    }

    let phase: Phase
    let statusText: String

    static func make(
        isConnected: Bool,
        isConnecting: Bool,
        error: String?
    ) -> Self {
        if let error, !error.isEmpty {
            return Self(phase: .error, statusText: error)
        }
        if isConnecting {
            return Self(phase: .connecting, statusText: String(localized: "Connecting..."))
        }
        if isConnected {
            return Self(phase: .connected, statusText: String(localized: "Connected"))
        }
        return Self(phase: .disconnected, statusText: String(localized: "Not connected"))
    }
}

/// Google Calendar integration via OAuth2 with PKCE.
@Observable @MainActor
final class GoogleCalendarService {
    static let clientIDDefaultsKey = "googleCalendar.clientID"
    static let clientSecretKey = "googleCalendar.clientSecret"

    struct OAuthCredentials: Sendable {
        let clientID: String
        let clientSecret: String
    }

    struct TokenExchangeRequest: Sendable {
        let tokenURL: URL
        let code: String
        let clientID: String
        let clientSecret: String?
        let redirectURI: String
        let codeVerifier: String
    }

    typealias CredentialsProvider = @MainActor () -> OAuthCredentials
    typealias StateGenerator = @Sendable () -> String
    typealias TokenExchange = @Sendable (TokenExchangeRequest) async throws -> OAuthTokenManager.TokenData
    typealias TokenStore = @MainActor (OAuthTokenManager.TokenData) throws -> Void
    typealias ClientSecretReader = @MainActor () -> String
    typealias ClientSecretWriter = @MainActor (String) throws -> Void

    private let defaults: UserDefaults
    private let tokenManager: OAuthTokenManager
    private let callbackServer: any OAuthCallbackServing
    private let credentialsProvider: CredentialsProvider?
    private let stateGenerator: StateGenerator
    private let tokenExchange: TokenExchange
    private let tokenStore: TokenStore
    private let clientSecretReader: ClientSecretReader
    private let clientSecretWriter: ClientSecretWriter

    var isConnecting = false
    var error: String?

    /// Closure to open a URL in the user's browser.
    var openURLHandler: (@Sendable (URL) -> Void)?

    // OAuth2 config — user must set these in Settings
    var clientID: String {
        defaults.string(forKey: Self.clientIDDefaultsKey) ?? ""
    }

    var clientSecret: String {
        clientSecretReader()
    }

    private let authURL = "https://accounts.google.com/o/oauth2/v2/auth"
    private let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    private let calendarAPIBase = "https://www.googleapis.com/calendar/v3"
    private let scopes = "https://www.googleapis.com/auth/calendar.readonly"

    var isConnected: Bool { tokenManager.isConnected("google") }

    init(
        tokenManager: OAuthTokenManager,
        callbackServer: any OAuthCallbackServing = OAuthCallbackServer(port: 8484),
        credentialsProvider: CredentialsProvider? = nil,
        stateGenerator: @escaping StateGenerator = PKCE.generateVerifier,
        tokenExchange: TokenExchange? = nil,
        tokenStore: TokenStore? = nil,
        defaults: UserDefaults = .standard,
        clientSecretReader: ClientSecretReader? = nil,
        clientSecretWriter: ClientSecretWriter? = nil
    ) {
        self.defaults = defaults
        self.tokenManager = tokenManager
        self.callbackServer = callbackServer
        self.credentialsProvider = credentialsProvider
        self.stateGenerator = stateGenerator
        self.tokenExchange = tokenExchange ?? { request in
            try await OAuthTokenManager.exchangeCodeForTokens(
                tokenURL: request.tokenURL,
                code: request.code,
                clientID: request.clientID,
                clientSecret: request.clientSecret,
                redirectURI: request.redirectURI,
                codeVerifier: request.codeVerifier
            )
        }
        self.tokenStore = tokenStore ?? { tokens in
            try tokenManager.store(tokens: tokens, for: "google")
        }
        self.clientSecretReader = clientSecretReader ?? {
            KeychainManager.shared.getWithMigration(
                Self.clientSecretKey,
                defaults: defaults
            )
        }
        self.clientSecretWriter = clientSecretWriter ?? { value in
            try KeychainManager.shared.set(value, forKey: Self.clientSecretKey)
        }
    }

    // MARK: - Configuration

    func configuredCredentials() -> OAuthCredentials {
        OAuthCredentials(clientID: clientID, clientSecret: clientSecret)
    }

    /// Persists the secret first. Public configuration and any legacy
    /// plaintext are changed only after the Keychain mutation succeeds.
    func saveCredentials(clientID: String, clientSecret: String) throws {
        let normalizedClientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSecret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedClientID.isEmpty else {
            throw GoogleCalendarCredentialError.missingClientID
        }
        try clientSecretWriter(normalizedSecret)
        defaults.set(normalizedClientID, forKey: Self.clientIDDefaultsKey)
        defaults.removeObject(forKey: Self.clientSecretKey)
    }

    // MARK: - OAuth2 Connect

    func connect() async throws {
        guard !isConnecting else {
            throw OAuthError.callbackInProgress
        }

        let credentials: OAuthCredentials
        if let credentialsProvider {
            credentials = credentialsProvider()
        } else {
            credentials = configuredCredentials()
            guard !credentials.clientID.isEmpty else {
                error = String(localized: "Google Client ID is not configured.")
                return
            }
        }

        guard !credentials.clientID.isEmpty else {
            error = String(localized: "Google Client ID is not configured.")
            return
        }

        isConnecting = true
        error = nil
        defer { isConnecting = false }

        // Generate a per-attempt PKCE pair and opaque state nonce.
        let codeVerifier = PKCE.generateVerifier()
        let codeChallenge = PKCE.challenge(forVerifier: codeVerifier)
        let state = stateGenerator()

        // Build authorization URL
        var components = URLComponents(string: authURL)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: credentials.clientID),
            URLQueryItem(name: "redirect_uri", value: callbackServer.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "state", value: state),
        ]
        guard let authorizeURL = components.url else {
            throw OAuthError.tokenExchangeFailed("Failed to build authorize URL")
        }

        guard let handler = openURLHandler else {
            NSLog("[GoogleCalendar] ERROR: openURLHandler is nil, cannot open browser")
            throw OAuthError.tokenExchangeFailed("Cannot open browser — URL handler not configured")
        }

        // The listener must bind before the browser opens. The callback server
        // owns attempt-scoped cancellation, including cancellation that arrives
        // before its continuation/listener has been installed.
        let result = try await callbackServer.waitForCallback(expectedState: state) {
            Task { @MainActor in handler(authorizeURL) }
        }

        guard result.state == state else {
            throw OAuthError.stateMismatch
        }
        guard !result.code.isEmpty else {
            throw OAuthError.invalidResponse
        }

        // Exchange code for tokens
        let tokens: OAuthTokenManager.TokenData
        do {
            tokens = try await tokenExchange(TokenExchangeRequest(
                tokenURL: tokenURL,
                code: result.code,
                clientID: credentials.clientID,
                clientSecret: credentials.clientSecret.isEmpty ? nil : credentials.clientSecret,
                redirectURI: callbackServer.redirectURI,
                codeVerifier: codeVerifier
            ))
        } catch is CancellationError {
            throw CancellationError()
        } catch let oauthError as OAuthError {
            throw oauthError
        } catch {
            NSLog("[GoogleCalendar] token exchange failed: %@", String(describing: error))
            throw OAuthError.tokenExchangeFailed(String(describing: error))
        }

        // A custom or mocked exchange may not cooperate with task
        // cancellation. Never persist credentials after cancellation anyway.
        try Task.checkCancellation()
        do {
            try tokenStore(tokens)
        } catch {
            NSLog("[GoogleCalendar] token persistence failed: %@", String(describing: error))
            throw OAuthError.tokenExchangeFailed(String(describing: error))
        }
    }

    func disconnect() throws {
        try tokenManager.removeTokens(for: "google")
    }

    // MARK: - Fetch Events

    func fetchEvents(from startDate: Date, to endDate: Date) async throws -> [MeetingEvent] {
        let accessToken: String
        do {
            accessToken = try await tokenManager.validAccessToken(for: "google") { refreshToken in
                try await OAuthTokenManager.refreshAccessToken(
                    tokenURL: self.tokenURL,
                    refreshToken: refreshToken,
                    clientID: self.clientID,
                    clientSecret: self.clientSecret.isEmpty ? nil : self.clientSecret
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let oauthError as OAuthError {
            throw oauthError
        } catch {
            NSLog("[GoogleCalendar] token refresh failed: %@", String(describing: error))
            throw OAuthError.networkFailure
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        var components = URLComponents(string: "\(calendarAPIBase)/calendars/primary/events")!
        components.queryItems = [
            URLQueryItem(name: "timeMin", value: formatter.string(from: startDate)),
            URLQueryItem(name: "timeMax", value: formatter.string(from: endDate)),
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "orderBy", value: "startTime"),
            URLQueryItem(name: "maxResults", value: "250"),
        ]

        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            NSLog("[GoogleCalendar] event request failed: %@", String(describing: error))
            throw OAuthError.networkFailure
        }
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw OAuthError.invalidResponse
        }

        return parseEvents(from: data)
    }

    // MARK: - Parse

    private func parseEvents(from data: Data) -> [MeetingEvent] {
        GoogleEventParser.parse(data)
    }

}
