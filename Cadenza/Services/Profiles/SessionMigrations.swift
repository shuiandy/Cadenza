import Foundation

/// Shared dependency bundle for the boot-time session stages (binding
/// recovery, M2, M3). All stages run on the main actor before any regular
/// container opens; every store below is the profile-scoped one, except the
/// legacy global reads M2 exists to retire.
@MainActor
struct SessionMigrationDependencies {
    let registry: ProfileRegistryProviding
    let secretStore: AuthSecretStore
    let sessionUserStore: (UUID) -> SessionUserStoring
    let marker: HistoricalConsentMarking
    let storeURL: (UUID) -> URL
    let storePresence: (URL) throws -> Bool
    /// Classified probe of `Profiles/<id>/`: true when any node exists at
    /// the directory path, false only on definite absence.
    let profileDirectoryPresence: (UUID) throws -> Bool
    let defaults: UserDefaults
    let backend: CadenzaBackendConfig.Resolved
    /// App-managed default audio root for a newly created profile, keyed
    /// by the profile ID so roots can never alias across profiles.
    let newLocalAudioDirectory: (UUID) -> Profile.AudioDirectory
    let now: () -> Date

    var bindingDependencies: ProfileBindingTransaction.Dependencies {
        ProfileBindingTransaction.Dependencies(
            registry: registry,
            secretStore: secretStore,
            sessionUserStore: sessionUserStore,
            marker: marker,
            storeURL: storeURL,
            storePresence: storePresence,
            now: now
        )
    }
}

/// M2 (spec §6.5): retires the pre-profile global session. A global user
/// record with a userID drives a full two-phase binding of the M1 profile
/// against the official backend — the only issuer pre-profile sessions
/// ever had — then maps the historical-disclosure consent and deletes the
/// global keys. No user record → nothing happens. Re-entrant: the global
/// user record is the beacon; it is deleted last, so any crash re-enters
/// and converges. Unknown evidence halts the boot.
@MainActor
enum M2SessionMigration {
    static let globalUserKey = "cadenza.session.user.json"

    enum Outcome: Equatable {
        case nothingToDo
        case completed(profileID: UUID)
        case halted(String)
    }

    static func run(session: SessionMigrationDependencies) -> Outcome {
        // Classified read: only a definitely-absent record means nothing to
        // migrate. A record of an unexpected type is legacy session
        // evidence that cannot be interpreted — halt, never let M3 shape
        // the registry as if no session existed.
        guard let rawRecord = session.defaults.object(forKey: globalUserKey) else {
            return .nothingToDo
        }
        guard let userData = rawRecord as? Data else {
            return .halted("global session user record has unexpected type")
        }
        let legacyUser: CadenzaAuthService.SignedInUser
        do {
            legacyUser = try JSONDecoder().decode(
                CadenzaAuthService.SignedInUser.self, from: userData
            )
        } catch {
            return .halted("global session user undecodable: \(error)")
        }
        guard !legacyUser.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .halted("global session user has no userID")
        }

        let document: ProfileRegistryDocument
        do {
            document = try session.registry.load()
        } catch {
            return .halted("registry unreadable: \(error)")
        }
        guard document.pendingBinding == nil, document.pendingTransfer == nil else {
            return .halted("pending operation left unresolved before session migration")
        }

        let origin = session.backend.origin
        // Re-entry after a committed binding whose cleanup crashed: the
        // account is bound, only the global keys remain to remove.
        if let bound = document.profiles.first(where: {
            $0.boundAccount?.originKey == origin.originKey
                && $0.boundAccount.map { AccountIdentity.matches($0.userID, legacyUser.id) } == true
        }) {
            return finalize(profileID: bound.id, userID: legacyUser.id, session: session)
        }

        // First run operates on the M1 shape: exactly one standard,
        // unbound profile. Anything else is unclassifiable.
        guard document.profiles.count == 1,
              let target = document.profiles.first,
              target.kind == .standard,
              target.boundAccount == nil else {
            return .halted("unexpected registry shape for session migration")
        }

        // A missing global token is a legitimate state (expired or lost
        // Keychain item): the binding proceeds tokenless and the profile
        // presents `.expired` (INV-3). An unreadable Keychain is unknown.
        let tokenRaw: String?
        do {
            tokenRaw = try session.secretStore.getClassified(SessionTokenKey.legacyGlobalAccount)
        } catch {
            return .halted("global token unreadable: \(error)")
        }

