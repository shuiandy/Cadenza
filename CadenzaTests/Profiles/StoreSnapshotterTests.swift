import Dispatch
import Foundation
import SQLite3
import SwiftData
import os
import Testing

@testable import Cadenza

/// Snapshot consistency (backup API under live connections and pending WAL
/// content), receipt semantics, corrupted-source failure, injected backup
/// and hash failures, seam auditing, symlink fail-closed behavior,
/// freeze-lease exclusion, source evidence stability, and journal IO with
/// the path-trust rule.
@Suite("Store Snapshotter and Freeze Lease", .serialized)
struct StoreSnapshotterTests {

    private let live = LiveFileOperations()
    private let liveDriver = LiveSQLiteBackupDriver()

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapshotter-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A real on-disk store with a few entities, left OPEN when the caller
    /// retains `container`, so pending WAL content exists at snapshot time.
    @MainActor
    private func makeSourceStore(
        in directory: URL, recordings: Int
    ) throws -> (container: ModelContainer, trio: StoreTrioURL) {
        let storeURL = directory.appendingPathComponent("Cadenza.store")
        let container = try ModelContainer(
            for: RecordingsStore.schema,
            configurations: ModelConfiguration(url: storeURL)
        )
        let context = ModelContext(container)
        for index in 0..<recordings {
            let recording = Recording(
                id: UUID(), title: "R\(index)", startDate: Date(timeIntervalSince1970: Double(index))
            )
            recording.audioFilePath = "/legacy/audio-\(index).m4a"
            context.insert(recording)
        }
        try context.save()
        return (container, StoreTrioURL(base: storeURL))
    }

