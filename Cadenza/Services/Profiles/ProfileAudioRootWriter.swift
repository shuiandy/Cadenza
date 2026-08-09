import Foundation

/// Registry-side recorder for the active profile's audio directory
/// (spec 4.2): the boot installs it into `StorageLocationManager`, which
/// then treats the registry as the root authority — a root change commits
/// there first, and a refreshed security-scoped bookmark is written back
/// best-effort on the main actor, where every runtime registry mutation
/// is serialized.
enum ProfileAudioRootWriter {
    /// Stable app-managed default root for a profile, keyed by ID so
    /// display-name collisions can never alias two profiles onto one
    /// directory.
    static func appManagedDefaultPath(profileID: UUID) -> String {
        DebugDataRoot.documentsDirectory()
            .appendingPathComponent("Cadenza", isDirectory: true)
            .appendingPathComponent("Profiles", isDirectory: true)
            .appendingPathComponent(profileID.uuidString, isDirectory: true)
            .path
    }

    static func liveAuthority(for profile: Profile) -> StorageLocationManager.ProfileRootAuthority {
        let profileID = profile.id
        return StorageLocationManager.ProfileRootAuthority(
            bookmark: profile.audioDirectory.bookmark,
            path: profile.audioDirectory.path,
            kind: profile.audioDirectory.kind,
            profileDefaultPath: appManagedDefaultPath(profileID: profileID),
            recordRefreshedBookmark: { payload in
                // Resolution can run off-main; the registry write hops to
                // the main actor, re-loads the latest document, and applies
                // only while the recorded directory still matches the
                // identity the bookmark was refreshed from.
                Task { @MainActor in
                    do {
                        try applyRefreshedBookmark(
                            payload, profileID: profileID, registry: liveRegistry()
                        )
                    } catch {
                        NSLog(
                            "[ProfileAudioRoot] bookmark refresh not recorded: %@",
                            String(describing: error)
                        )
                    }
                }
            },
            recordRootChange: { bookmark, path, kind in
                try update(profileID: profileID, registry: liveRegistry()) { directory in
                    directory.bookmark = bookmark
                    directory.path = path
                    directory.kind = kind
                    return true
                }
            }
        )
    }

    /// Ownership-conditioned refresh: writes the refreshed bookmark only
    /// while the latest registry still records exactly the directory it
    /// was resolved from; a root committed in between makes this a no-op.
    @MainActor
    static func applyRefreshedBookmark(
        _ payload: StorageLocationManager.RefreshedBookmark,
        profileID: UUID,
        registry: ProfileRegistryProviding
    ) throws {
        try update(profileID: profileID, registry: registry) { directory in
            guard directory.bookmark == payload.expectedBookmark,
                  directory.path == payload.expectedPath,
                  directory.kind == payload.expectedKind else {
                return false
            }
            directory.bookmark = payload.refreshed
            return true
        }
    }

    /// Bookmark relink repair: replaces only the bookmark bytes of the
    /// active profile's user-selected root. Identity-conditioned on the
    /// exact recorded lexical path — a registry that no longer records
    /// that identity refuses with `rootChanged` instead of writing
    /// anything, so a root switched between the offer and the save can
    /// never receive a bookmark taken for the old directory.
    @MainActor
    static func applyRelinkedBookmark(
        _ bookmark: Data,
        expectedPath: String,
        profileID: UUID,
        registry: ProfileRegistryProviding
    ) throws {
        var identityMatches = false
        try update(profileID: profileID, registry: registry) { directory in
            guard directory.kind == .userSelected,
                  LexicalPathIdentity.equals(directory.path, expectedPath) else {
                return false
            }
            identityMatches = true
            directory.bookmark = bookmark
            return true
        }
        guard identityMatches else { throw RootWriteError.rootChanged }
    }

