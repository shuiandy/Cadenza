import CryptoKit
import Foundation
import os.lock

struct MCPClientAccessRecord: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var name: String
    var scopes: Set<MCPPermissionScope>
    let createdAt: Date
    var lastUsedAt: Date?
}

enum MCPClientAccessError: Error, LocalizedError, Sendable {
    case invalidClientID

    var errorDescription: String? {
        "The MCP client identifier is invalid."
    }
}

protocol MCPTokenPersisting: Sendable {
    func get(_ key: String) -> String?
    func set(_ value: String, forKey key: String) throws
    func remove(_ key: String) throws
}

extension KeychainManager: MCPTokenPersisting {}

/// MCP credentials authorize access to the active profile's recordings, so
/// their metadata and Keychain names must change with that profile. Server
/// enablement and port remain device-level preferences, but switching profiles
/// deliberately requires clients to reconnect and receive a new credential.
enum MCPProfileCredentialKeys {
    private static let metadataBase = "mcpClientAccessRecords"
    private static let clientTokenBase = "mcp.clientToken"
    private static let legacyTokenBase = "mcp.bearerToken"

    static var activeMetadataKey: String {
        ActiveProfileDefaults.key(metadataBase)
    }

    static var activeClientTokenPrefix: String {
        ActiveProfileDefaults.key(clientTokenBase) + "."
    }

    static var activeLegacyTokenKey: String {
        ActiveProfileDefaults.key(legacyTokenBase)
    }

    static func metadataKey(for mode: ActiveProfileDefaults.Mode) -> String? {
        ActiveProfileDefaults.resolvedKey(metadataBase, mode: mode)
    }

    static func clientTokenPrefix(for mode: ActiveProfileDefaults.Mode) -> String? {
        ActiveProfileDefaults.resolvedKey(clientTokenBase, mode: mode).map { $0 + "." }
    }

    static func legacyTokenKey(for mode: ActiveProfileDefaults.Mode) -> String? {
        ActiveProfileDefaults.resolvedKey(legacyTokenBase, mode: mode)
    }
}

final class MCPClientAccessStore: Sendable {
    static let shared = MCPClientAccessStore()

    private struct State: Sendable {
        var records: [String: MCPClientAccessRecord]
        var tokens: [String: String]
    }

    private let lock: OSAllocatedUnfairLock<State>
    private let keychain: any MCPTokenPersisting
    private let defaultsSuiteName: String?
    private let metadataKey: String
    private let tokenPrefix: String
    private let persistQueue = DispatchQueue(label: "com.shuiandy.Cadenza.mcp-access-persist")

    /// How stale `lastUsedAt` may get on disk before a request pays for a write.
    private static let lastUsedPersistInterval: TimeInterval = 60

    init(
        keychain: any MCPTokenPersisting = KeychainManager.shared,
        defaultsSuiteName: String? = nil,
        metadataKey: String = MCPProfileCredentialKeys.activeMetadataKey,
        tokenPrefix: String = MCPProfileCredentialKeys.activeClientTokenPrefix
    ) {
        self.keychain = keychain
        self.defaultsSuiteName = defaultsSuiteName
        self.metadataKey = metadataKey
        self.tokenPrefix = tokenPrefix

        let decoded: [MCPClientAccessRecord]
        let defaults = defaultsSuiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        if let data = defaults.data(forKey: metadataKey),
           let records = try? JSONDecoder().decode([MCPClientAccessRecord].self, from: data) {
            decoded = records
        } else {
            decoded = []
        }
        var records: [String: MCPClientAccessRecord] = [:]
        var tokens: [String: String] = [:]
        for record in decoded {
            let normalizedID = Self.normalizedID(record.id)
            guard normalizedID == record.id, !normalizedID.isEmpty,
                  records[normalizedID] == nil else { continue }
            records[normalizedID] = record
            if let token = keychain.get(tokenPrefix + record.id), !token.isEmpty {
                tokens[record.id] = token
            }
        }
        lock = OSAllocatedUnfairLock(initialState: State(
            records: records,
            tokens: tokens
        ))
    }

    func records() -> [MCPClientAccessRecord] {
        lock.withLock { state in
            state.records.values.sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }
    }