    @Test @MainActor
    func snapshotCountsIncludePendingWALContentWhileSourceStaysOpen() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try makeSourceStore(in: dir, recordings: 3)
        // The container stays open — WAL not checkpointed. The backup API
        // must still see all three rows.
        let receipt = try StoreSnapshotter.performVerifiedSnapshot(
            source: source.trio,
            into: dir.appendingPathComponent("snapshots", isDirectory: true),
            label: "wal-test",
            fileOperations: live,
            backupDriver: liveDriver
        )
        #expect(receipt.entityCounts["Recording"] == 3)
        #expect(receipt.entityCounts["Folder"] == 0)
        #expect(!receipt.files.isEmpty)
        // Receipt hashes describe the artifact as it exists post-open.
        for record in receipt.files {
            let url = receipt.directory.appendingPathComponent(record.name)
            #expect(try live.sha256(of: url) == record.sha256)
        }
        _ = source.container
    }

    @Test func corruptedSourceFailsClosed() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeURL = dir.appendingPathComponent("Cadenza.store")
        try Data("this is not a sqlite database at all".utf8).write(to: storeURL)

        #expect(throws: (any Error).self) {
            try StoreSnapshotter.performVerifiedSnapshot(
                source: StoreTrioURL(base: storeURL),
                into: dir.appendingPathComponent("snapshots", isDirectory: true),
                label: "corrupt",
                fileOperations: live,
                backupDriver: liveDriver
            )
        }
    }

    @Test func missingSourceFailsClosed() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: (any Error).self) {
            try StoreSnapshotter.performVerifiedSnapshot(
                source: StoreTrioURL(base: dir.appendingPathComponent("missing.store")),
                into: dir, label: "missing",
                fileOperations: live,
                backupDriver: liveDriver
            )
        }
    }

    // MARK: - Injected failures and seam audit

    @Test @MainActor
    func injectedBackupFailureAbortsSnapshot() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try makeSourceStore(in: dir, recordings: 1)
        #expect(throws: SQLiteBackupError.backupFailed("injected failure")) {
            try StoreSnapshotter.performVerifiedSnapshot(
                source: source.trio,
                into: dir.appendingPathComponent("snapshots", isDirectory: true),
                label: "backup-fail",
                fileOperations: live,
                backupDriver: FailingSQLiteBackupDriver()
            )
        }
        _ = source.container
    }

    @Test @MainActor
    func injectedHashFailureAbortsSnapshot() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try makeSourceStore(in: dir, recordings: 1)
        let operations = InstrumentedFileOperations(failHashNames: ["Cadenza.store"])
        #expect(throws: FileOperationError.hashFailed("Cadenza.store")) {
            try StoreSnapshotter.performVerifiedSnapshot(
                source: source.trio,
                into: dir.appendingPathComponent("snapshots", isDirectory: true),
                label: "hash-fail",
                fileOperations: operations,
                backupDriver: liveDriver
            )
        }
        _ = source.container
    }

    /// A receipt is only evidence when every field is real: a metadata read
    /// that cannot produce the size aborts instead of guessing zero.
    @Test @MainActor
    func missingSizeMetadataAbortsReceipt() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try makeSourceStore(in: dir, recordings: 1)
        let operations = InstrumentedFileOperations(stripSizeNames: ["Cadenza.store"])
        #expect(throws: (any Error).self) {
            try StoreSnapshotter.performVerifiedSnapshot(
                source: source.trio,
                into: dir.appendingPathComponent("snapshots", isDirectory: true),
                label: "no-size",
                fileOperations: operations,
                backupDriver: liveDriver
            )
        }
        _ = source.container
    }

    /// Audits the seam traffic of one snapshot: every path the seam saw is
    /// inside the test root, the artifact hash and the store-open notice
    /// went through the seam, and the backup driver was called exactly once
    /// with the expected endpoints. (The audit covers seam-routed IO; SQLite
    /// and SwiftData perform their own file access behind the driver and
    /// the store-open notice.)
    @Test @MainActor
    func snapshotSeamTrafficStaysInsideRootAndCoversArtifact() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try makeSourceStore(in: dir, recordings: 2)
        let operations = InstrumentedFileOperations()
        let driver = AuditingSQLiteBackupDriver()
        let receipt = try StoreSnapshotter.performVerifiedSnapshot(
            source: source.trio,
            into: dir.appendingPathComponent("snapshots", isDirectory: true),
            label: "audit",
            fileOperations: operations,
            backupDriver: driver
        )
        let recorded = operations.recorded
        #expect(!recorded.touchedPaths.isEmpty)
        for path in recorded.touchedPaths {
            #expect(path.hasPrefix(dir.path))
        }
        let artifact = receipt.directory.appendingPathComponent("Cadenza.store")
        #expect(recorded.hashedPaths.contains(artifact.path))
        #expect(recorded.storeOpenPaths == [artifact.path])
        #expect(driver.calls == [
            .init(source: source.trio.base.path, destination: artifact.path)
        ])
        _ = source.container
    }

    // MARK: - Symlink fail-closed

    @Test @MainActor
    func symlinkedSourceStoreIsRejectedBySnapshotAndLease() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try makeSourceStore(in: dir, recordings: 1)
        let link = dir.appendingPathComponent("Link.store")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: source.trio.base
        )

        #expect(throws: FileOperationError.symlinkRejected("Link.store")) {
            try StoreSnapshotter.performVerifiedSnapshot(
                source: StoreTrioURL(base: link),
                into: dir.appendingPathComponent("snapshots", isDirectory: true),
                label: "symlink",
                fileOperations: live,
                backupDriver: liveDriver
            )
        }
        #expect(throws: SourceFreezeError.self) {
            try SourceFreezeLease.acquire(storeURL: link, fileOperations: live)
        }
        _ = source.container
    }

    // MARK: - Freeze lease

    @Test @MainActor
    func freezeLeaseBlocksLaterWritersAndAllowsBackup() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try makeSourceStore(in: dir, recordings: 1)
        let lease = try SourceFreezeLease.acquire(
            storeURL: source.trio.base, fileOperations: live
        )
        defer { lease.release() }

        // A writer arriving during the freeze gets BUSY.
        var writer: OpaquePointer?
        #expect(sqlite3_open_v2(
            source.trio.base.path, &writer, SQLITE_OPEN_READWRITE, nil
        ) == SQLITE_OK)
        defer { sqlite3_close(writer) }
        sqlite3_busy_timeout(writer, 0)
        let begin = sqlite3_exec(writer, "BEGIN IMMEDIATE", nil, nil, nil)
        #expect(begin == SQLITE_BUSY || begin == SQLITE_LOCKED)

        // The read-only backup still succeeds under the lease.
        let receipt = try StoreSnapshotter.performVerifiedSnapshot(
            source: source.trio,
            into: dir.appendingPathComponent("snapshots", isDirectory: true),
            label: "under-lease",
            fileOperations: live,
            backupDriver: liveDriver
        )
        #expect(receipt.entityCounts["Recording"] == 1)
        _ = source.container
    }

    @Test @MainActor
    func activeWriterFailsLeaseAcquisitionClosed() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try makeSourceStore(in: dir, recordings: 1)

        var writer: OpaquePointer?
        #expect(sqlite3_open_v2(
            source.trio.base.path, &writer, SQLITE_OPEN_READWRITE, nil
        ) == SQLITE_OK)
        defer { sqlite3_close(writer) }
        #expect(sqlite3_exec(writer, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)
        defer { _ = sqlite3_exec(writer, "ROLLBACK", nil, nil, nil) }

        #expect(throws: SourceFreezeError.sourceBusy(source.trio.base.lastPathComponent)) {
            try SourceFreezeLease.acquire(storeURL: source.trio.base, fileOperations: live)
        }
        _ = source.container
    }

    @Test @MainActor
    func releasedLeaseAdmitsWritersAgain() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try makeSourceStore(in: dir, recordings: 1)
        let lease = try SourceFreezeLease.acquire(
            storeURL: source.trio.base, fileOperations: live
        )
        lease.release()

        let second = try SourceFreezeLease.acquire(
            storeURL: source.trio.base, fileOperations: live
        )
        second.release()
        _ = source.container
    }

    // MARK: - Source evidence

    @Test @MainActor
    func sourceEvidenceDetectsOutOfBandChanges() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try makeSourceStore(in: dir, recordings: 2)
        let evidence = try SourceEvidence.capture(source: source.trio, fileOperations: live)
        #expect(evidence.stillHolds(for: source.trio, fileOperations: live))

        // Direct file tampering (outside SQLite) breaks the evidence.
        let handle = try FileHandle(forWritingTo: source.trio.base)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x00]))
        try handle.close()
        #expect(!evidence.stillHolds(for: source.trio, fileOperations: live))
        _ = source.container
    }

    // MARK: - Journal

    @Test func journalRoundTripsAndValidatesPaths() throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let paths = ProfilePaths(root: base.appendingPathComponent("Cadenza", isDirectory: true))
        let store = MigrationJournalStore(paths: paths, fileOperations: live)
        #expect(try store.load() == nil)

        let record = MigrationJournalDocument.M1Record(
            state: .started,
            profileID: UUID(),
            sourceStorePath: "/tmp/source",
            receipt: nil,
            sourceEvidence: SourceEvidence(nodes: []),
            rewrittenReferenceCount: nil,
            retainedLegacyCount: nil,
            sourceContentDigest: String(repeating: "ab", count: 32),
            targetContentDigest: nil,
            retireGeneration: nil
        )
        let document = MigrationJournalDocument(version: 1, m1: record)
        try store.save(document)
        #expect(try store.load() == document)

        // In-tree locations validate; escapes and symlinked components do
        // not.
        let inside = paths.migrationDirectory.appendingPathComponent("staging/x")
        #expect(try store.validatedMigrationLocation(inside) == inside)
        #expect(throws: MigrationJournalError.self) {
            try store.validatedMigrationLocation(URL(fileURLWithPath: "/tmp/elsewhere"))
        }
        try FileManager.default.createDirectory(
            at: paths.migrationDirectory, withIntermediateDirectories: true
        )
        let outside = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: outside) }
        let link = paths.migrationDirectory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        #expect(throws: MigrationJournalError.self) {
            try store.validatedMigrationLocation(link.appendingPathComponent("staging"))
        }
    }

    /// State-dependent semantics gate both load and save: records missing
    /// the evidence their state implies are corruption.
    @Test func journalSemanticValidationRejectsMalformedRecords() throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let paths = ProfilePaths(root: base.appendingPathComponent("Cadenza", isDirectory: true))
        let store = MigrationJournalStore(paths: paths, fileOperations: live)
        let digest = String(repeating: "ab", count: 32)

        func record(
            state: MigrationJournalDocument.M1State,
            receipt: SnapshotReceipt? = nil,
            rewritten: Int? = nil,
            retained: Int? = nil,
            sourceDigest: String? = nil,
            targetDigest: String? = nil,
            generation: Int? = nil,
            sourcePath: String = "/tmp/source"
        ) -> MigrationJournalDocument.M1Record {
            .init(
                state: state, profileID: UUID(), sourceStorePath: sourcePath,
                receipt: receipt, sourceEvidence: SourceEvidence(nodes: []),
                rewrittenReferenceCount: rewritten, retainedLegacyCount: retained,
                sourceContentDigest: sourceDigest, targetContentDigest: targetDigest,
                retireGeneration: generation
            )
        }
        let receipt = SnapshotReceipt(directory: base, files: [], entityCounts: [:])

        // Valid shapes save.
        try store.save(.init(version: 1, m1: record(state: .started, sourceDigest: digest)))
        try store.save(.init(version: 1, m1: record(
            state: .staged, receipt: receipt, rewritten: 1, retained: 0,
            sourceDigest: digest, targetDigest: digest
        )))

        // Missing per-state evidence rejects.
        #expect(throws: MigrationJournalError.self) {
            try store.save(.init(version: 1, m1: record(state: .started)))
        }
        #expect(throws: MigrationJournalError.self) {
            try store.save(.init(version: 1, m1: record(
                state: .snapshotVerified, sourceDigest: digest
            )))
        }
        #expect(throws: MigrationJournalError.self) {
            try store.save(.init(version: 1, m1: record(
                state: .staged, receipt: receipt, rewritten: -1, retained: 0,
                sourceDigest: digest, targetDigest: digest
            )))
        }
        #expect(throws: MigrationJournalError.self) {
            try store.save(.init(version: 1, m1: record(
                state: .staged, receipt: receipt, rewritten: 1, retained: 0,
                sourceDigest: digest, targetDigest: "not-hex"
            )))
        }
        #expect(throws: MigrationJournalError.self) {
            try store.save(.init(version: 1, m1: record(
                state: .registryCommitted, receipt: receipt, rewritten: 0, retained: 0,
                sourceDigest: digest, targetDigest: digest, generation: -5
            )))
        }
        // The same gate applies on load: a hand-written malformed record
        // never comes back as data.
        let staged = MigrationJournalDocument(version: 1, m1: record(
            state: .staged, receipt: receipt, rewritten: 1, retained: 0,
            sourceDigest: digest, targetDigest: digest
        ))
        var object = try JSONSerialization.jsonObject(
            with: ProfileRegistryCoding.makeEncoder().encode(staged)
        ) as! [String: Any]
        var m1 = object["m1"] as! [String: Any]
        m1.removeValue(forKey: "receipt")
        object["m1"] = m1
        try FileManager.default.createDirectory(
            at: paths.migrationDirectory, withIntermediateDirectories: true
        )
        try JSONSerialization.data(withJSONObject: object).write(to: paths.journalURL)
        #expect(throws: MigrationJournalError.self) { try store.load() }
    }

    /// The journal file itself is never followed through a link: a symlink
    /// at journal.json fails closed instead of loading (or silently
    /// counting as absent).
    @Test func symlinkedJournalFileFailsClosed() throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let paths = ProfilePaths(root: base.appendingPathComponent("Cadenza", isDirectory: true))
        try FileManager.default.createDirectory(
            at: paths.migrationDirectory, withIntermediateDirectories: true
        )
        let elsewhere = base.appendingPathComponent("elsewhere.json")
        try Data("{\"version\":1}".utf8).write(to: elsewhere)
        try FileManager.default.createSymbolicLink(
            at: paths.journalURL, withDestinationURL: elsewhere
        )
        let store = MigrationJournalStore(paths: paths, fileOperations: live)
        #expect(throws: MigrationJournalError.untrustedPath(paths.journalURL.path)) {
            try store.load()
        }
    }
}

