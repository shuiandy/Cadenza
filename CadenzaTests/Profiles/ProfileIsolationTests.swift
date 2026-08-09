import Foundation
import SwiftData
import Testing

@testable import Cadenza

/// INV-8: the TestHost never touches the real registry, store, audio
/// library, Keychain, or session record; the migration entry point is
/// unreachable from ephemeral runs; and the migration sources contain no
/// auth-key literals.
@Suite("Profile Test Isolation", .serialized)
struct ProfileIsolationTests {

    // MARK: - 1. TestHost wiring is fully ephemeral

    @Test @MainActor
    func testHostRunsOnEphemeralAuthAndInMemoryStore() throws {
        #expect(AppState.isRunningTests)
        let state = try #require(AppState.shared)

        // Auth surface: ephemeral secret store and user store — no real
        // Keychain reads, no defaults-backed session record.
        let backing = state.cadenzaAuth.authStorageBackingForTesting
        #expect(backing.secretStore == .ephemeral)
        #expect(backing.userStore == .ephemeral)

        // The app-level container is in-memory; the profile bootstrap
        // (and with it the migration entry) never ran.
        let container = try #require(state.store?.modelContainer)
        #expect(!container.configurations.isEmpty)
        #expect(container.configurations.allSatisfy { $0.isStoredInMemoryOnly })
        #expect(state.profileBootContext == nil)

        // Chat history stays in memory — construction never touches the
        // real ChatHistory directory — and no startup backup runs at all.
        #expect(state.chatHistory.storageForTesting == .disabled)
        #expect(AppState.startupBackupPlan(isRunningTests: true, context: nil)
            == .skip(reason: "test run"))
    }

    /// Startup backup routing follows the boot mode strictly: profile
    /// boots use the profile directory or skip, the legacy backup exists
    /// only for the pre-commit fallback, and test runs never back up.
    @Test func startupBackupPlanFollowsBootMode() {
        let id = UUID()
        let store = URL(fileURLWithPath: "/tmp/profile/Cadenza.store")
        let backups = URL(fileURLWithPath: "/tmp/profile/Backups")
        let profileContext = ProfileBootContext(
            mode: .profile(id), storeURL: store,
            chatHistoryDirectory: nil, backupsDirectory: backups
        )
        #expect(AppState.startupBackupPlan(isRunningTests: false, context: profileContext)
            == .store(store, into: backups))

        let degraded = ProfileBootContext(
            mode: .profile(id), storeURL: store,
            chatHistoryDirectory: nil, backupsDirectory: nil
        )
        #expect(AppState.startupBackupPlan(isRunningTests: false, context: degraded)
            == .skip(reason: "profile backups directory unavailable"))

        #expect(AppState.startupBackupPlan(
            isRunningTests: false, context: .legacy(reason: "r")
        ) == .legacy)
        #expect(AppState.startupBackupPlan(
            isRunningTests: true, context: profileContext
        ) == .skip(reason: "test run"))
        #expect(AppState.startupBackupPlan(
            isRunningTests: false, context: .halted(reason: "h")
        ) == .skip(reason: "boot halted"))
    }

    /// Chat persistence is opt-in by configuration: an unconfigured
    /// manager keeps sessions in memory only, and configuring a directory
    /// starts persisting there — the legacy directory is never an implicit
    /// default.
    @Test @MainActor
    func chatHistoryPersistsOnlyWhereConfigured() throws {
        let manager = ChatHistoryManager()
        #expect(manager.storageForTesting == .disabled)
        let session = ChatSession(title: "s", messages: [], provider: "p", model: "m")
        manager.save(session)
        #expect(manager.load(id: session.id)?.id == session.id)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-isolation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        manager.configure(directory: directory)
        manager.save(session)
        #expect(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("\(session.id.uuidString).json").path
        ))
    }

    // MARK: - 2. Ephemeral bootstrap path audit

    /// Component-aware containment: string prefixing would let a sibling
    /// like `/tmp/base-evil` pass for `/tmp/base`.
    static func isContained(_ path: String, inside root: String) -> Bool {
        let pathComponents = URL(fileURLWithPath: path).pathComponents
        let rootComponents = URL(fileURLWithPath: root).pathComponents
        guard pathComponents.count >= rootComponents.count else { return false }
        return Array(pathComponents.prefix(rootComponents.count)) == rootComponents
    }

    @Test func containmentRejectsSiblingPrefixEscapes() {
        #expect(Self.isContained("/tmp/base/x", inside: "/tmp/base"))
        #expect(Self.isContained("/tmp/base", inside: "/tmp/base"))
        #expect(!Self.isContained("/tmp/base-evil/x", inside: "/tmp/base"))
        #expect(!Self.isContained("/tmp", inside: "/tmp/base"))
    }

    /// Runs a full bootstrap (fresh-install shape) against an ephemeral
    /// base with an auditing seam: every path that crosses the seam stays
    /// under the base (component containment), and the REAL registry and
    /// legacy store are unchanged by content hash and identity. (The audit
    /// covers seam-routed IO; SQLite/SwiftData IO is bounded by the store
    /// URLs the bootstrap hands them, asserted via the returned context.)
    @Test @MainActor
    func ephemeralBootstrapTouchesOnlyItsOwnTree() throws {
        let livePaths = ProfilePaths.live()
        struct Fingerprint: Equatable {
            var exists: Bool
            var inode: Int?
            var sha256: String?
        }
        func fingerprint(_ url: URL) -> Fingerprint {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            else { return Fingerprint(exists: false, inode: nil, sha256: nil) }
            let hash = attributes[.type] as? FileAttributeType == .typeRegular
                ? try? LiveFileOperations().sha256(of: url) : nil
            return Fingerprint(
                exists: true,
                inode: attributes[.systemFileNumber] as? Int,
                sha256: hash
            )
        }
        let registryBefore = fingerprint(livePaths.registryURL)
        let storeBefore = fingerprint(livePaths.legacyStoreURL)

        let environment = ProfileEnvironment.current()
        #expect(environment.isEphemeral)
        let paths = environment.paths
        try FileManager.default.createDirectory(
            at: paths.root, withIntermediateDirectories: true
        )
        defer {
            if case .ephemeral(let base) = environment {
                try? FileManager.default.removeItem(at: base)
            }
        }
        let suiteName = "isolation-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let operations = InstrumentedFileOperations()
        let audioRoot = paths.root.appendingPathComponent("AudioRoot", isDirectory: true)
        try FileManager.default.createDirectory(at: audioRoot, withIntermediateDirectories: true)

        let context = ProfileBootstrap.run(dependencies: .init(
            paths: paths,
            registry: InMemoryProfileRegistry(),
            fileOperations: operations,
            backupDriver: LiveSQLiteBackupDriver(),
            audioRoot: { audioRoot },
            audioDirectoryState: { .init(bookmark: nil, path: audioRoot.path, kind: .userSelected) },
            scopedDefaults: ProfileScopedDefaults(defaults: defaults, persistentDomainName: suiteName),
            now: { Date(timeIntervalSince1970: 1_785_628_800) }
        ))

        guard case .profile = context.mode else {
            Issue.record("expected profile boot, got \(context.mode)")
            return
        }
        // Every URL the bootstrap will open a store at is inside the base.
        for url in [context.storeURL, context.chatHistoryDirectory, context.backupsDirectory] {
            #expect(url?.path.hasPrefix(paths.root.path) == true)
        }
        let recorded = operations.recorded
        #expect(!recorded.touchedPaths.isEmpty)
        // The skip-version probe legitimately checks the pre-Cadenza store
        // location one level above the root — still inside the ephemeral
        // base, which is the isolation boundary.
        let boundary = paths.root.deletingLastPathComponent().path
        for path in recorded.touchedPaths {
            #expect(Self.isContained(path, inside: boundary))
        }

        #expect(fingerprint(livePaths.registryURL) == registryBefore)
        #expect(fingerprint(livePaths.legacyStoreURL) == storeBefore)
    }

    // MARK: - 3. Profile sources touch session state only through the seams

    /// Per-profile session storage lives in this layer by design (INV-5),
    /// so the gate pins how it may be touched instead of forbidding it
    /// outright: concrete Keychain access stays behind the AuthSecretStore
    /// seam everywhere, and the raw `cadenza.session` key literals appear
    /// only in the two authority files — the key-scheme definition and the
    /// M2 migration that retires the global keys. Every other file must go
    /// through SessionTokenKey.
    @Test func profileSourcesContainNoAuthLiterals() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .resolvingSymlinksInPath()
        let profilesRoot = repoRoot
            .appendingPathComponent("Cadenza/Services/Profiles", isDirectory: true)
        let enumerator = try #require(FileManager.default.enumerator(
            at: profilesRoot, includingPropertiesForKeys: [.isRegularFileKey]
        ))
        let forbiddenEverywhere = [
            "KeychainManager",
            "OAuthTokenManager",
            "UserDefaultsUserStore",
        ]
        let sessionKeyAuthorityFiles: Set<String> = [
            "ProfileSessionStore.swift",
            "SessionMigrations.swift",
        ]
        var scanned = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            scanned += 1
            let contents = try String(contentsOf: url, encoding: .utf8)
            for pattern in forbiddenEverywhere {
                #expect(
                    !contents.contains(pattern),
                    "\(url.lastPathComponent) references \(pattern)"
                )
            }
            if !sessionKeyAuthorityFiles.contains(url.lastPathComponent) {
                #expect(
                    !contents.contains("cadenza.session"),
                    "\(url.lastPathComponent) names a session key outside the authority files"
                )
            }
        }
        #expect(scanned >= 10)
    }

    /// The scoped-defaults inventory must never include an auth key.
    @Test func scopedDefaultsInventoryExcludesAuthKeys() {
        for key in ProfileScopedDefaults.scopedKeys {
            #expect(!key.contains("cadenza.session"))
            #expect(!key.lowercased().contains("token"))
        }
        for prefix in ProfileScopedDefaults.scopedKeyPrefixes {
            #expect(!prefix.contains("cadenza.session"))
            #expect(!prefix.lowercased().contains("websync"))
        }
    }
}