        let request = ProfileBindingTransaction.Request(
            profileID: target.id,
            userID: legacyUser.id,
            origin: origin,
            apiBaseURL: session.backend.apiBaseURL.absoluteString,
            user: SessionUser(
                userID: legacyUser.id,
                email: legacyUser.email,
                displayName: legacyUser.displayName,
                pictureURL: legacyUser.pictureURL
            ),
            tokenRaw: (tokenRaw?.isEmpty ?? true) ? nil : tokenRaw
        )
        do {
            _ = try ProfileBindingTransaction.runSync(
                request: request, dependencies: session.bindingDependencies
            )
        } catch {
            return .halted("session binding failed: \(error)")
        }
        return finalize(profileID: target.id, userID: legacyUser.id, session: session)
    }

    /// Consent mapping (§6.6) plus global-key retirement. The disclosure
    /// record is honored exactly: absent or false stays undecided; an
    /// accepted disclosure maps to with-audio only when the audio
    /// preference was explicitly true — every valid acceptance path wrote
    /// that key, so an absent value is not affirmative audio intent and
    /// fails closed to text-only. Existing scoped consent is never
    /// overwritten. The global user record is removed last — it is the
    /// re-entry beacon.
    private static func finalize(
        profileID: UUID, userID: String, session: SessionMigrationDependencies
    ) -> Outcome {
        let scope = ProfileDefaultsScope(defaults: session.defaults, profileID: profileID)
        if scope.string(forKey: HistoricalSyncConsent.scopedKeyBase) == nil {
            let disclosure = session.defaults.bool(
                forKey: "webSync.historicalDisclosure.v1.\(userID)"
            )
            if disclosure {
                let audioValue = session.defaults.object(
                    forKey: "webSync.uploadAudio.v1.\(userID)"
                ) as? Bool
                let consent: HistoricalSyncConsent =
                    audioValue == true ? .withAudio : .textOnly
                consent.write(to: scope)
            }
        }

        do {
            try session.secretStore.remove(SessionTokenKey.legacyGlobalAccount)
        } catch {
            return .halted("global token removal failed: \(error)")
        }
        session.defaults.removeObject(forKey: globalUserKey)
        return .completed(profileID: profileID)
    }
}

/// M3 (spec §6.5): establishes the permanent system Local profile. The M1
/// profile, if still unbound, is promoted in place (kind system, renamed
/// "Local" — the data does not move); if M2 bound it, a fresh empty Local
/// is created alongside with an unmaterialized store and the bound profile
/// stays active. Idempotent: an existing system profile means done.
@MainActor
enum M3LocalMigration {
    enum Outcome: Equatable {
        case alreadyEstablished
        case promoted(profileID: UUID)
        case created(profileID: UUID)
        case halted(String)
    }

    static func run(session: SessionMigrationDependencies) -> Outcome {
        let document: ProfileRegistryDocument
        do {
            document = try session.registry.load()
        } catch {
            return .halted("registry unreadable: \(error)")
        }
        if let systemIndex = document.profiles.firstIndex(where: { $0.kind == .system }) {
            // Permanent-Local semantics on re-entry: the registry validator
            // already enforces single/unbound/unlocked for system profiles
            // on every load; the fixed name is repaired here — the spec
            // names the system profile "Local" and offers no rename
            // surface for it.
            if document.profiles[systemIndex].name != "Local" {
                var repaired = document
                repaired.profiles[systemIndex].name = "Local"
                do {
                    try session.registry.save(repaired)
                } catch {
                    return .halted("local name repair failed: \(error)")
                }
            }
            return .alreadyEstablished
        }
        guard document.pendingBinding == nil, document.pendingTransfer == nil else {
            return .halted("pending operation left unresolved before local establishment")
        }
        guard document.profiles.count == 1,
              let sole = document.profiles.first,
              sole.kind == .standard else {
            return .halted("unexpected registry shape for local establishment")
        }

        if sole.boundAccount == nil {
            var updated = document
            updated.profiles[0].kind = .system
            updated.profiles[0].name = "Local"
            do {
                try session.registry.save(updated)
            } catch {
                return .halted("local promotion failed: \(error)")
            }
            return .promoted(profileID: sole.id)
        }

        let localID = UUID()
        // Residue gate for the new identity: its directory must be
        // definitely absent — an occupant (or an unprobeable node) can
        // never be adopted as a fresh empty profile.
        do {
            if try session.profileDirectoryPresence(localID) {
                return .halted("new local profile directory already occupied")
            }
        } catch {
            return .halted("new local profile directory unprobeable: \(error)")
        }
        // A fresh Local starts with clean scoped preferences: the mapping
        // marker is set up front so the boot reconciliation never copies
        // the (account-flavored) global values into it. Written before the
        // registry commit — an orphan marker for a discarded UUID is
        // harmless, the reverse order would leak globals on a crash.
        session.defaults.set(
            true,
            forKey: ProfileScopedDefaults.scopedKey(
                ProfileScopedDefaults.mappingMarkerKey, profileID: localID
            )
        )
        var updated = document
        updated.profiles.append(Profile(
            id: localID,
            kind: .system,
            name: "Local",
            colorHex: nil,
            createdAt: session.now(),
            lastActiveAt: session.now(),
            audioDirectory: session.newLocalAudioDirectory(localID),
            boundAccount: nil,
            lockOnSignOut: false,
            isLocked: false,
            storeMaterialized: false,
            sessionDisposition: .active
        ))
        do {
            try session.registry.save(updated)
        } catch {
            return .halted("local creation failed: \(error)")
        }
        return .created(profileID: localID)
    }
}
