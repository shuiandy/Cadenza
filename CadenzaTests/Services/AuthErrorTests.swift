import Foundation
import Testing
@testable import Cadenza

@Suite("AuthError")
struct AuthErrorTests {
    @Test func classifyURLErrorCancelledMapsToCancelled() {
        let urlError = URLError(.cancelled)
        let classified = AuthError.classify(urlError)
        #expect(classified == .cancelled)
    }

    @Test func classifyURLErrorNotConnectedMapsToNetwork() {
        let urlError = URLError(.notConnectedToInternet)
        let classified = AuthError.classify(urlError)
        #expect(classified == .network(.notConnectedToInternet))
    }

    @Test func classifyDecodingErrorMapsToDecoding() {
        let decodeError = DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "bad json"))
        let classified = AuthError.classify(decodeError)
        if case .decoding = classified { /* ok */ } else {
            Issue.record("expected .decoding, got \(classified)")
        }
    }

    @Test func classifyExistingAuthErrorPassesThrough() {
        let original = AuthError.stateMismatch
        #expect(AuthError.classify(original) == .stateMismatch)
    }

    @Test func classifyUnknownErrorMapsToUnknown() {
        struct WeirdError: Error {}
        #expect(AuthError.classify(WeirdError()) == .unknown)
    }

    @Test func equatableTreatsAssociatedValuesProperly() {
        #expect(AuthError.server(status: 500) == AuthError.server(status: 500))
        #expect(AuthError.server(status: 500) != AuthError.server(status: 503))
        #expect(AuthError.integrationReauthRequired(provider: "notion")
                == AuthError.integrationReauthRequired(provider: "notion"))
        #expect(AuthError.integrationReauthRequired(provider: "notion")
                != AuthError.integrationReauthRequired(provider: "zoom"))
    }
}
