import Foundation
import os.lock
import Testing
@testable import Cadenza

private final class MemoryTokenPersistence: MCPTokenPersisting, Sendable {
    private let values = OSAllocatedUnfairLock(initialState: [String: String]())

    func get(_ key: String) -> String? {
        values.withLock { $0[key] }
    }

    func set(_ value: String, forKey key: String) throws {
        values.withLock { $0[key] = value }
    }

    func remove(_ key: String) throws {
        _ = values.withLock { $0.removeValue(forKey: key) }
    }
}

@Suite("MCP Client Access Store")
struct MCPClientAccessStoreTests {
    @Test func activeProfileCredentialsDoNotAuthorizeAnotherProfile() throws {
        let suite = "mcp-profile-access-tests-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let keychain = MemoryTokenPersistence()
        let profileA = UUID()
        let profileB = UUID()
        let modeA = ActiveProfileDefaults.Mode.profile(profileA)
        let modeB = ActiveProfileDefaults.Mode.profile(profileB)

        let metadataA = try #require(MCPProfileCredentialKeys.metadataKey(for: modeA))
        let tokenPrefixA = try #require(MCPProfileCredentialKeys.clientTokenPrefix(for: modeA))
        let metadataB = try #require(MCPProfileCredentialKeys.metadataKey(for: modeB))
        let tokenPrefixB = try #require(MCPProfileCredentialKeys.clientTokenPrefix(for: modeB))

        #expect(metadataA != metadataB)
        #expect(tokenPrefixA != tokenPrefixB)
        #expect(
            MCPProfileCredentialKeys.legacyTokenKey(for: modeA)
                != MCPProfileCredentialKeys.legacyTokenKey(for: modeB)
        )

        let storeA = MCPClientAccessStore(
            keychain: keychain,
            defaultsSuiteName: suite,
            metadataKey: metadataA,
            tokenPrefix: tokenPrefixA
        )
        let tokenA = try storeA.token(
            for: "codex-cli",
            name: "Codex",
            scopes: [.recordingRead]
        )

        let storeB = MCPClientAccessStore(
            keychain: keychain,
            defaultsSuiteName: suite,
            metadataKey: metadataB,
            tokenPrefix: tokenPrefixB
        )
        #expect(storeB.authenticate(presentedToken: tokenA, legacyToken: "profile-b") == nil)
        #expect(storeB.records().isEmpty)
    }

    @Test func clientTokensAuthenticateWithOnlyAssignedScopesAndPersistMetadata() throws {
        let suite = "mcp-access-tests-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let keychain = MemoryTokenPersistence()
        let store = MCPClientAccessStore(
            keychain: keychain,
            defaultsSuiteName: suite,
            metadataKey: "records",
            tokenPrefix: "tokens."
        )

        let token = try store.token(
            for: "codex-cli",
            name: "Codex",
            scopes: [.recordingRead, .externalImportWrite]
        )
        let context = try #require(store.authenticate(presentedToken: token, legacyToken: "legacy"))
        #expect(context.clientID == "codex-cli")
        #expect(context.scopes == [.recordingRead, .externalImportWrite])
        #expect(!context.isLegacy)
        #expect(store.records().first?.lastUsedAt != nil)

        let reloaded = MCPClientAccessStore(
            keychain: keychain,
            defaultsSuiteName: suite,
            metadataKey: "records",
            tokenPrefix: "tokens."
        )
        #expect(reloaded.existingToken(for: "codex-cli") == token)
        #expect(reloaded.records().first?.scopes == [.recordingRead, .externalImportWrite])
    }

    @Test func legacyTokenKeepsAllScopesAndRevocationInvalidatesClientToken() throws {
        let suite = "mcp-access-tests-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let store = MCPClientAccessStore(
            keychain: MemoryTokenPersistence(),
            defaultsSuiteName: suite,
            metadataKey: "records",
            tokenPrefix: "tokens."
        )
        let token = try store.token(for: "claude", name: "Claude", scopes: [.recordingRead])
        let legacy = try #require(store.authenticate(presentedToken: "legacy", legacyToken: "legacy"))
        #expect(legacy == .legacy)
        #expect(store.revoke(clientID: "claude"))
        #expect(store.authenticate(presentedToken: token, legacyToken: "legacy") == nil)
        #expect(store.records().isEmpty)
    }

    @Test func rejectsEmptyClientIDAndIgnoresDuplicatePersistedMetadata() throws {
        let suite = "mcp-access-tests-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let defaults = try #require(UserDefaults(suiteName: suite))
        let duplicate = MCPClientAccessRecord(
            id: "codex-cli",
            name: "Codex",
            scopes: [.recordingRead],
            createdAt: Date(),
            lastUsedAt: nil
        )
        defaults.set(try JSONEncoder().encode([duplicate, duplicate]), forKey: "records")

        let store = MCPClientAccessStore(
            keychain: MemoryTokenPersistence(),
            defaultsSuiteName: suite,
            metadataKey: "records",
            tokenPrefix: "tokens."
        )
        #expect(store.records().count == 1)
        #expect(throws: MCPClientAccessError.self) {
            _ = try store.token(for: "---", name: "Invalid", scopes: [.recordingRead])
        }
        #expect(!store.revoke(clientID: "---"))
    }
}