@Suite("Automatic Database Backup", .serialized)
struct DatabaseBackupTests {
    private final class ScriptedSQLiteBackupStepper: SQLiteBackupStepper {
        private struct State: Sendable {
            var scriptedResults: [Int32]
            var stepCount = 0
            var sleepDurations: [Int32] = []
        }

        private let state: OSAllocatedUnfairLock<State>

        init(scriptedResults: [Int32]) {
            state = OSAllocatedUnfairLock(
                initialState: State(scriptedResults: scriptedResults)
            )
        }

        var stepCount: Int { state.withLock { $0.stepCount } }
        var sleepDurations: [Int32] { state.withLock { $0.sleepDurations } }

        func step(_ backup: OpaquePointer, pages: Int32) -> Int32 {
            let scripted = state.withLock { current -> Int32? in
                current.stepCount += 1
                guard !current.scriptedResults.isEmpty else { return nil }
                return current.scriptedResults.removeFirst()
            }
            return scripted ?? sqlite3_backup_step(backup, pages)
        }

        func sleep(milliseconds: Int32) {
            state.withLock { $0.sleepDurations.append(milliseconds) }
        }
    }

    private struct SelectiveFailingArtifactRemover: DatabaseBackupArtifactRemover {
        let failingNames: Set<String>
        private let live = LiveDatabaseBackupArtifactRemover()

        func remove(at url: URL) -> DatabaseBackupArtifactRemovalResult {
            guard !failingNames.contains(url.lastPathComponent) else {
                return .failed(errno: EACCES)
            }
            return live.remove(at: url)
        }

        func remove(
            name: String,
            from directoryFD: Int32
        ) -> DatabaseBackupArtifactRemovalResult {
            guard !failingNames.contains(name) else {
                return .failed(errno: EACCES)
            }
            return live.remove(name: name, from: directoryFD)
        }
    }

