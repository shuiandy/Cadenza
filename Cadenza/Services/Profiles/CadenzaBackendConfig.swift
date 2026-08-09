import Foundation

/// Backend endpoint resolution (§5.4, INV-6). The configurable default
/// applies only to NEW logins; a bound profile's issuer and base URL are
/// frozen in its boundAccount and never drift with this setting.
enum CadenzaBackendConfig {
    static let officialAPIBaseURLString = "https://cadenzapp.com/api/v1"
    /// The official web account page. Subscription management is served there
    /// and nowhere else, so the app opens this fixed route instead of deriving
    /// a destination from a response or a configured base URL.
    static let officialAccountURLString = "https://cadenzapp.com/app/settings"
    /// The official web app. Offered only to an account proven to be on the
    /// official service; a self-hosted deployment's address is never guessed.
    static let officialWebAppURLString = "https://cadenzapp.com/app"
    /// Global (device-level) override for the backend new logins target.
    static let defaultsKey = "backend.apiBaseURL.v1"

    struct Resolved: Equatable {
        let origin: IssuerOrigin
        let apiBaseURL: URL
    }

    enum ConfigurationError: Error, Equatable {
        case invalidConfiguredBaseURL(String)
    }

    /// The hardcoded official backend — also the issuer identity of every
    /// pre-profile session, which is why M2 binds against it.
    static func official() -> Resolved {
        guard let url = URL(string: officialAPIBaseURLString),
              let origin = try? IssuerOrigin(url: url) else {
            preconditionFailure("official backend constant must parse")
        }
        return Resolved(origin: origin, apiBaseURL: url)
    }

    /// The official account page, or nil if the constant ever stops parsing.
    static func officialAccountURL() -> URL? {
        URL(string: officialAccountURLString)
    }

    static func officialWebAppURL() -> URL? {
        URL(string: officialWebAppURLString)
    }

    /// Backend for a NEW login: the configured override when present and
    /// valid, the official backend otherwise. An override that does not
    /// parse into an origin refuses the login instead of silently
    /// substituting the official backend.
    static func resolveForNewLogin(defaults: UserDefaults = .standard) throws -> Resolved {
        guard let raw = defaults.string(forKey: defaultsKey),
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return official()
        }
        guard let url = URL(string: raw), let origin = try? IssuerOrigin(url: url) else {
            throw ConfigurationError.invalidConfiguredBaseURL(raw)
        }
        return Resolved(origin: origin, apiBaseURL: url)
    }
}
