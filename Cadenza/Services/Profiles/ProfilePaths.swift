import Foundation

/// Single source of truth for every profile-related filesystem location.
/// Constructed from a base directory so tests operate on a unique temporary
/// root and never touch the real application-support tree.
struct ProfilePaths: Sendable {
    /// `…/Application Support/Cadenza/`.
    let root: URL

    static func live() -> ProfilePaths {
        let appSupport = DebugDataRoot.applicationSupportDirectory()
        return ProfilePaths(root: appSupport.appendingPathComponent("Cadenza", isDirectory: true))
    }

    var registryURL: URL {
        root.appendingPathComponent("profiles.json")
    }

    var migrationDirectory: URL {
        root.appendingPathComponent("Migration", isDirectory: true)
    }

    var journalURL: URL {
        migrationDirectory.appendingPathComponent("journal.json")
    }

    func transferStagingDirectory(transactionID: UUID) -> URL {
        migrationDirectory
            .appendingPathComponent("transfer-staging", isDirectory: true)
            .appendingPathComponent(transactionID.uuidString, isDirectory: true)
    }

    func stagingDirectory(profileID: UUID) -> URL {
        migrationDirectory
            .appendingPathComponent("staging", isDirectory: true)
            .appendingPathComponent(profileID.uuidString, isDirectory: true)
    }

    var profilesDirectory: URL {
        root.appendingPathComponent("Profiles", isDirectory: true)
    }

    func profileDirectory(_ id: UUID) -> URL {
        profilesDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func storeURL(_ id: UUID) -> URL {
        profileDirectory(id).appendingPathComponent("Cadenza.store")
    }

    func sessionUserURL(_ id: UUID) -> URL {
        profileDirectory(id).appendingPathComponent("session-user.json")
    }

    func chatHistoryDirectory(_ id: UUID) -> URL {
        profileDirectory(id).appendingPathComponent("ChatHistory", isDirectory: true)
    }

    func backupsDirectory(_ id: UUID) -> URL {
        profileDirectory(id).appendingPathComponent("Backups", isDirectory: true)
    }

    // MARK: - Legacy (pre-registry) locations

    /// Store used before the profile registry existed.
    var legacyStoreURL: URL {
        root.appendingPathComponent("Cadenza.store")
    }

    /// Store used before it moved under the Cadenza subdirectory — the
    /// skip-version upgrade source (INV-16).
    var preLegacyStoreURL: URL {
        root.deletingLastPathComponent().appendingPathComponent("default.store")
    }

    var legacyChatHistoryDirectory: URL {
        root.appendingPathComponent("ChatHistory", isDirectory: true)
    }
}

/// The three SQLite files that make up one store. The WAL and SHM entries
/// may not exist on disk; every consumer treats them as optional siblings.
struct StoreTrioURL: Sendable, Equatable {
    let base: URL

    var wal: URL { URL(fileURLWithPath: base.path + "-wal") }
    var shm: URL { URL(fileURLWithPath: base.path + "-shm") }
}
