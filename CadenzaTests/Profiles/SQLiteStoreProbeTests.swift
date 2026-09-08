import Foundation
import SQLite3
import SwiftData
import Testing

@testable import Cadenza

/// The boot-time store probe: passes exactly the databases the old
/// digest-as-probe passed, and fails closed on everything else — garbage
/// files, corrupted pages, symlinks. The gate-level test proves the boot
/// pipeline still halts on a corrupt store after the probe swap.
@Suite("SQLite Store Probe", .serialized)
struct SQLiteStoreProbeTests {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("store-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Multi-page database: enough blob rows that page 2 is guaranteed to
    /// be a live b-tree page, so wholesale page corruption cannot land in
    /// unused space.
    private func makeHealthyDatabase(at url: URL) throws {
        var db: OpaquePointer?
        #expect(sqlite3_open_v2(
            url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil
        ) == SQLITE_OK)
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(
            db, "PRAGMA journal_mode=DELETE; CREATE TABLE t(x BLOB);", nil, nil, nil
        ) == SQLITE_OK)
        for _ in 0..<64 {
            #expect(sqlite3_exec(
                db, "INSERT INTO t VALUES(randomblob(1024));", nil, nil, nil
            ) == SQLITE_OK)
        }
    }

    @Test func healthyDatabasePasses() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("healthy.db")
        try makeHealthyDatabase(at: url)
        try SQLiteStoreProbe.verifyReadable(at: url)
    }

    @Test func nonDatabaseGarbageFailsClosed() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("garbage.db")
        try Data("definitely not a sqlite database".utf8).write(to: url)
        #expect(throws: (any Error).self) {
            try SQLiteStoreProbe.verifyReadable(at: url)
        }
    }

    @Test func corruptedPageFailsClosed() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("corrupt.db")
        try makeHealthyDatabase(at: url)
        try SQLiteStoreProbe.verifyReadable(at: url)

        // Overwrite all of page 2 (the first page after the header page)
        // with garbage; the file keeps its size and header.
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: 4096)
        try handle.write(contentsOf: Data(repeating: 0xAA, count: 4096))
        try handle.synchronize()

        #expect(throws: (any Error).self) {
            try SQLiteStoreProbe.verifyReadable(at: url)
        }
    }

    @Test func symlinkTargetsRejected() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appendingPathComponent("real.db")
        try makeHealthyDatabase(at: real)
        let link = dir.appendingPathComponent("link.db")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(throws: (any Error).self) {
            try SQLiteStoreProbe.verifyReadable(at: link)
        }
    }
}

/// Boot pipeline regression: the store gate must still halt on a corrupt
/// store now that it probes instead of digesting.
@Suite("Boot Store Gate", .serialized)
struct BootStoreGateTests {

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

    private func makeFixture() throws -> Fixture {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("boot-gate-\(UUID().uuidString)", isDirectory: true)
        let audioRoot = base.appendingPathComponent("AudioRoot", isDirectory: true)
        try FileManager.default.createDirectory(at: audioRoot, withIntermediateDirectories: true)
        let paths = ProfilePaths(root: base.appendingPathComponent("Cadenza", isDirectory: true))
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        let suiteName = "boot-gate-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let operations = LiveFileOperations()
        let dependencies = M1StorageMigration.Dependencies(
            paths: paths,
            registry: DiskProfileRegistry(
                registryURL: paths.registryURL, fileOperations: operations
            ),
            fileOperations: operations,
            backupDriver: LiveSQLiteBackupDriver(),
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

    @Test @MainActor
    func corruptStoreHaltsTheNextBoot() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        // First boot: fresh install commits a registry and materializes
        // the store.
        let first = ProfileBootstrap.run(dependencies: fixture.dependencies)
        guard case .profile(let id) = first.mode else {
            Issue.record("expected profile boot, got \(first.mode)")
            return
        }
        let storeURL = fixture.paths.storeURL(id)
        // Materialize a real database at the committed path, as the app's
        // container creation would; scoped so the connection is closed
        // before the corruption below.
        do {
            let container = try ModelContainer(
                for: RecordingsStore.schema,
                configurations: ModelConfiguration(url: storeURL)
            )
            _ = container
        }
        let second = ProfileBootstrap.run(dependencies: fixture.dependencies)
        guard case .profile = second.mode else {
            Issue.record("healthy store should boot, got \(second.mode)")
            return
        }

        // Corrupt the store wholesale; the next boot must halt, not let
        // SwiftData recreate an empty database silently.
        try Data("definitely not a sqlite database".utf8).write(to: storeURL)
        let third = ProfileBootstrap.run(dependencies: fixture.dependencies)
        guard case .halted(let reason) = third.mode else {
            Issue.record("expected halt on corrupt store, got \(third.mode)")
            return
        }
        #expect(reason.contains("profile store unavailable"))
    }
}
