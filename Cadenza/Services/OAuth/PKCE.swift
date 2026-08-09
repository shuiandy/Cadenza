import CryptoKit
import Foundation

/// RFC 7636 — Proof Key for Code Exchange.
/// Generates a code_verifier (high-entropy random string) and the matching
/// code_challenge (SHA-256 of the verifier, base64url-encoded without padding).
enum PKCE {
    /// Generate a 32-byte random `code_verifier`, base64url-encoded (no padding).
    /// RFC 7636 §4.1: 43–128 char ASCII string from [A-Z][a-z][0-9]-._~.
    /// 32 random bytes → 43-char base64url, well within the spec.
    static func generateVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return Data(bytes).base64URLEncodedString()
    }

    /// Derive `code_challenge` from a `code_verifier` using S256:
    /// challenge = base64url( SHA256(verifier) ), no padding.
    static func challenge(forVerifier verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }
}

extension Data {
    /// Base64url encoding without padding (RFC 4648 §5).
    fileprivate func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
