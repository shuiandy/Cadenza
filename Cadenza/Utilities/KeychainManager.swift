import Foundation
import KeychainAccess

enum KeychainMutationBatch {
    static func execute(_ operations: [() throws -> Void]) throws {
        var firstError: Error?
        for operation in operations {
            do {
                try operation()
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }
        }
        if let firstError {
            throw firstError
        }
    }
}

protocol KeychainValueStoring: AnyObject {
    func get(_ key: String) throws -> String?
    func set(_ value: String, key: String) throws
    func remove(_ key: String) throws
}

private final class SystemKeychainValueStore: KeychainValueStoring {
    private let keychain: Keychain

    init(service: String) {
        keychain = Keychain(service: service).accessibility(.whenUnlocked)
    }

    func get(_ key: String) throws -> String? {
        try keychain.get(key)
    }

    func set(_ value: String, key: String) throws {
        try keychain.set(value, key: key)
    }

    func remove(_ key: String) throws {
        try keychain.remove(key)
    }
}

private final class InMemoryKeychainValueStore: KeychainValueStoring {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func get(_ key: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    func set(_ value: String, key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        values[key] = value
    }

    func remove(_ key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        values.removeValue(forKey: key)
    }
}

final class KeychainManager: @unchecked Sendable {
    static let shared = KeychainManager()

    private let primaryService = "com.shuiandy.Cadenza"
    private let legacyServices = [
        "com.shuiandy.AIRecorder",
        "com.shuiandy.AIRecorder.keys",
        "com.shuiandy.AIRecorder.app",
        "com.shuiandy.ai-recorder",
        "com.shuiandy.AI-Recorder"
    ]
    private let primaryStore: any KeychainValueStoring
    private let legacyStoreFactory: ((String) -> any KeychainValueStoring)?
    let isMemoryOnly: Bool

    private convenience init() {
        self.init(
            isolated: DebugDataRoot.blocksLiveAccess,
            livePrimaryStore: { SystemKeychainValueStore(service: "com.shuiandy.Cadenza") },
            liveLegacyStore: { SystemKeychainValueStore(service: $0) }
        )
    }

    /// Test seam for proving the isolated branch does not even construct,
    /// inspect, migrate, or remove a live/legacy Keychain store.
    init(
        isolated: Bool,
        livePrimaryStore: () -> any KeychainValueStoring,
        liveLegacyStore: @escaping (String) -> any KeychainValueStoring
    ) {
        isMemoryOnly = isolated
        if isolated {
            primaryStore = InMemoryKeychainValueStore()
            legacyStoreFactory = nil
        } else {
            primaryStore = livePrimaryStore()
            legacyStoreFactory = liveLegacyStore
        }
    }

    func apiKey(for provider: AIProvider) -> String? {
        let keyName = "apiKey.\(provider.rawValue)"

        do {
            if let key = try primaryStore.get(keyName), !key.isEmpty {
                return key
            }
        } catch {
            NSLog("[KeychainManager] failed to read %@: %@", keyName, error.localizedDescription)
            return nil
        }

        // Backward compatibility: migrate keys from legacy service names.
        guard let legacyStoreFactory else { return nil }
        for service in legacyServices where service != primaryService {
            let legacyKeychain = legacyStoreFactory(service)
            do {
                if let legacyKey = try legacyKeychain.get(keyName), !legacyKey.isEmpty {
                    do {
                        try primaryStore.set(legacyKey, key: keyName)
                    } catch {
                        NSLog(
                            "[KeychainManager] failed to migrate %@ from %@: %@",
                            keyName,
                            service,
                            error.localizedDescription
                        )
                    }
                    return legacyKey
                }
            } catch {
                NSLog(
                    "[KeychainManager] failed to read legacy key %@ from %@: %@",
                    keyName,
                    service,
                    error.localizedDescription
                )
            }
        }

        return nil
    }