    private struct CommitFromSecondConnectionDriver: SQLiteBackupDriver {
        func consistentBackup(source: URL, destination: URL) throws {
            var writer: OpaquePointer?
            guard sqlite3_open_v2(
                sqliteNoFollowPath(for: source),
                &writer,
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOFOLLOW,
                nil
            ) == SQLITE_OK, let writer else {
                let message = writer.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
                sqlite3_close(writer)
                throw SQLiteBackupError.openFailed("concurrent writer: \(message)")
            }
            defer { sqlite3_close(writer) }
            guard sqlite3_exec(
                writer,
                "INSERT INTO backup_probe(value) VALUES ('concurrent commit')",
                nil,
                nil,
                nil
            ) == SQLITE_OK else {
                throw SQLiteBackupError.backupFailed(
                    "concurrent commit: \(String(cString: sqlite3_errmsg(writer)))"
                )
            }
            try LiveSQLiteBackupDriver().consistentBackup(
                source: source,
                destination: destination
            )
        }
    }

    private func makeTempProfile() throws -> (
        root: URL,
        paths: ProfilePaths,
        profileID: UUID,
        backups: URL
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("database-backup-tests-\(UUID().uuidString)", isDirectory: true)
        let paths = ProfilePaths(
            root: root.appendingPathComponent("Cadenza", isDirectory: true)
        )
        let profileID = UUID()
        let backups = paths.backupsDirectory(profileID)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        return (root, paths, profileID, backups)
    }

