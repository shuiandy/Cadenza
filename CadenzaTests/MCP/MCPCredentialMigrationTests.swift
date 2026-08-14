import Foundation
import os.lock
import Testing
@testable import Cadenza

private final class MemoryKeychain: MCPTokenPersisting, Sendable {
    private let values = OSAllocatedUnfairLock(initialState: [String: String]())
    private let failingKeys: Set<String>

    init(failingKeys: Set<String> = []) {
        self.failingKeys = failingKeys
    }

    struct WriteRefused: Error {}

    func get(_ key: String) -> String? {
        values.withLock { $0[key] }
    }

    func set(_ value: String, forKey key: String) throws {
        guard !failingKeys.contains(key) else { throw WriteRefused() }
        values.withLock { $0[key] = value }
    }

    func remove(_ key: String) throws {
        _ = values.withLock { $0.removeValue(forKey: key) }
    }
}

@Suite("MCP Credential Migration")
struct MCPCredentialMigrationTests {
    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "mcp-credential-migration-\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    private func seedGlobalClient(
        _ defaults: UserDefaults,
        _ keychain: MemoryKeychain,
        id: String,
        token: String
    ) throws {
        let record = MCPClientAccessRecord(
            id: id,
            name: "Codex (GPT)",
            scopes: [.recordingRead, .recordingWrite],
            createdAt: Date(timeIntervalSince1970: 1_000),
            lastUsedAt: Date(timeIntervalSince1970: 2_000)
        )
        let globalMetadata = try #require(
            MCPProfileCredentialKeys.metadataKey(for: .legacyFallback)
        )
        let globalPrefix = try #require(
            MCPProfileCredentialKeys.clientTokenPrefix(for: .legacyFallback)
        )
        defaults.set(try JSONEncoder().encode([record]), forKey: globalMetadata)
        try keychain.set(token, forKey: globalPrefix + id)
    }

    @Test("A pre-profile client keeps working after the upgrade")
    func adoptsClientRecordAndToken() throws {
        let (defaults, suite) = makeDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let keychain = MemoryKeychain()
        let profile = UUID()
        try seedGlobalClient(defaults, keychain, id: "codex-cli", token: "codex-token")

        MCPCredentialMigration(defaults: defaults, keychain: keychain)
            .adoptGlobalCredentials(into: profile)

        let scopedMetadata = try #require(
            MCPProfileCredentialKeys.metadataKey(for: .profile(profile))
        )
        let scopedPrefix = try #require(
            MCPProfileCredentialKeys.clientTokenPrefix(for: .profile(profile))
        )
        #expect(keychain.get(scopedPrefix + "codex-cli") == "codex-token")

        // The decisive check: the store the running server reads must now
        // authenticate the token the client already has in its config.
        let store = MCPClientAccessStore(
            keychain: keychain,
            defaultsSuiteName: suite,
            metadataKey: scopedMetadata,
            tokenPrefix: scopedPrefix
        )
        let context = store.authenticate(presentedToken: "codex-token", legacyToken: "unrelated")
        #expect(context?.clientID == "codex-cli")
        #expect(context?.isLegacy == false)
        #expect(context?.scopes == [.recordingRead, .recordingWrite])
    }

    @Test("The pre-profile shared token is adopted over an on-demand one")
    func adoptsLegacyTokenOverGeneratedOne() throws {
        let (defaults, suite) = makeDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let keychain = MemoryKeychain()
        let profile = UUID()
        let globalLegacy = try #require(
            MCPProfileCredentialKeys.legacyTokenKey(for: .legacyFallback)
        )
        let scopedLegacy = try #require(
            MCPProfileCredentialKeys.legacyTokenKey(for: .profile(profile))
        )
        try keychain.set("shared-token-clients-still-send", forKey: globalLegacy)
        // What a build without this migration mints on first launch.
        try keychain.set("freshly-generated", forKey: scopedLegacy)

        MCPCredentialMigration(defaults: defaults, keychain: keychain)
            .adoptGlobalCredentials(into: profile)

        #expect(keychain.get(scopedLegacy) == "shared-token-clients-still-send")
    }

    @Test("An existing scoped registry is merged with, never replaced by, the global one")
    func mergesIntoScopedRegistryWithoutTouchingItsRecords() throws {
        // Bailing out whenever a scoped registry already existed stranded the
        // common recovery: a user who reconnects one client in Settings creates
        // that registry, and every other pre-upgrade client would then be
        // orphaned for good. The adoption must add the missing global clients
        // while leaving the profile's own records byte-for-byte alone.
        let (defaults, suite) = makeDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let keychain = MemoryKeychain()
        let profile = UUID()
        try seedGlobalClient(defaults, keychain, id: "codex-cli", token: "codex-token")

        let scopedMetadata = try #require(
            MCPProfileCredentialKeys.metadataKey(for: .profile(profile))
        )
        let ownRecord = MCPClientAccessRecord(
            id: "claude-code",
            name: "Claude Code",
            scopes: [.recordingRead],
            createdAt: Date(timeIntervalSince1970: 9_000),
            lastUsedAt: nil
        )
        defaults.set(try JSONEncoder().encode([ownRecord]), forKey: scopedMetadata)

        MCPCredentialMigration(defaults: defaults, keychain: keychain)
            .adoptGlobalCredentials(into: profile)

        let stored = try JSONDecoder().decode(
            [MCPClientAccessRecord].self,
            from: try #require(defaults.data(forKey: scopedMetadata))
        )
        #expect(stored.map(\.id) == ["claude-code", "codex-cli"])
        let ownStored = try #require(stored.first { $0.id == "claude-code" })
        #expect(ownStored.createdAt == Date(timeIntervalSince1970: 9_000))
        #expect(ownStored.scopes == [.recordingRead])
    }

    @Test("A global record whose id already exists scoped is not adopted twice")
    func doesNotDuplicateAnExistingClientID() throws {
        let (defaults, suite) = makeDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let keychain = MemoryKeychain()
        let profile = UUID()
        // The same client is registered globally and scoped; the scoped record
        // is the profile's own state and the global twin must not clobber it.
        try seedGlobalClient(defaults, keychain, id: "claude-code", token: "global-token")

        let scopedMetadata = try #require(
            MCPProfileCredentialKeys.metadataKey(for: .profile(profile))
        )
        let ownRecord = MCPClientAccessRecord(
            id: "claude-code",
            name: "Claude Code",
            scopes: [.recordingRead],
            createdAt: Date(timeIntervalSince1970: 9_000),
            lastUsedAt: nil
        )
        defaults.set(try JSONEncoder().encode([ownRecord]), forKey: scopedMetadata)

        MCPCredentialMigration(defaults: defaults, keychain: keychain)
            .adoptGlobalCredentials(into: profile)

        let stored = try JSONDecoder().decode(
            [MCPClientAccessRecord].self,
            from: try #require(defaults.data(forKey: scopedMetadata))
        )
        #expect(stored.map(\.id) == ["claude-code"])
        #expect(try #require(stored.first).createdAt == Date(timeIntervalSince1970: 9_000))
    }

    @Test("The marker is global, so a second profile inherits nothing")
    func secondProfileDoesNotInheritCredentials() throws {
        let (defaults, suite) = makeDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let keychain = MemoryKeychain()
        let first = UUID()
        let second = UUID()
        try seedGlobalClient(defaults, keychain, id: "codex-cli", token: "codex-token")

        let migration = MCPCredentialMigration(defaults: defaults, keychain: keychain)
        migration.adoptGlobalCredentials(into: first)
        migration.adoptGlobalCredentials(into: second)

        let secondMetadata = try #require(
            MCPProfileCredentialKeys.metadataKey(for: .profile(second))
        )
        let secondPrefix = try #require(
            MCPProfileCredentialKeys.clientTokenPrefix(for: .profile(second))
        )
        #expect(defaults.data(forKey: secondMetadata) == nil)
        #expect(keychain.get(secondPrefix + "codex-cli") == nil)
        #expect(migration.adoptionComplete())
    }

    @Test("A Keychain failure retries instead of publishing a broken client")
    func incompleteRunRetriesOnNextBoot() throws {
        let (defaults, suite) = makeDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let profile = UUID()
        let scopedPrefix = try #require(
            MCPProfileCredentialKeys.clientTokenPrefix(for: .profile(profile))
        )
        let scopedMetadata = try #require(
            MCPProfileCredentialKeys.metadataKey(for: .profile(profile))
        )
        let failing = MemoryKeychain(failingKeys: [scopedPrefix + "codex-cli"])
        try seedGlobalClient(defaults, failing, id: "codex-cli", token: "codex-token")

        MCPCredentialMigration(defaults: defaults, keychain: failing)
            .adoptGlobalCredentials(into: profile)

        // No metadata means no client claiming to be connected, and no marker
        // means the next boot tries again.
        #expect(defaults.data(forKey: scopedMetadata) == nil)
        #expect(defaults.object(forKey: MCPCredentialMigration.markerKey) == nil)

        let working = MemoryKeychain()
        try seedGlobalClient(defaults, working, id: "codex-cli", token: "codex-token")
        MCPCredentialMigration(defaults: defaults, keychain: working)
            .adoptGlobalCredentials(into: profile)
        #expect(working.get(scopedPrefix + "codex-cli") == "codex-token")
        #expect(defaults.data(forKey: scopedMetadata) != nil)
    }

    @Test("A fresh install adopts nothing and still settles")
    func freshInstallIsANoOp() throws {
        let (defaults, suite) = makeDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let keychain = MemoryKeychain()
        let profile = UUID()

        let migration = MCPCredentialMigration(defaults: defaults, keychain: keychain)
        migration.adoptGlobalCredentials(into: profile)

        let scopedMetadata = try #require(
            MCPProfileCredentialKeys.metadataKey(for: .profile(profile))
        )
        #expect(defaults.data(forKey: scopedMetadata) == nil)
        #expect(migration.adoptionComplete())
    }
}
