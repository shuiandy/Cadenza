import Foundation

/// Narrow HTTP surface used by `CadenzaAuthService` and `NotionExportService`,
/// so tests can substitute an in-memory fake without `URLProtocol` plumbing.
///
/// `@MainActor`-isolated so:
///   - Test fakes can be plain `final class` with mutable state — no
///     `@unchecked Sendable` (forbidden by AGENTS.md).
///   - Production conformer (`URLSession`) is Sendable and conforms via the
///     extension below; calling its async method from `@MainActor` is safe
///     because `URLSession.data(for:)` is itself actor-agnostic (nonisolated).
@MainActor
protocol AuthHTTP {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: AuthHTTP {}
