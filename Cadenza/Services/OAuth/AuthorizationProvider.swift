import Foundation

/// Abstracts `OAuthCoordinator.authorize(authorizeURL:)` for testing.
/// Production binds to `OAuthCoordinator.shared`; tests inject a fake.
@MainActor
protocol AuthorizationProvider {
    /// Opens `authorizeURL` in an `ASWebAuthenticationSession` and resolves
    /// with the captured callback URL, or throws `AuthError`.
    func authorize(_ authorizeURL: URL) async throws -> URL
}