    /// Read an API key without migrating or writing any Keychain item.
    ///
    /// Provider resolution uses this path because deciding where audio may be
    /// sent must not have a hidden persistence side effect. Legacy services are
    /// still consulted so existing users keep access to keys saved by older app
    /// versions; explicit migration remains owned by `apiKey(for:)` callers.
    func readOnlyAPIKey(for provider: AIProvider) -> String? {
        let keyName = "apiKey.\(provider.rawValue)"

        do {
            if let key = try primaryStore.get(keyName), !key.isEmpty {
                return key
            }
        } catch {
            NSLog("[KeychainManager] failed to read %@: %@", keyName, error.localizedDescription)
            return nil
        }

        guard let legacyStoreFactory else { return nil }
        for service in legacyServices where service != primaryService {
            let legacyKeychain = legacyStoreFactory(service)
            do {
                if let legacyKey = try legacyKeychain.get(keyName), !legacyKey.isEmpty {
                    return legacyKey
                }
            } catch {
                NSLog(
                    "[KeychainManager] failed to read legacy key %@ from %@: %@",
                    keyName,
                    service,
                    error.localizedDescription
                )
            }
        }

        return nil
    }

    func setAPIKey(_ key: String, for provider: AIProvider) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            try primaryStore.remove("apiKey.\(provider.rawValue)")
        } else {
            try primaryStore.set(trimmed, key: "apiKey.\(provider.rawValue)")
        }
    }

    func removeAPIKey(for provider: AIProvider) throws {
        let keyName = "apiKey.\(provider.rawValue)"
        var removalOperations: [() throws -> Void] = [
            { try self.primaryStore.remove(keyName) }
        ]
        if let legacyStoreFactory {
            removalOperations += legacyServices
                .filter { $0 != primaryService }
                .map { service in
                    {
                        let legacy = legacyStoreFactory(service)
                        do {
                            try legacy.remove(keyName)
                        } catch {
                            NSLog(
                                "[KeychainManager] failed to remove legacy key %@ from %@: %@",
                                keyName,
                                service,
                                error.localizedDescription
                            )
                            throw error
                        }
                    }
                }
        }
        try KeychainMutationBatch.execute(removalOperations)
    }

    func hasAPIKey(for provider: AIProvider) -> Bool {
        guard let key = apiKey(for: provider) else { return false }
        return !key.isEmpty
    }

    // MARK: - Generic Key Access

    func get(_ key: String) -> String? {
        do {
            return try primaryStore.get(key)
        } catch {
            NSLog("[KeychainManager] failed to read %@: %@", key, error.localizedDescription)
            return nil
        }
    }

    /// Classified read: nil is a definite not-found; any other Keychain
    /// failure throws. Authority decisions (binding recovery) use this so
    /// an unreadable Keychain is never mistaken for an absent token.
    func getClassified(_ key: String) throws -> String? {
        try primaryStore.get(key)
    }

    func set(_ value: String, forKey key: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try primaryStore.remove(key)
        } else {
            try primaryStore.set(trimmed, key: key)
        }
    }

    func remove(_ key: String) throws {
        try primaryStore.remove(key)
    }

    // MARK: - Migration

    /// Gets a value from Keychain, migrating from UserDefaults if needed.
    /// Only deletes the UserDefaults entry after Keychain write succeeds.
    func getWithMigration(_ key: String, defaults: UserDefaults = .standard) -> String {
        if let val = get(key) { return val }
        // An isolated fixture runtime owns an empty process-memory vault. It
        // must not use defaults as a back door into any persisted credential
        // migration, even though CFFIXED_USER_HOME separately relocates them.
        if isMemoryOnly { return "" }
        if let val = defaults.string(forKey: key), !val.isEmpty {
            do {
                try set(val, forKey: key)
                defaults.removeObject(forKey: key)
            } catch {
                NSLog(
                    "[KeychainManager] failed to migrate %@ from UserDefaults: %@",
                    key,
                    error.localizedDescription
                )
            }
            return val
        }
        return ""
    }

    /// Legacy best-effort call site support. User-facing credential flows must
    /// use the throwing `set(_:forKey:)` API so failures can be surfaced.
    func setQuietly(_ value: String, forKey key: String) {
        do {
            try set(value, forKey: key)
        } catch {
            NSLog("[KeychainManager] failed to write %@: %@", key, error.localizedDescription)
        }
    }
}
