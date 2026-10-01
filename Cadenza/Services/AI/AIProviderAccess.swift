import Foundation

/// How requests for one AI provider reach it.
///
/// Signed out, the device calls the provider with the key in its own Keychain.
/// Signed in to a Cadenza account whose server serves cloud keys, it calls the
/// Cadenza server instead, which attaches the key stored in the account's
/// vault: the key never reaches the device, and the request and response are
/// otherwise the provider's own. Services build the same request either way;
/// only the base URL and the credential differ.
struct AIProviderAccess: Sendable, Equatable {
    enum Route: Sendable, Equatable {
        /// Straight to the provider with the device's own key.
        case direct(apiKey: String)
        /// Through the Cadenza server. `apiBase` is the account's bound API
        /// base (…/api/v1); the session token only ever goes to that origin.
        case cadenza(apiBase: URL, sessionToken: String)
    }

    let provider: AIProvider
    let route: Route

    static func direct(_ provider: AIProvider, apiKey: String) -> AIProviderAccess {
        AIProviderAccess(provider: provider, route: .direct(apiKey: apiKey))
    }

    /// The provider's name on the Cadenza server, or nil for providers that
    /// run on the device and have no key.
    static func cadenzaName(for provider: AIProvider) -> String? {
        switch provider {
        case .openai: "openai"
        case .claude: "anthropic"
        case .gemini: "gemini"
        case .minimax: "minimax"
        case .apple, .whisperLocal: nil
        }
    }

    static func directOrigin(for provider: AIProvider) -> String? {
        switch provider {
        case .openai: "https://api.openai.com"
        case .claude: "https://api.anthropic.com"
        case .gemini: "https://generativelanguage.googleapis.com"
        case .minimax: "https://api.minimax.io"
        case .apple, .whisperLocal: nil
        }
    }

    var viaCadenza: Bool {
        if case .cadenza = route { return true }
        return false
    }

    /// The URL for a provider API path such as `/v1/messages`.
    func url(path: String, queryItems: [URLQueryItem] = []) throws -> URL {
        let base: String
        switch route {
        case .direct:
            guard let origin = Self.directOrigin(for: provider) else {
                throw AITransportError.unsafeEndpoint
            }
            base = origin
        case .cadenza(let apiBase, _):
            guard let name = Self.cadenzaName(for: provider) else {
                throw AITransportError.unsafeEndpoint
            }
            base = apiBase.appendingPathComponent("ai/proxy/\(name)").absoluteString
        }
        guard var components = URLComponents(string: base + path) else {
            throw AITransportError.unsafeEndpoint
        }
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let url = components.url else {
            throw AITransportError.unsafeEndpoint
        }
        return url
    }

    /// Where a realtime credential for one connection is minted, when the
    /// route goes through Cadenza.
    var realtimeCredentialsURL: URL? {
        guard case .cadenza(let apiBase, _) = route else { return nil }
        return apiBase.appendingPathComponent("ai/realtime/credentials")
    }

    /// Attaches this route's credential, replacing any already set.
    func authorize(_ request: inout URLRequest) {
        for header in ["Authorization", "x-api-key", "x-goog-api-key"] {
            request.setValue(nil, forHTTPHeaderField: header)
        }
        switch route {
        case .direct(let apiKey):
            switch provider {
            case .claude:
                request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            case .gemini:
                request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
            case .openai, .minimax, .apple, .whisperLocal:
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
        case .cadenza(_, let sessionToken):
            request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        }
    }

    /// Values the transport keeps out of logs and error messages.
    var secrets: [String] {
        switch route {
        case .direct(let apiKey): [apiKey]
        case .cadenza(_, let sessionToken): [sessionToken]
        }
    }

    /// The raw key for code that talks to a provider without an HTTP request
    /// this type builds, such as a realtime socket. Nil through Cadenza, where
    /// the device never holds the key.
    var directAPIKey: String? {
        if case .direct(let apiKey) = route { return apiKey }
        return nil
    }
}

/// An error the Cadenza server raised itself while serving an AI call on the
/// account's vault key, as opposed to a provider error it passed through.
/// The server marks these with `X-Cadenza-Proxy-Error`.
struct CadenzaAIAccessError: Error, LocalizedError, Equatable {
    let code: String

    static let headerName = "X-Cadenza-Proxy-Error"

    /// The account's vault state behind this error may have changed, so the
    /// key status shown to the user should be refreshed.
    var invalidatesKeyStatus: Bool {
        ["ai_key_missing", "ai_key_invalid", "unauthenticated", "ai_proxy_disabled"].contains(code)
    }

    var errorDescription: String? { localizedMessage() }

    func localizedMessage(locale: Locale? = nil) -> String {
        switch code {
        case "ai_key_missing":
            return LocalizedBundle.string(
                "No API key for this provider is stored in your Cadenza account. Add one in Settings.",
                locale: locale
            )
        case "ai_key_invalid":
            return LocalizedBundle.string(
                "The provider rejected the API key stored in your Cadenza account. Replace it in Settings.",
                locale: locale
            )
        case "unauthenticated":
            return LocalizedBundle.string(
                "Your Cadenza session has expired. Sign in again to use the API keys stored in your account.",
                locale: locale
            )
        case "ai_usage_limit":
            return LocalizedBundle.string(
                "Your Cadenza account reached today's AI usage limit. Try again tomorrow.",
                locale: locale
            )
        case "rate_limited":
            return LocalizedBundle.string(
                "Too many AI requests from your Cadenza account right now. Try again in a moment.",
                locale: locale
            )
        case "ai_proxy_disabled":
            return LocalizedBundle.string(
                "API keys stored in your Cadenza account are temporarily unavailable. Try again later.",
                locale: locale
            )
        default:
            return LocalizedBundle.string(
                "Cadenza couldn't reach the AI provider with the API key stored in your account. Try again later.",
                locale: locale
            )
        }
    }
}

extension Notification.Name {
    /// Posted when a request made through Cadenza fails in a way that may
    /// change the account's vault key status (a missing or rejected key, an
    /// expired session). The credential resolver refreshes on it.
    static let cadenzaAIAccessDidFail = Notification.Name("CadenzaAIAccessDidFail")
}
