import Testing
@testable import Cadenza

struct PKCETests {
    /// RFC 7636 Appendix B test vector.
    /// verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
    /// challenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
    @Test func challengeMatchesRFC7636Vector() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let challenge = PKCE.challenge(forVerifier: verifier)
        #expect(challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func generatedVerifierIsBase64URLNoPadding() {
        let v = PKCE.generateVerifier()
        // 32 random bytes → base64url length = 43 (no padding).
        #expect(v.count == 43)
        // Only base64url chars: [A-Za-z0-9_-].
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        #expect(v.unicodeScalars.allSatisfy { allowed.contains($0) })
    }

    @Test func generatedVerifiersAreDistinct() {
        // Cryptographic randomness — collision astronomically unlikely.
        let a = PKCE.generateVerifier()
        let b = PKCE.generateVerifier()
        #expect(a != b)
    }

    @Test func challengeIsDeterministic() {
        let v = PKCE.generateVerifier()
        #expect(PKCE.challenge(forVerifier: v) == PKCE.challenge(forVerifier: v))
    }
}