    func token(for clientID: String, name: String, scopes: Set<MCPPermissionScope>) throws -> String {
        let normalizedID = Self.normalizedID(clientID)
        guard !normalizedID.isEmpty else { throw MCPClientAccessError.invalidClientID }
        if let existing = lock.withLock({ $0.tokens[normalizedID] }) {
            updateRecord(id: normalizedID, name: name, scopes: scopes, token: existing)
            return existing
        }

        let token = MCPServer.generateToken()
        try keychain.set(token, forKey: tokenPrefix + normalizedID)
        updateRecord(id: normalizedID, name: name, scopes: scopes, token: token)
        return token
    }

    func existingToken(for clientID: String) -> String? {
        let normalizedID = Self.normalizedID(clientID)
        guard !normalizedID.isEmpty else { return nil }
        return lock.withLock { $0.tokens[normalizedID] }
    }

    /// Revoking drops the live credential first and deletes the Keychain item
    /// afterwards. The order matters: if the delete fails (locked Keychain, changed
    /// ACL) the client is still locked out, both now and across restarts — `init`
    /// only loads tokens for records that survive in the metadata, so the orphaned
    /// blob is inert. Returns false when cleanup did not complete, so the caller can
    /// say so; access is revoked either way.
    @discardableResult
    func revoke(clientID: String) -> Bool {
        let normalizedID = Self.normalizedID(clientID)
        guard !normalizedID.isEmpty else { return false }

        let existed = lock.withLock { state -> Bool in
            let had = state.records.removeValue(forKey: normalizedID) != nil
            state.tokens.removeValue(forKey: normalizedID)
            return had
        }
        persistMetadata(sync: true)
        guard existed else { return false }

        do {
            try keychain.remove(tokenPrefix + normalizedID)
        } catch {
            NSLog("[MCPClientAccessStore] revoked %@ but could not delete its Keychain item: %@",
                  normalizedID, error.localizedDescription)
            return false
        }
        return true
    }

    func authenticate(presentedToken: String, legacyToken: String) -> MCPRequestContext? {
        if Self.constantTimeEqual(presentedToken, legacyToken) {
            return .legacy
        }

        // Hash the presented token once rather than once per registered client.
        let presentedDigest = Self.digest(presentedToken)
        let now = Date()
        let outcome = lock.withLock { state -> (record: MCPClientAccessRecord, persistDue: Bool)? in
            for (id, token) in state.tokens where Self.digest(token) == presentedDigest {
                guard var record = state.records[id] else { continue }
                let previous = record.lastUsedAt
                record.lastUsedAt = now
                state.records[id] = record
                // lastUsedAt is a display timestamp, so it only has to be roughly
                // right. Persisting it on every call would put a full re-encode and
                // a defaults write on the request path.
                let due = previous.map { now.timeIntervalSince($0) >= Self.lastUsedPersistInterval } ?? true
                return (record, due)
            }
            return nil
        }
        guard let outcome else { return nil }
        if outcome.persistDue { persistMetadata(sync: false) }
        return MCPRequestContext(
            clientID: outcome.record.id,
            clientName: outcome.record.name,
            scopes: outcome.record.scopes,
            isLegacy: false
        )
    }

    private func updateRecord(id: String, name: String, scopes: Set<MCPPermissionScope>, token: String) {
        lock.withLock { state in
            let existing = state.records[id]
            state.records[id] = MCPClientAccessRecord(
                id: id,
                name: name,
                scopes: scopes,
                createdAt: existing?.createdAt ?? Date(),
                lastUsedAt: existing?.lastUsedAt
            )
            state.tokens[id] = token
        }
        persistMetadata(sync: true)
    }

    /// Encodes and writes the metadata. Never called while `lock` is held: JSON
    /// encoding and a UserDefaults write are exactly the kind of work that must not
    /// happen under an `os_unfair_lock`. The snapshot is taken inside the serial
    /// queue, so a late write can never resurrect a record a newer call removed.
    private func persistMetadata(sync: Bool) {
        let work: @Sendable () -> Void = { [lock, defaultsSuiteName, metadataKey] in
            let sorted = lock.withLock { $0.records.values.sorted { $0.id < $1.id } }
            guard let data = try? JSONEncoder().encode(sorted) else { return }
            let defaults = defaultsSuiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
            defaults.set(data, forKey: metadataKey)
        }
        if sync {
            persistQueue.sync(execute: work)
        } else {
            persistQueue.async(execute: work)
        }
    }

    private static func normalizedID(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let mapped = value.lowercased().unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" }
        return String(String(mapped).prefix(128))
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private static func digest(_ value: String) -> SHA256Digest {
        SHA256.hash(data: Data(value.utf8))
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        digest(lhs) == digest(rhs)
    }
}
