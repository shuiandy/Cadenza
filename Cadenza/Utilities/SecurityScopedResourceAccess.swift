import Foundation

@MainActor
enum SecurityScopedResourceAccess {
    static func withAccess<Value>(
        to url: URL,
        start: (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
        stop: (URL) -> Void = { $0.stopAccessingSecurityScopedResource() },
        operation: () async throws -> Value
    ) async rethrows -> Value {
        let didStart = start(url)
        defer {
            if didStart {
                stop(url)
            }
        }
        return try await operation()
    }
}
