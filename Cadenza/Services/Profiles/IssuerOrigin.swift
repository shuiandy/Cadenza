import CryptoKit
import Foundation

/// Token security boundary for an account session (INV-7): the normalized
/// origin of the backend that issued the token. Kept separate from the full
/// API base URL, which may carry a path such as `/api/v1` — the origin
/// decides where a token may be sent, the base URL decides how requests are
/// built.
struct IssuerOrigin: Equatable, Hashable, Sendable {
    /// Canonical form: lowercase scheme, lowercase host, explicit port —
    /// no path, query, fragment, or credentials.
    let normalized: String

    enum NormalizationError: Error, Equatable {
        case notAURL(String)
        case unsupportedScheme(String)
        case missingHost
        case notCanonical(stored: String, canonical: String)
    }

    init(url: URL) throws {
        guard let rawScheme = url.scheme else {
            throw NormalizationError.unsupportedScheme("")
        }
        let scheme = rawScheme.lowercased()
        let defaultPort: Int
        switch scheme {
        case "https": defaultPort = 443
        case "http": defaultPort = 80
        default: throw NormalizationError.unsupportedScheme(scheme)
        }
        guard let rawHost = url.host, !rawHost.isEmpty else {
            throw NormalizationError.missingHost
        }
        let host = rawHost.lowercased()
        // Foundation strips brackets from IPv6 literals; restore them so
        // the canonical form stays parseable as a URL.
        let hostComponent = host.contains(":") ? "[\(host)]" : host
        let port = url.port ?? defaultPort
        normalized = "\(scheme)://\(hostComponent):\(port)"
    }

    /// Re-validates a stored origin string (registry `issuerOrigin` field).
    /// Stored values are always written in canonical form; one that does
    /// not normalize to itself is rejected as corrupt rather than silently
    /// reinterpreted — origin identity is never guessed.
    init(validating raw: String) throws {
        guard let url = URL(string: raw), url.scheme != nil else {
            throw NormalizationError.notAURL(raw)
        }
        try self.init(url: url)
        guard normalized == raw else {
            throw NormalizationError.notCanonical(stored: raw, canonical: normalized)
        }
    }

    /// First 16 hex characters of SHA-256 over the normalized origin — the
    /// Keychain account component that pins a token to its issuer (§5.2).
    var originKey: String {
        let digest = SHA256.hash(data: Data(normalized.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(16))
    }

    /// INV-7 request gate: a token bound to this origin may only be sent to
    /// URLs whose origin normalizes to the same value. Unparseable target
    /// URLs never match.
    func covers(requestURL: URL) -> Bool {
        guard let target = try? IssuerOrigin(url: requestURL) else { return false }
        return target == self
    }
}