    @MainActor
    static func applyRelinkedBookmarkLive(
        _ bookmark: Data, expectedPath: String, profileID: UUID
    ) throws {
        try applyRelinkedBookmark(
            bookmark, expectedPath: expectedPath, profileID: profileID,
            registry: liveRegistry()
        )
    }

    private static func liveRegistry() -> DiskProfileRegistry {
        let paths = ProfilePaths.live()
        return DiskProfileRegistry(
            registryURL: paths.registryURL, fileOperations: LiveFileOperations()
        )
    }

    enum RootWriteError: Error, Equatable, LocalizedError {
        case profileMissing
        case notActiveProfile
        case profileLocked
        case operationInFlight
        /// The registry no longer records the directory a repair was
        /// prepared for; nothing was written.
        case rootChanged
        /// The save threw and the reread proved the old shape: nothing
        /// changed, the caller may retry.
        case saveNotCommitted(String)
        /// The save threw and the reread could not prove either shape:
        /// the registry may durably hold the new value while this
        /// process still resolves the old one, so root-dependent work
        /// must stay blocked until restart.
        case commitIndeterminate(String)

        var errorDescription: String? { localizedMessage() }

        func localizedMessage(locale: Locale? = nil) -> String {
            switch self {
            case .profileMissing:
                return LocalizedBundle.string(
                    "The active profile is missing from the registry.", locale: locale
                )
            case .notActiveProfile:
                return LocalizedBundle.string(
                    "This profile is no longer active, so the change was not saved.",
                    locale: locale
                )
            case .profileLocked:
                return LocalizedBundle.string("This profile is locked.", locale: locale)
            case .operationInFlight:
                return LocalizedBundle.string(
                    "Another profile operation is in progress — try again when it finishes.",
                    locale: locale
                )
            case .rootChanged:
                return LocalizedBundle.string(
                    "The recorded storage folder changed before the repair could save, so nothing was updated.",
                    locale: locale
                )
            case .saveNotCommitted:
                return LocalizedBundle.string(
                    "The change couldn't be saved — try again.", locale: locale
                )
            case .commitIndeterminate:
                return LocalizedBundle.string(
                    "A profile change didn't finish. Quit and reopen Cadenza to continue.",
                    locale: locale
                )
            }
        }
    }

    /// Load-mutate-save on the main actor with a fresh document: the
    /// mutation applies only when this process's profile is still the
    /// registry's active one, unlocked, and no two-phase operation is in
    /// flight — a stale process after a switch request must never update
    /// its old profile behind the new authority. The mutate closure
    /// returns whether anything should be saved. The save is
    /// classified: returning without error means proven committed, so
    /// the caller may advance its own cache.
    @MainActor
    static func update(
        profileID: UUID,
        registry: ProfileRegistryProviding,
        _ mutate: (inout Profile.AudioDirectory) -> Bool
    ) throws {
        let document = try registry.load()
        guard let index = document.profiles.firstIndex(where: { $0.id == profileID }) else {
            throw RootWriteError.profileMissing
        }
        guard document.activeProfileID == profileID else {
            throw RootWriteError.notActiveProfile
        }
        guard !document.profiles[index].isLocked else {
            throw RootWriteError.profileLocked
        }
        guard document.pendingBinding == nil, document.pendingTransfer == nil else {
            throw RootWriteError.operationInFlight
        }
        var intended = document
        guard mutate(&intended.profiles[index].audioDirectory) else { return }
        switch ProfileSwitchCoordinator.classifiedSave(
            old: document, intended: intended, registry: registry
        ) {
        case .committed:
            return
        case .notCommitted(let detail):
            throw RootWriteError.saveNotCommitted(detail)
        case .indeterminate(let detail):
            // Poisoned at the single write path so every caller (root
            // change and bookmark refresh) blocks root-dependent work:
            // recording under a stale root cache strands files.
            StorageMigrationGate.shared.markIndeterminate()
            throw RootWriteError.commitIndeterminate(detail)
        }
    }
}
