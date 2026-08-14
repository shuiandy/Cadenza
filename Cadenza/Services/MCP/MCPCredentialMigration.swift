import Foundation

/// Adopts pre-profile MCP credentials into the active profile's scoped keys.
///
/// Before profile scoping, MCP credentials lived at fixed global keys:
/// `mcpClientAccessRecords` in UserDefaults, `mcp.clientToken.<clientID>` and
/// `mcp.bearerToken` in the Keychain. `MCPProfileCredentialKeys` now resolves
/// all three through `ActiveProfileDefaults`, so an upgrading install reads
/// `<base>.profile.<uuid>` — keys it has never written. The access store then
/// loads zero registered clients, every token issued before the upgrade fails
/// `authenticate`, and each configured client gets a 401 while Settings reports
/// it as out of date. Reconnecting is the only recovery, and for the TOML and
/// YAML clients that means re-running the text-level config rewrite the
/// connector itself documents as the risky path.
///
/// The marker is deliberately **global, not per-profile**: the credentials it
/// moves predate profiles, so they belong to exactly one of them. A per-profile
/// marker would re-run the adoption for every profile the user later activates
/// and copy one profile's credentials into all the others. Whichever profile is
/// active on the first boot after this ships claims them; a different profile
/// recovers by reconnecting its clients, which is also how it would have had to
/// start.
struct MCPCredentialMigration {
    let defaults: UserDefaults
    let keychain: any MCPTokenPersisting

    /// Global, set once the pre-profile credentials have been claimed.
    static let markerKey = "mcpCredentialsAdopted.v1"

    static func standard() -> MCPCredentialMigration {
        MCPCredentialMigration(defaults: .standard, keychain: KeychainManager.shared)
    }

    func adoptionComplete() -> Bool {
        defaults.object(forKey: Self.markerKey) as? Bool == true
    }

    /// Idempotent. A run interrupted by a Keychain failure leaves the marker
    /// unset and writes no metadata, so the next boot repeats it; the token
    /// copies it did land are skipped as already present.
    func adoptGlobalCredentials(into profileID: UUID) {
        guard !adoptionComplete() else { return }

        let global = ActiveProfileDefaults.Mode.legacyFallback
        let scoped = ActiveProfileDefaults.Mode.profile(profileID)
        guard
            let globalMetadata = MCPProfileCredentialKeys.metadataKey(for: global),
            let scopedMetadata = MCPProfileCredentialKeys.metadataKey(for: scoped),
            let globalTokens = MCPProfileCredentialKeys.clientTokenPrefix(for: global),
            let scopedTokens = MCPProfileCredentialKeys.clientTokenPrefix(for: scoped),
            let globalLegacy = MCPProfileCredentialKeys.legacyTokenKey(for: global),
            let scopedLegacy = MCPProfileCredentialKeys.legacyTokenKey(for: scoped)
        else { return }

        let clients = adoptClientAccess(
            globalMetadata: globalMetadata,
            scopedMetadata: scopedMetadata,
            globalTokens: globalTokens,
            scopedTokens: scopedTokens
        )
        let legacy = adoptLegacyToken(global: globalLegacy, scoped: scopedLegacy)
        guard clients, legacy else { return }
        defaults.set(true, forKey: Self.markerKey)
    }

    /// Returns false only when the copy could not be completed, so the caller
    /// leaves the marker unset.
    ///
    /// Existing scoped records are merged with, not replaced by, the global
    /// ones — and never overwritten. Bailing out whenever a scoped registry
    /// already existed stranded the common recovery: a user who reconnects one
    /// client in Settings creates that registry, and every other pre-upgrade
    /// client would then be orphaned for good on the next boot.
    private func adoptClientAccess(
        globalMetadata: String,
        scopedMetadata: String,
        globalTokens: String,
        scopedTokens: String
    ) -> Bool {
        let existing: [MCPClientAccessRecord] = defaults.data(forKey: scopedMetadata)
            .flatMap { try? JSONDecoder().decode([MCPClientAccessRecord].self, from: $0) }
            ?? []
        let existingIDs = Set(existing.map(\.id))
        guard let data = defaults.data(forKey: globalMetadata),
              let records = try? JSONDecoder().decode([MCPClientAccessRecord].self, from: data),
              !records.isEmpty
        else { return true }

        var adopted: [MCPClientAccessRecord] = []
        var complete = true
        for record in records where !existingIDs.contains(record.id) {
            // A record whose token did not come across would show in Settings
            // as a connected client that 401s on every call, which is exactly
            // the failure this migration exists to end.
            guard let token = keychain.get(globalTokens + record.id), !token.isEmpty else { continue }
            if keychain.get(scopedTokens + record.id) == nil {
                do {
                    try keychain.set(token, forKey: scopedTokens + record.id)
                } catch {
                    NSLog("[MCPCredentialMigration] could not adopt the token for %@: %@",
                          record.id, error.localizedDescription)
                    complete = false
                    continue
                }
            }
            adopted.append(record)
        }

        // Metadata is written last and only on a complete run: the store reads
        // it to decide which tokens to load, so publishing it while a copy is
        // still missing would register a client that cannot authenticate.
        guard complete else { return false }
        guard !adopted.isEmpty else { return true }
        guard let encoded = try? JSONEncoder().encode(existing + adopted) else { return false }
        defaults.set(encoded, forKey: scopedMetadata)
        return true
    }

    /// The shared token is overwritten rather than preserved when a scoped one
    /// already exists. Nothing can be bound to that scoped value: `connect`
    /// always configures a client with its own per-client token, so a scoped
    /// shared token present before the first adoption was minted on demand by
    /// `loadOrCreateToken` and no client holds it. The pre-profile token, by
    /// contrast, is what every client configured before per-client tokens
    /// existed still sends.
    private func adoptLegacyToken(global: String, scoped: String) -> Bool {
        guard let token = keychain.get(global), !token.isEmpty else { return true }
        guard keychain.get(scoped) != token else { return true }
        do {
            try keychain.set(token, forKey: scoped)
        } catch {
            NSLog("[MCPCredentialMigration] could not adopt the shared token: %@",
                  error.localizedDescription)
            return false
        }
        return true
    }
}
