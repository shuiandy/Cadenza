import Foundation

/// Narrow secret-store surface used by auth services so tests can swap the
/// real `KeychainManager` for an in-memory fake.
///
/// `@MainActor`-isolated so:
///   - Test fakes can be plain `final class` with mutable state — no
///     `@unchecked Sendable` (forbidden by AGENTS.md).
///   - Production conformer (`KeychainAuthSecretStore`) is reachable
///     from `@MainActor`-isolated `CadenzaAuthService`.
@MainActor
protocol AuthSecretStore {
    func get(_ key: String) -> String?
    /// Classified read: nil is a definite not-found; unknown failures
    /// throw. Authority probes (binding recovery, migration) must use this
    /// instead of `get` so an unreadable store never reads as absent.
    func getClassified(_ key: String) throws -> String?
    func set(_ value: String, for key: String) throws
    func remove(_ key: String) throws
}

/// TestHost conformance (INV-8): secrets live in memory only, so test runs
/// never read or write the real Keychain items.
@MainActor
final class EphemeralAuthSecretStore: AuthSecretStore {
    private var values: [String: String] = [:]

    func get(_ key: String) -> String? {
        values[key]
    }

    func getClassified(_ key: String) throws -> String? {
        values[key]
    }

    func set(_ value: String, for key: String) throws {
        values[key] = value
    }

    func remove(_ key: String) throws {
        values.removeValue(forKey: key)
    }
}

/// Production conformance: thin wrapper over `KeychainManager.shared`.
@MainActor
struct KeychainAuthSecretStore: AuthSecretStore {
    func get(_ key: String) -> String? {
        KeychainManager.shared.get(key)
    }

    func getClassified(_ key: String) throws -> String? {
        try KeychainManager.shared.getClassified(key)
    }

    func set(_ value: String, for key: String) throws {
        try KeychainManager.shared.set(value, forKey: key)
    }

    func remove(_ key: String) throws {
        try KeychainManager.shared.remove(key)
    }
}
