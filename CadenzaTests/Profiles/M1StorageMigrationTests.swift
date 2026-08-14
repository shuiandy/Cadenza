import Foundation
import SQLite3
import SwiftData
import Testing

@testable import Cadenza

/// M1 end-to-end pipeline, boundary resume semantics, pre-commit fallback,
/// fresh install, audio-root reconciliation, and the scoped-defaults
/// mapping. The exhaustive §9.3 failure matrix lives in its own suite.
@Suite("M1 Storage Migration", .serialized)
struct M1StorageMigrationTests {

    struct Fixture {
        let base: URL
        let paths: ProfilePaths
        let audioRoot: URL
        let defaults: UserDefaults
        let suiteName: String
        let dependencies: M1StorageMigration.Dependencies

        func cleanup() {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: base)
        }
    }

    private func makeFixture(
        fileOperations: (any FileOperations)? = nil,
        backupDriver: (any SQLiteBackupDriver)? = nil
    ) throws -> Fixture {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("m1-tests-\(UUID().uuidString)", isDirectory: true)
        let audioRoot = base.appendingPathComponent("AudioRoot", isDirectory: true)
        try FileManager.default.createDirectory(at: audioRoot, withIntermediateDirectories: true)
        let paths = ProfilePaths(root: base.appendingPathComponent("Cadenza", isDirectory: true))
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        let suiteName = "m1-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let operations = fileOperations ?? LiveFileOperations()
        let dependencies = M1StorageMigration.Dependencies(
            paths: paths,
            registry: DiskProfileRegistry(
                registryURL: paths.registryURL, fileOperations: operations
            ),
            fileOperations: operations,
            backupDriver: backupDriver ?? LiveSQLiteBackupDriver(),
            audioRoot: { audioRoot },
            audioDirectoryState: { .init(bookmark: nil, path: audioRoot.path, kind: .userSelected) },
            scopedDefaults: ProfileScopedDefaults(defaults: defaults, persistentDomainName: suiteName),
            now: { Date(timeIntervalSince1970: 1_785_628_800) }
        )
        return Fixture(
            base: base, paths: paths, audioRoot: audioRoot,
            defaults: defaults, suiteName: suiteName, dependencies: dependencies
        )
    }

    /// Source store at the legacy location with three recordings:
    /// in-root legacy absolute (rewritable), out-of-root legacy absolute
    /// (retained), and an already-relative row. Plus one chat session file.
    @MainActor
    private func populateSource(_ fixture: Fixture) throws {
        let container = try ModelContainer(
            for: RecordingsStore.schema,
            configurations: ModelConfiguration(url: fixture.paths.legacyStoreURL)
        )
        let context = ModelContext(container)

        let inRoot = Recording(id: UUID(), title: "in-root")
        inRoot.audioFilePath = fixture.audioRoot.appendingPathComponent("a/one.m4a").path
        inRoot.audioSegmentsDirectory = fixture.audioRoot.appendingPathComponent("a/segments").path
        context.insert(inRoot)

        let outOfRoot = Recording(id: UUID(), title: "out-of-root")
        outOfRoot.audioFilePath = "/elsewhere/two.m4a"
        context.insert(outOfRoot)

        let alreadyRelative = Recording(id: UUID(), title: "relative")
        alreadyRelative.audioFilePath = "rel/three.m4a"
        context.insert(alreadyRelative)

        try context.save()

        try FileManager.default.createDirectory(
            at: fixture.paths.legacyChatHistoryDirectory, withIntermediateDirectories: true
        )
        try Data("{\"id\":\"session\"}".utf8).write(
            to: fixture.paths.legacyChatHistoryDirectory.appendingPathComponent("s1.json")
        )
    }

    @MainActor
    private func openProfileStore(_ fixture: Fixture, id: UUID) throws -> [Recording] {
        let container = try ModelContainer(
            for: RecordingsStore.schema,
            configurations: ModelConfiguration(url: fixture.paths.storeURL(id), allowsSave: false)
        )
        return try ModelContext(container).fetch(FetchDescriptor<Recording>())
    }

    // MARK: - Happy path

    @Test @MainActor
    func migratesInheritedDataEndToEnd() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try populateSource(fixture)

        let context = ProfileBootstrap.run(dependencies: fixture.dependencies)
        guard case .profile(let id) = context.mode else {
            Issue.record("expected profile boot, got \(context.mode)")
            return
        }
        #expect(context.storeURL == fixture.paths.storeURL(id))

        // Registry: one standard profile, committed atomically.
        let document = try fixture.dependencies.registry.load()
        #expect(document.activeProfileID == id)
        #expect(document.profiles.count == 1)
        #expect(document.profiles.first?.kind == .standard)

        // Store content: ownership backfilled, §10.3 rewrites applied
        // exactly where provable.
        let recordings = try openProfileStore(fixture, id: id)
        #expect(recordings.count == 3)
        for recording in recordings {
            #expect(recording.audioFileOwnership == AudioFileOwnership.unknownLegacy.rawValue)
        }
        let byTitle = Dictionary(uniqueKeysWithValues: recordings.map { ($0.title, $0) })
        #expect(byTitle["in-root"]?.audioFileReference == .relative("a/one.m4a"))
        #expect(byTitle["in-root"]?.segmentsDirectoryReference == .relative("a/segments"))
        #expect(byTitle["out-of-root"]?.audioFileReference == .legacyAbsolute("/elsewhere/two.m4a"))
        #expect(byTitle["relative"]?.audioFileReference == .relative("rel/three.m4a"))

        // Chat history copied; the source directory is retained.
        #expect(FileManager.default.fileExists(
            atPath: fixture.paths.chatHistoryDirectory(id).appendingPathComponent("s1.json").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: fixture.paths.legacyChatHistoryDirectory.appendingPathComponent("s1.json").path
        ))

        // Source retired with the .migrated-<ts> suffix, original name gone.
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.legacyStoreURL.path))
        let retained = try FileManager.default.contentsOfDirectory(atPath: fixture.paths.root.path)
            .filter { $0.hasPrefix("Cadenza.store.migrated-") }
        #expect(retained.count == 1)

        // Journal converged; staging cleaned up by the rename.
        let journal = try MigrationJournalStore(
            paths: fixture.paths, fileOperations: LiveFileOperations()
        ).load()
        #expect(journal?.m1?.state == .done)
        #expect(journal?.m1?.rewrittenReferenceCount == 2)
        #expect(journal?.m1?.retainedLegacyCount == 1)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.paths.stagingDirectory(profileID: id).path
        ))
    }

    @Test @MainActor
    func secondLaunchIsIdempotent() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try populateSource(fixture)

        let first = ProfileBootstrap.run(dependencies: fixture.dependencies)
        let second = ProfileBootstrap.run(dependencies: fixture.dependencies)
        #expect(first == second)
        let document = try fixture.dependencies.registry.load()
        #expect(document.profiles.count == 1)
    }

    @Test func freshInstallCreatesEmptyProfile() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let context = ProfileBootstrap.run(dependencies: fixture.dependencies)
        guard case .profile(let id) = context.mode else {
            Issue.record("expected profile boot, got \(context.mode)")
            return
        }
        #expect(try fixture.dependencies.registry.load().activeProfileID == id)
        #expect(FileManager.default.fileExists(
            atPath: fixture.paths.chatHistoryDirectory(id).path
        ))
        let journal = try MigrationJournalStore(
            paths: fixture.paths, fileOperations: LiveFileOperations()
        ).load()
        #expect(journal?.m1?.state == .done)
    }

    // MARK: - Pre-commit failure fork

    @Test @MainActor
    func preCommitFailureKeepsSourceAndBootsLegacy() throws {
        let fixture = try makeFixture(backupDriver: FailingSQLiteBackupDriver())
        defer { fixture.cleanup() }
        try populateSource(fixture)

        let context = ProfileBootstrap.run(dependencies: fixture.dependencies)
        guard case .legacyFallback = context.mode else {
            Issue.record("expected legacy fallback, got \(context.mode)")
            return
        }
        #expect(context.storeURL == nil)
        // Source untouched, registry never written.
        #expect(FileManager.default.fileExists(atPath: fixture.paths.legacyStoreURL.path))
        #expect(fixture.dependencies.registry.presence() == .absent)
    }

    @Test @MainActor
    func failedAttemptLeftoversAreCleanedOnRetry() throws {
        let failing = try makeFixture(backupDriver: FailingSQLiteBackupDriver())
        defer { failing.cleanup() }
        try populateSource(failing)
        _ = ProfileBootstrap.run(dependencies: failing.dependencies)

        // Same tree, now with a working driver: the retry restarts from
        // scratch and completes.
        let retry = M1StorageMigration.Dependencies(
            paths: failing.paths,
            registry: failing.dependencies.registry,
            fileOperations: failing.dependencies.fileOperations,
            backupDriver: LiveSQLiteBackupDriver(),
            audioRoot: { failing.audioRoot },
            audioDirectoryState: failing.dependencies.audioDirectoryState,
            scopedDefaults: failing.dependencies.scopedDefaults,
            now: failing.dependencies.now
        )
        let context = ProfileBootstrap.run(dependencies: retry)
        guard case .profile(let id) = context.mode else {
            Issue.record("expected profile boot, got \(context.mode)")
            return
        }
        #expect(try retry.registry.load().activeProfileID == id)
        // Exactly one profile directory: earlier attempts left nothing.
        let profileDirs = try FileManager.default.contentsOfDirectory(
            atPath: failing.paths.profilesDirectory.path
        )
        #expect(profileDirs == [id.uuidString])
    }

    @Test @MainActor
    func busySourceFailsClosedPreCommit() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try populateSource(fixture)
        var writer: OpaquePointer?
        #expect(sqlite3_open_v2(
            fixture.paths.legacyStoreURL.path, &writer, SQLITE_OPEN_READWRITE, nil
        ) == SQLITE_OK)
        defer { sqlite3_close(writer) }
        // The fixture container may still be inside its asynchronous
        // close-time checkpoint; wait it out before taking the lock.
        sqlite3_busy_timeout(writer, 5000)
        #expect(sqlite3_exec(writer, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)
        defer { _ = sqlite3_exec(writer, "ROLLBACK", nil, nil, nil) }

        let context = ProfileBootstrap.run(dependencies: fixture.dependencies)
        guard case .legacyFallback = context.mode else {
            Issue.record("expected legacy fallback, got \(context.mode)")
            return
        }
        #expect(fixture.dependencies.registry.presence() == .absent)
    }

    // MARK: - Post-commit boundary

    /// Crash window between the registry write / retire and the journal's
    /// `done` write: the registry is committed, the journal understates.
    /// The next boot must keep the profile authority and converge retire —
    /// never fall back to legacy, never touch the placed profile directory.
    @Test @MainActor
    func committedJournalShortOfDoneConvergesWithoutTouchingTarget() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try populateSource(fixture)
        let first = ProfileBootstrap.run(dependencies: fixture.dependencies)
        guard case .profile(let id) = first.mode else {
            Issue.record("expected profile boot, got \(first.mode)")
            return
        }

        // Restore a source duplicate and rewind the journal to targetVerified.
        // Copying avoids renaming an inode whose test-only SwiftData engine
        // may still be completing asynchronous teardown.
        let retiredName = try #require(try FileManager.default.contentsOfDirectory(
            atPath: fixture.paths.root.path
        ).first { $0.hasPrefix("Cadenza.store.migrated-") })
        try FileManager.default.copyItem(
            at: fixture.paths.root.appendingPathComponent(retiredName),
            to: fixture.paths.legacyStoreURL
        )
        let journalStore = MigrationJournalStore(
            paths: fixture.paths, fileOperations: LiveFileOperations()
        )
        var record = try #require(try journalStore.load()?.m1)
        record.state = .targetVerified
        // At this crash boundary the retire has not started: the on-disk
        // journal carries no generation yet.
        record.retireGeneration = nil
        try journalStore.save(MigrationJournalDocument(version: 1, m1: record))

        let storeContentBefore = try LiveFileOperations()
            .sha256(of: fixture.paths.storeURL(id))

        let second = ProfileBootstrap.run(dependencies: fixture.dependencies)
        #expect(second.mode == .profile(id))
        #expect(second.storeURL == fixture.paths.storeURL(id))
        // Retire converged: source renamed again, journal done, profile
        // store bytes untouched.
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.legacyStoreURL.path))
        #expect(try journalStore.load()?.m1?.state == .done)
        #expect(try LiveFileOperations().sha256(of: fixture.paths.storeURL(id))
            == storeContentBefore)
    }

    // MARK: - Audio-root authority (registry-owned)

    /// The registry's per-profile record is the root authority: a
    /// committed boot never mirrors the legacy defaults state over it —
    /// whatever the registry says (including a root the defaults never
    /// saw) survives the boot byte-for-byte.
    @Test @MainActor
    func bootNeverMirrorsLegacyDefaultsOverTheRegistryRoot() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try populateSource(fixture)
        _ = ProfileBootstrap.run(dependencies: fixture.dependencies)

        var document = try fixture.dependencies.registry.load()
        let recorded = Profile.AudioDirectory(
            bookmark: Data([0x01]), path: "/profile/own-root", kind: .appManaged
        )
        document.profiles[0].audioDirectory = recorded
        try fixture.dependencies.registry.save(document)

        _ = ProfileBootstrap.run(dependencies: fixture.dependencies)
        let after = try fixture.dependencies.registry.load()
        #expect(after.profiles[0].audioDirectory == recorded)
    }

    /// The initial migration records `userSelected` for the inherited
    /// bookmark-less default root: the app cannot prove exclusive
    /// management of a directory that predates the registry.
    @Test @MainActor
    func initialMigrationRecordsInheritedRootAsUserSelected() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try populateSource(fixture)
        _ = ProfileBootstrap.run(dependencies: fixture.dependencies)

        #expect(try fixture.dependencies.registry.load()
            .profiles[0].audioDirectory.kind == .userSelected)
    }

    // MARK: - Scoped defaults mapping

    @Test func scopedDefaultsCopyPreservesTypesAndAbsence() throws {
        let suiteName = "scoped-defaults-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let scoped = ProfileScopedDefaults(defaults: defaults, persistentDomainName: suiteName)
        let profileID = UUID()

        defaults.set(true, forKey: "markdownMirrorEnabled")
        defaults.set("Andy", forKey: "userName")
        defaults.set(Data([0x01, 0x02]), forKey: "markdownMirrorLedger.v1")
        defaults.set(["a", "b"], forKey: "craft.exportedRecordingIDs")
        defaults.set(7, forKey: "meetingPrepLeadMinutes")
        let folderKey = "folderSort.\(UUID().uuidString)"
        defaults.set("dateNewest", forKey: folderKey)
        // A registered default matching a scoped prefix must NOT be copied:
        // only explicitly-set values map.
        defaults.register(defaults: ["folderSort.registered-only": "registeredValue"])
        // "userJobTitle" stays absent on purpose.

        scoped.copyGlobalValues(to: profileID)

        func scopedKey(_ key: String) -> String {
            ProfileScopedDefaults.scopedKey(key, profileID: profileID)
        }
        // Scoped key format follows the spec: <originalKey>.profile.<id>.
        #expect(scopedKey("userName") == "userName.profile.\(profileID.uuidString)")
        #expect(defaults.object(forKey: scopedKey("markdownMirrorEnabled")) as? Bool == true)
        #expect(defaults.object(forKey: scopedKey("userName")) as? String == "Andy")
        #expect(
            defaults.object(forKey: scopedKey("markdownMirrorLedger.v1")) as? Data
                == Data([0x01, 0x02])
        )
        #expect(
            defaults.object(forKey: scopedKey("craft.exportedRecordingIDs")) as? [String]
                == ["a", "b"]
        )
        #expect(defaults.object(forKey: scopedKey("meetingPrepLeadMinutes")) as? Int == 7)
        #expect(defaults.object(forKey: scopedKey(folderKey)) as? String == "dateNewest")
        #expect(defaults.object(forKey: scopedKey("folderSort.registered-only")) == nil)
        // Absent globally → absent scoped; no defaults invented.
        #expect(defaults.object(forKey: scopedKey("userJobTitle")) == nil)
        // Globals retained for rollback.
        #expect(defaults.object(forKey: "markdownMirrorEnabled") as? Bool == true)
        #expect(defaults.object(forKey: "userName") as? String == "Andy")
        // The completion marker records that the mapping ran.
        #expect(scoped.mappingComplete(for: profileID))

        // A re-run must never touch a scoped value that is already set — by then
        // it is the user's per-profile setting, not a mirror of the global. The
        // copy re-runs whenever the marker is absent (crash window, or any bump
        // of `mappingMarkerKey`), so a destructive branch here would silently
        // delete settings on upgrade.
        defaults.removeObject(forKey: "userName")
        defaults.set("Renamed by the user", forKey: scopedKey("markdownMirrorEnabled"))
        scoped.copyGlobalValues(to: profileID)
        #expect(defaults.object(forKey: scopedKey("userName")) as? String == "Andy")
        #expect(
            defaults.object(forKey: scopedKey("markdownMirrorEnabled")) as? String
                == "Renamed by the user"
        )
        // Still absent globally and scoped: seeding never invents a value.
        #expect(defaults.object(forKey: scopedKey("userJobTitle")) == nil)
    }

    /// The inventory is the authoritative list, verbatim: any drive-by
    /// addition or removal must fail this literal comparison and be argued
    /// against the spec's inventory table.
    @Test func scopedDefaultsInventoryIsExactlyTheAuthoritativeList() {
        #expect(ProfileScopedDefaults.scopedKeys == [
            "markdownMirrorEnabled",
            "markdownMirrorIncludeTranscript",
            "markdownMirrorDirectoryBookmark",
            "markdownMirrorDirectoryPath",
            "markdownMirrorLedger.v1",
            "autoExportToNotion",
            "notion.databaseID",
            "notion.connected",
            "notion.workspaceName",
            "autoExportToCraft",
            "craft.spaceID",
            "craft.folderID",
            "craft.exportedRecordingIDs",
            "userName",
            "userJobTitle",
            "smartFolders.overrides.v2",
            "smartFolders.pinned.v1",
            "smartFolders.excluded.v1",
            "enableAutomaticRecaps",
            "meetingPrepEnabled",
            "meetingPrepLeadMinutes",
        ])
        #expect(ProfileScopedDefaults.scopedKeyPrefixes == ["folderSort."])
    }

    /// Crash-window convergence: the mapping is idempotent and re-applied
    /// by the bootstrap whenever the completion marker is missing.
    @Test @MainActor
    func bootstrapReappliesDefaultsMappingWhenMarkerMissing() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try populateSource(fixture)
        fixture.defaults.set("Andy", forKey: "userName")
        let first = ProfileBootstrap.run(dependencies: fixture.dependencies)
        guard case .profile(let id) = first.mode else {
            Issue.record("expected profile boot, got \(first.mode)")
            return
        }
        let scopedName = ProfileScopedDefaults.scopedKey("userName", profileID: id)
        let marker = ProfileScopedDefaults.scopedKey(
            ProfileScopedDefaults.mappingMarkerKey, profileID: id
        )
        #expect(fixture.defaults.object(forKey: scopedName) as? String == "Andy")

        // Wipe the mapping and its marker — the shape of a crash between
        // the copy and its durability — and boot again.
        fixture.defaults.removeObject(forKey: scopedName)
        fixture.defaults.removeObject(forKey: marker)
        _ = ProfileBootstrap.run(dependencies: fixture.dependencies)
        #expect(fixture.defaults.object(forKey: scopedName) as? String == "Andy")
        #expect(fixture.defaults.object(forKey: marker) as? Bool == true)
    }
}