    private func openWALSource(in root: URL) throws -> (url: URL, database: OpaquePointer) {
        let url = root.appendingPathComponent("live.store")
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(database)
            throw SQLiteBackupError.openFailed(message)
        }
        do {
            try execute("PRAGMA journal_mode=WAL", on: database)
            try execute("PRAGMA wal_autocheckpoint=0", on: database)
            try execute(
                "CREATE TABLE backup_probe (id INTEGER PRIMARY KEY, value TEXT NOT NULL)",
                on: database
            )
            try execute(
                "INSERT INTO backup_probe(value) VALUES ('before backup')",
                on: database
            )
            return (url, database)
        } catch {
            sqlite3_close(database)
            throw error
        }
    }

    private func execute(_ sql: String, on database: OpaquePointer) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteBackupError.backupFailed(String(cString: sqlite3_errmsg(database)))
        }
    }

    private func scalarInt(_ sql: String, databaseURL: URL) throws -> Int {
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            sqliteNoFollowPath(for: databaseURL),
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_NOFOLLOW,
            nil
        ) == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(database)
            throw SQLiteBackupError.openFailed(message)
        }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            sqlite3_finalize(statement)
            throw SQLiteBackupError.backupFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw SQLiteBackupError.backupFailed(String(cString: sqlite3_errmsg(database)))
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func scalarText(_ sql: String, databaseURL: URL) throws -> String {
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            sqliteNoFollowPath(for: databaseURL),
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_NOFOLLOW,
            nil
        ) == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(database)
            throw SQLiteBackupError.openFailed(message)
        }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            sqlite3_finalize(statement)
            throw SQLiteBackupError.backupFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let text = sqlite3_column_text(statement, 0) else {
            throw SQLiteBackupError.backupFailed(String(cString: sqlite3_errmsg(database)))
        }
        return String(cString: text)
    }

    private func createdURL(from outcome: DatabaseBackupOutcome) throws -> URL {
        switch outcome {
        case .created(let url), .createdWithMaintenanceError(let url, _):
            return url
        case .failed(let error):
            throw error
        case .skippedNoSource:
            throw SQLiteBackupError.openFailed("backup unexpectedly skipped")
        }
    }

    @Test
    func onlineBackupCapturesWALAndConcurrentCommittedRowAsPrivateSingleFile() throws {
        let profile = try makeTempProfile()
        defer { try? FileManager.default.removeItem(at: profile.root) }
        let source = try openWALSource(in: profile.root)
        defer { sqlite3_close(source.database) }

        let walURL = URL(fileURLWithPath: source.url.path + "-wal")
        #expect(FileManager.default.fileExists(atPath: walURL.path))
        let walSize = try FileManager.default.attributesOfItem(atPath: walURL.path)[.size] as? Int
        #expect((walSize ?? 0) > 0)

        let outcome = DatabaseBackup.performBackup(
            storeURL: source.url,
            backupsDirectory: profile.backups,
            backupDriver: CommitFromSecondConnectionDriver(),
            now: Date(timeIntervalSince1970: 1_786_000_000),
            backupID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        )
        let backupURL = try createdURL(from: outcome)

        #expect(try scalarText("PRAGMA integrity_check", databaseURL: backupURL) == "ok")
        #expect(try scalarInt("SELECT COUNT(*) FROM backup_probe", databaseURL: backupURL) == 2)
        #expect(!FileManager.default.fileExists(atPath: backupURL.path + "-wal"))
        #expect(!FileManager.default.fileExists(atPath: backupURL.path + "-shm"))
        let permissions = try FileManager.default.attributesOfItem(atPath: backupURL.path)[
            .posixPermissions
        ] as? Int
        #expect(permissions == 0o600)
    }

    @Test
    func onlineBackupRetriesBusyAndLockedWithABoundedInjectedStepper() throws {
        let profile = try makeTempProfile()
        defer { try? FileManager.default.removeItem(at: profile.root) }
        let source = try openWALSource(in: profile.root)
        defer { sqlite3_close(source.database) }
        let destination = profile.root.appendingPathComponent("retry.store")
        let stepper = ScriptedSQLiteBackupStepper(
            scriptedResults: [SQLITE_BUSY, SQLITE_LOCKED]
        )

        try LiveSQLiteBackupDriver(stepper: stepper).consistentBackup(
            source: source.url,
            destination: destination
        )

        #expect(stepper.stepCount == 3)
        #expect(stepper.sleepDurations == [
            LiveSQLiteBackupDriver.busyRetryDelayMilliseconds,
            LiveSQLiteBackupDriver.busyRetryDelayMilliseconds
        ])
        #expect(try scalarInt("SELECT COUNT(*) FROM backup_probe", databaseURL: destination) == 1)
    }

    @Test
    func onlineBackupStopsAfterMaximumBusyRetries() throws {
        let profile = try makeTempProfile()
        defer { try? FileManager.default.removeItem(at: profile.root) }
        let source = try openWALSource(in: profile.root)
        defer { sqlite3_close(source.database) }
        let stepper = ScriptedSQLiteBackupStepper(
            scriptedResults: Array(
                repeating: SQLITE_BUSY,
                count: LiveSQLiteBackupDriver.maximumBusyRetryCount + 1
            )
        )

        #expect(throws: SQLiteBackupError.self) {
            try LiveSQLiteBackupDriver(stepper: stepper).consistentBackup(
                source: source.url,
                destination: profile.root.appendingPathComponent("busy.store")
            )
        }
        #expect(stepper.stepCount == LiveSQLiteBackupDriver.maximumBusyRetryCount + 1)
        #expect(stepper.sleepDurations.count == LiveSQLiteBackupDriver.maximumBusyRetryCount)
    }

    @Test
    func nextBackupImmediatelyReclaimsControlledCrashStaging() throws {
        let profile = try makeTempProfile()
        defer { try? FileManager.default.removeItem(at: profile.root) }
        let source = try openWALSource(in: profile.root)
        defer { sqlite3_close(source.database) }
        let staging = profile.backups.appendingPathComponent(
            ".cadenza-backup-staging-00000000-0000-0000-0000-000000000090.store"
        )
        try Data("recent crash residue".utf8).write(to: staging)
        try Data("recent sidecar".utf8).write(
            to: URL(fileURLWithPath: staging.path + "-wal")
        )
        let unmanaged = profile.backups.appendingPathComponent(
            ".cadenza-backup-staging-not-a-uuid.store"
        )
        try Data("keep".utf8).write(to: unmanaged)

        _ = try createdURL(from: DatabaseBackup.performBackup(
            storeURL: source.url,
            backupsDirectory: profile.backups,
            now: Date().addingTimeInterval(1),
            backupID: UUID(uuidString: "00000000-0000-0000-0000-000000000091")!
        ))

        #expect(!FileManager.default.fileExists(atPath: staging.path))
        #expect(!FileManager.default.fileExists(atPath: staging.path + "-wal"))
        #expect(try Data(contentsOf: unmanaged) == Data("keep".utf8))
    }

    @Test
    func crashStagingBaseRemovalFailureIsReportedOnceAndPreservesSidecar() throws {
        let profile = try makeTempProfile()
        defer { try? FileManager.default.removeItem(at: profile.root) }
        let source = try openWALSource(in: profile.root)
        defer { sqlite3_close(source.database) }
        let staging = profile.backups.appendingPathComponent(
            ".cadenza-backup-staging-00000000-0000-0000-0000-000000000096.store"
        )
        let stagingWAL = URL(fileURLWithPath: staging.path + "-wal")
        try Data("crash residue".utf8).write(to: staging)
        try Data("required WAL".utf8).write(to: stagingWAL)

        let outcome = DatabaseBackup.performBackup(
            storeURL: source.url,
            backupsDirectory: profile.backups,
            artifactRemover: SelectiveFailingArtifactRemover(
                failingNames: [staging.lastPathComponent]
            ),
            backupID: UUID(uuidString: "00000000-0000-0000-0000-000000000097")!
        )
        guard case .createdWithMaintenanceError(
            _,
            .postPublishMaintenanceFailed(let failures)
        ) = outcome else {
            Issue.record("Expected one staging maintenance failure, got \(outcome)")
            return
        }

        #expect(failures == ["\(staging.lastPathComponent): errno \(EACCES)"])
        #expect(try Data(contentsOf: staging) == Data("crash residue".utf8))
        #expect(try Data(contentsOf: stagingWAL) == Data("required WAL".utf8))
    }

    @Test
    func sameInstantBackupsHaveUniqueNamesAndRotationRemovesSidecarsAndOrphans() throws {
        let profile = try makeTempProfile()
        defer { try? FileManager.default.removeItem(at: profile.root) }
        let source = try openWALSource(in: profile.root)
        defer { sqlite3_close(source.database) }
        let instant = Date(timeIntervalSince1970: 1_786_000_000)

        var firstThree: [URL] = []
        for value in 1...3 {
            let id = UUID(uuidString: String(
                format: "00000000-0000-0000-0000-%012d",
                value
            ))!
            firstThree.append(try createdURL(from: DatabaseBackup.performBackup(
                storeURL: source.url,
                backupsDirectory: profile.backups,
                now: instant,
                backupID: id
            )))
        }
        #expect(Set(firstThree.map(\.lastPathComponent)).count == 3)

        for backup in firstThree {
            try Data("legacy sidecar".utf8).write(
                to: URL(fileURLWithPath: backup.path + "-wal")
            )
        }
        let orphan = profile.backups.appendingPathComponent("cadenza-orphan.store-shm")
        try Data("orphan".utf8).write(to: orphan)

        let fourth = try createdURL(from: DatabaseBackup.performBackup(
            storeURL: source.url,
            backupsDirectory: profile.backups,
            now: instant,
            backupID: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        ))
        let contents = try FileManager.default.contentsOfDirectory(
            at: profile.backups,
            includingPropertiesForKeys: nil
        )
        let bases = contents.filter {
            $0.lastPathComponent.hasPrefix("cadenza-") && $0.pathExtension == "store"
        }
        #expect(bases.count == DatabaseBackup.maxBackups)
        #expect(FileManager.default.fileExists(atPath: fourth.path))
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        let walSidecars = contents.filter { $0.lastPathComponent.hasSuffix(".store-wal") }
        #expect(walSidecars.count == 2)
        for sidecar in walSidecars {
            let basePath = String(sidecar.path.dropLast("-wal".count))
            #expect(FileManager.default.fileExists(atPath: basePath))
        }
    }

    @Test
    func rotationBaseUnlinkFailurePreservesItsSidecars() throws {
        let profile = try makeTempProfile()
        defer { try? FileManager.default.removeItem(at: profile.root) }
        let source = try openWALSource(in: profile.root)
        defer { sqlite3_close(source.database) }

        let names = [
            "cadenza-oldest.store",
            "cadenza-middle.store",
            "cadenza-newest.store"
        ]
        for (index, name) in names.enumerated() {
            let url = profile.backups.appendingPathComponent(name)
            try Data("backup \(index)".utf8).write(to: url)
            let date = Date(timeIntervalSince1970: Double(index + 1))
            try FileManager.default.setAttributes(
                [.creationDate: date, .modificationDate: date],
                ofItemAtPath: url.path
            )
        }
        let oldest = profile.backups.appendingPathComponent(names[0])
        let oldestWAL = URL(fileURLWithPath: oldest.path + "-wal")
        try Data("required WAL".utf8).write(to: oldestWAL)

        let outcome = DatabaseBackup.performBackup(
            storeURL: source.url,
            backupsDirectory: profile.backups,
            artifactRemover: SelectiveFailingArtifactRemover(
                failingNames: [oldest.lastPathComponent]
            ),
            backupID: UUID(uuidString: "00000000-0000-0000-0000-000000000092")!
        )
        guard case .createdWithMaintenanceError(
            let created,
            .postPublishMaintenanceFailed(let failures)
        ) = outcome else {
            Issue.record("Expected a created backup with rotation failure, got \(outcome)")
            return
        }

        #expect(FileManager.default.fileExists(atPath: created.path))
        #expect(FileManager.default.fileExists(atPath: oldest.path))
        #expect(try Data(contentsOf: oldestWAL) == Data("required WAL".utf8))
        #expect(failures.contains { $0.contains(oldest.lastPathComponent) })
    }

    @Test
    func snapshotFailureDoesNotRotateOrChangeExistingGoodBackups() throws {
        let profile = try makeTempProfile()
        defer { try? FileManager.default.removeItem(at: profile.root) }
        let source = try openWALSource(in: profile.root)
        defer { sqlite3_close(source.database) }

        let good = try createdURL(from: DatabaseBackup.performBackup(
            storeURL: source.url,
            backupsDirectory: profile.backups,
            backupID: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
        ))
        for value in 1...3 {
            let extra = profile.backups.appendingPathComponent("cadenza-manual-\(value).store")
            try FileManager.default.copyItem(at: good, to: extra)
        }
        let before = try Dictionary(uniqueKeysWithValues: FileManager.default
            .contentsOfDirectory(at: profile.backups, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "store" }
            .map { ($0.lastPathComponent, try Data(contentsOf: $0)) })

        let outcome = DatabaseBackup.performBackup(
            storeURL: source.url,
            backupsDirectory: profile.backups,
            backupDriver: FailingSQLiteBackupDriver(),
            backupID: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
        )
        guard case .failed(.snapshotFailed(_, let cleanupFailure)) = outcome else {
            Issue.record("Expected a structured snapshot failure, got \(outcome)")
            return
        }
        #expect(cleanupFailure == nil)

        let after = try Dictionary(uniqueKeysWithValues: FileManager.default
            .contentsOfDirectory(at: profile.backups, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "store" }
            .map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
        #expect(after == before)
        let stagingResidue = try FileManager.default.contentsOfDirectory(
            at: profile.backups,
            includingPropertiesForKeys: nil
        ).map(\.lastPathComponent).filter {
            $0.hasPrefix(".cadenza-backup-staging-")
        }
        #expect(stagingResidue.isEmpty, "Unexpected staging residue: \(stagingResidue)")
    }

    @Test
    func performAndClearAllShareOneProcessWideExecutionLease() throws {
        let profile = try makeTempProfile()
        defer { try? FileManager.default.removeItem(at: profile.root) }
        let source = try openWALSource(in: profile.root)
        defer { sqlite3_close(source.database) }
        let sourceURL = source.url
        let backups = profile.backups
        let paths = profile.paths
        let profileID = profile.profileID
        let performAcquired = DispatchSemaphore(value: 0)
        let releasePerform = DispatchSemaphore(value: 0)
        let clearAttempted = DispatchSemaphore(value: 0)
        let clearAcquired = DispatchSemaphore(value: 0)
        let performFinished = DispatchSemaphore(value: 0)
        let clearFinished = DispatchSemaphore(value: 0)
        let performResult = OSAllocatedUnfairLock<DatabaseBackupOutcome?>(initialState: nil)
        let clearResult = OSAllocatedUnfairLock<(
            outcome: DatabaseBackupClearOutcome?,
            failure: String?
        )>(initialState: (nil, nil))

        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = DatabaseBackup.performBackup(
                storeURL: sourceURL,
                backupsDirectory: backups,
                backupID: UUID(uuidString: "00000000-0000-0000-0000-000000000095")!,
                didAcquireExecutionLease: {
                    performAcquired.signal()
                    releasePerform.wait()
                }
            )
            performResult.withLock { $0 = outcome }
            performFinished.signal()
        }
        let performEntered = performAcquired.wait(timeout: .now() + .seconds(2))
        #expect(performEntered == .success)
        guard performEntered == .success else {
            releasePerform.signal()
            _ = performFinished.wait(timeout: .now() + .seconds(2))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            clearAttempted.signal()
            do {
                let outcome = try DatabaseBackup.clearAllAutomaticBackups(
                    for: profileID,
                    paths: paths,
                    didAcquireExecutionLease: { clearAcquired.signal() }
                )
                clearResult.withLock { $0.outcome = outcome }
            } catch {
                clearResult.withLock { $0.failure = String(describing: error) }
            }
            clearFinished.signal()
        }
        let clearStarted = clearAttempted.wait(timeout: .now() + .seconds(2))
        #expect(clearStarted == .success)
        let clearWasBlocked = clearAcquired.wait(timeout: .now() + .milliseconds(100))
        #expect(clearWasBlocked == .timedOut)

        releasePerform.signal()
        #expect(performFinished.wait(timeout: .now() + .seconds(5)) == .success)
        #expect(clearFinished.wait(timeout: .now() + .seconds(5)) == .success)
        #expect(clearAcquired.wait(timeout: .now() + .seconds(2)) == .success)
        let performOutcome = try #require(performResult.withLock { $0 })
        let clearState = clearResult.withLock { $0 }
        #expect(clearState.failure == nil)
        let clearOutcome = try #require(clearState.outcome)
        _ = try createdURL(from: performOutcome)
        #expect(clearOutcome.profileBackupsRemoved == 1)
        #expect(clearOutcome.isComplete)
        let remaining = try FileManager.default.contentsOfDirectory(
            at: backups,
            includingPropertiesForKeys: nil
        ).map(\.lastPathComponent)
        #expect(!remaining.contains {
            $0.hasPrefix("cadenza-") && $0.hasSuffix(".store")
        })
    }

    @Test
    func explicitClearDeletesOnlyControlledProfileBackupArtifacts() throws {
        let profile = try makeTempProfile()
        defer { try? FileManager.default.removeItem(at: profile.root) }
        let base = profile.backups.appendingPathComponent("cadenza-one.store")
        try Data("backup".utf8).write(to: base)
        for suffix in ["-wal", "-shm", "-journal"] {
            try Data("sidecar".utf8).write(to: URL(fileURLWithPath: base.path + suffix))
        }
        let legacy = profile.backups.appendingPathComponent("default-old.store")
        let unrelated = profile.backups.appendingPathComponent("notes.txt")
        try Data("legacy".utf8).write(to: legacy)
        try Data("keep".utf8).write(to: unrelated)

        #expect(try DatabaseBackup.clearAutomaticBackups(
            in: profile.backups,
            for: profile.profileID,
            paths: profile.paths
        ) == 1)
        #expect(!FileManager.default.fileExists(atPath: base.path))
        #expect(FileManager.default.fileExists(atPath: legacy.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }

    @Test
    func explicitClearRejectsManagedSymlinkBeforeDeletingAnything() throws {
        let profile = try makeTempProfile()
        defer { try? FileManager.default.removeItem(at: profile.root) }
        let outside = profile.root.appendingPathComponent("outside.store")
        try Data("outside".utf8).write(to: outside)
        let safe = profile.backups.appendingPathComponent("cadenza-safe.store")
        try Data("safe".utf8).write(to: safe)
        let link = profile.backups.appendingPathComponent("cadenza-linked.store")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        #expect(throws: DatabaseBackupError.unsafeArtifact("cadenza-linked.store")) {
            try DatabaseBackup.clearAutomaticBackups(
                in: profile.backups,
                for: profile.profileID,
                paths: profile.paths
            )
        }
        #expect(FileManager.default.fileExists(atPath: outside.path))
        #expect(FileManager.default.fileExists(atPath: safe.path))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == outside.path)
    }

    @Test
    func explicitClearRejectsSymlinkedBackupDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("database-backup-link-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProfilePaths(
            root: root.appendingPathComponent("Cadenza", isDirectory: true)
        )
        let profileID = UUID()
        let profileDirectory = paths.profileDirectory(profileID)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: profileDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let outsideBackup = outside.appendingPathComponent("cadenza-outside.store")
        try Data("outside".utf8).write(to: outsideBackup)
        let linkedBackups = profileDirectory.appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedBackups, withDestinationURL: outside)

        #expect(throws: DatabaseBackupError.unsafeBackupDirectory("Backups")) {
            try DatabaseBackup.clearAutomaticBackups(
                in: linkedBackups,
                for: profileID,
                paths: paths
            )
        }
        #expect(try Data(contentsOf: outsideBackup) == Data("outside".utf8))
    }

    @Test
    func clearAllIncludesLegacyBackupsAndLeavesUnmanagedFiles() throws {
        let profile = try makeTempProfile()
        defer { try? FileManager.default.removeItem(at: profile.root) }
        let legacyBackups = profile.paths.root.deletingLastPathComponent()
            .appendingPathComponent("Cadenza-Backups", isDirectory: true)
        try FileManager.default.createDirectory(
            at: legacyBackups,
            withIntermediateDirectories: true
        )

        let profileBase = profile.backups.appendingPathComponent("cadenza-profile.store")
        try Data("profile".utf8).write(to: profileBase)
        try Data("profile sidecar".utf8).write(
            to: URL(fileURLWithPath: profileBase.path + "-wal")
        )
        let legacyCadenza = legacyBackups.appendingPathComponent("cadenza-legacy.store")
        let legacyDefault = legacyBackups.appendingPathComponent("default-legacy.store")
        try Data("legacy cadenza".utf8).write(to: legacyCadenza)
        try Data("legacy default".utf8).write(to: legacyDefault)
        try Data("legacy sidecar".utf8).write(
            to: URL(fileURLWithPath: legacyDefault.path + "-shm")
        )
        let profileUnmanaged = profile.backups.appendingPathComponent("notes.txt")
        let legacyUnmanaged = legacyBackups.appendingPathComponent("manual.store")
        try Data("keep profile".utf8).write(to: profileUnmanaged)
        try Data("keep legacy".utf8).write(to: legacyUnmanaged)
        let profileStaging = profile.backups.appendingPathComponent(
            ".cadenza-backup-staging-00000000-0000-0000-0000-000000000093.store"
        )
        let legacyStaging = legacyBackups.appendingPathComponent(
            ".cadenza-backup-staging-00000000-0000-0000-0000-000000000094.store"
        )
        try Data("profile staging".utf8).write(to: profileStaging)
        try Data("legacy staging".utf8).write(to: legacyStaging)
        try Data("legacy staging sidecar".utf8).write(
            to: URL(fileURLWithPath: legacyStaging.path + "-journal")
        )

        let outcome = try DatabaseBackup.clearAllAutomaticBackups(
            for: profile.profileID,
            paths: profile.paths
        )
        #expect(outcome.profileBackupsRemoved == 1)
        #expect(outcome.legacyBackupsRemoved == 2)
        #expect(outcome.totalBackupsRemoved == 3)
        #expect(outcome.totalStagingBackupsRemoved == 2)
        #expect(outcome.isComplete)
        #expect(!FileManager.default.fileExists(atPath: profileBase.path))
        #expect(!FileManager.default.fileExists(atPath: legacyCadenza.path))
        #expect(!FileManager.default.fileExists(atPath: legacyDefault.path))
        #expect(!FileManager.default.fileExists(atPath: profileStaging.path))
        #expect(!FileManager.default.fileExists(atPath: legacyStaging.path))
        #expect(!FileManager.default.fileExists(atPath: legacyStaging.path + "-journal"))
        #expect(try Data(contentsOf: profileUnmanaged) == Data("keep profile".utf8))
        #expect(try Data(contentsOf: legacyUnmanaged) == Data("keep legacy".utf8))
    }

    @Test
    func clearAllReturnsCountsAndResidualsWhenLegacyRemovalPartiallyFails() throws {
        let profile = try makeTempProfile()
        defer { try? FileManager.default.removeItem(at: profile.root) }
        let legacyBackups = profile.paths.root.deletingLastPathComponent()
            .appendingPathComponent("Cadenza-Backups", isDirectory: true)
        try FileManager.default.createDirectory(
            at: legacyBackups,
            withIntermediateDirectories: true
        )

        let profileBase = profile.backups.appendingPathComponent("cadenza-profile.store")
        let failingLegacy = legacyBackups.appendingPathComponent("cadenza-cannot-remove.store")
        let failingLegacyWAL = URL(fileURLWithPath: failingLegacy.path + "-wal")
        let removableLegacy = legacyBackups.appendingPathComponent("default-removable.store")
        try Data("profile".utf8).write(to: profileBase)
        try Data("legacy".utf8).write(to: failingLegacy)
        try Data("required WAL".utf8).write(to: failingLegacyWAL)
        try Data("remove me".utf8).write(to: removableLegacy)

        let outcome = try DatabaseBackup.clearAllAutomaticBackups(
            for: profile.profileID,
            paths: profile.paths,
            artifactRemover: SelectiveFailingArtifactRemover(
                failingNames: [failingLegacy.lastPathComponent]
            )
        )

        #expect(outcome.profileBackupsRemoved == 1)
        #expect(outcome.legacyBackupsRemoved == 1)
        #expect(outcome.totalBackupsRemoved == 2)
        #expect(outcome.profile.isComplete)
        #expect(!outcome.legacy.isComplete)
        #expect(outcome.legacy.failures == [
            "\(failingLegacy.lastPathComponent): errno \(EACCES)"
        ])
        #expect(outcome.legacy.residualManagedArtifacts == [
            failingLegacy.lastPathComponent,
            failingLegacyWAL.lastPathComponent
        ])
        #expect(!FileManager.default.fileExists(atPath: profileBase.path))
        #expect(!FileManager.default.fileExists(atPath: removableLegacy.path))
        #expect(try Data(contentsOf: failingLegacy) == Data("legacy".utf8))
        #expect(try Data(contentsOf: failingLegacyWAL) == Data("required WAL".utf8))
    }

    @Test
    func clearAllRejectsLegacyManagedSymlinkBeforeClearingProfile() throws {
        let profile = try makeTempProfile()
        defer { try? FileManager.default.removeItem(at: profile.root) }
        let profileBase = profile.backups.appendingPathComponent("cadenza-profile.store")
        try Data("profile".utf8).write(to: profileBase)
        let legacyBackups = profile.paths.root.deletingLastPathComponent()
            .appendingPathComponent("Cadenza-Backups", isDirectory: true)
        try FileManager.default.createDirectory(
            at: legacyBackups,
            withIntermediateDirectories: true
        )
        let legacyBase = legacyBackups.appendingPathComponent("cadenza-safe.store")
        try Data("legacy".utf8).write(to: legacyBase)
        let outside = profile.root.appendingPathComponent("outside.store")
        try Data("outside".utf8).write(to: outside)
        let link = legacyBackups.appendingPathComponent("cadenza-linked.store")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        #expect(throws: DatabaseBackupError.unsafeArtifact("cadenza-linked.store")) {
            try DatabaseBackup.clearAllAutomaticBackups(
                for: profile.profileID,
                paths: profile.paths
            )
        }
        #expect(try Data(contentsOf: profileBase) == Data("profile".utf8))
        #expect(try Data(contentsOf: legacyBase) == Data("legacy".utf8))
        #expect(try Data(contentsOf: outside) == Data("outside".utf8))
    }

    @Test
    func clearAllRejectsSymlinkedLegacyDirectoryBeforeClearingProfile() throws {
        let profile = try makeTempProfile()
        defer { try? FileManager.default.removeItem(at: profile.root) }
        let profileBase = profile.backups.appendingPathComponent("cadenza-profile.store")
        try Data("profile".utf8).write(to: profileBase)
        let outside = profile.root.appendingPathComponent("outside-legacy", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let outsideBackup = outside.appendingPathComponent("cadenza-outside.store")
        try Data("outside".utf8).write(to: outsideBackup)
        let legacyBackups = profile.paths.root.deletingLastPathComponent()
            .appendingPathComponent("Cadenza-Backups", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: legacyBackups,
            withDestinationURL: outside
        )

        #expect(throws: DatabaseBackupError.unsafeBackupDirectory("Cadenza-Backups")) {
            try DatabaseBackup.clearAllAutomaticBackups(
                for: profile.profileID,
                paths: profile.paths
            )
        }
        #expect(try Data(contentsOf: profileBase) == Data("profile".utf8))
        #expect(try Data(contentsOf: outsideBackup) == Data("outside".utf8))
    }

    @Test
    func explicitClearRejectsLookalikeAndPrefixConfusionDirectories() throws {
        let profile = try makeTempProfile()
        defer { try? FileManager.default.removeItem(at: profile.root) }
        let lookalike = profile.root
            .appendingPathComponent("Profiles", isDirectory: true)
            .appendingPathComponent(profile.profileID.uuidString, isDirectory: true)
            .appendingPathComponent("Backups", isDirectory: true)
        let prefixConfusion = URL(fileURLWithPath: profile.paths.root.path + "-copy")
            .appendingPathComponent("Profiles", isDirectory: true)
            .appendingPathComponent(profile.profileID.uuidString, isDirectory: true)
            .appendingPathComponent("Backups", isDirectory: true)
        for candidate in [lookalike, prefixConfusion] {
            try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
            let artifact = candidate.appendingPathComponent("cadenza-keep.store")
            try Data("keep".utf8).write(to: artifact)
            #expect(throws: DatabaseBackupError.invalidProfileBackupDirectory(candidate.path)) {
                try DatabaseBackup.clearAutomaticBackups(
                    in: candidate,
                    for: profile.profileID,
                    paths: profile.paths
                )
            }
            #expect(try Data(contentsOf: artifact) == Data("keep".utf8))
        }
    }
}
