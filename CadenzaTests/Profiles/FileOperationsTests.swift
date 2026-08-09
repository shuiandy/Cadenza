import Foundation
import SQLite3
import SwiftData
import Testing

@testable import Cadenza

/// Hardened seam semantics: exclusive 0o600 temp files (no permissive
/// window), symlink-swap rejection on read and hash, and durable renames.
@Suite("File Operations Hardening")
struct FileOperationsTests {

    private let live = LiveFileOperations()

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fileops-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The temp file is born 0o600 and the rename preserves it, so the
    /// destination never passes through a wider mode.
    @Test func atomicReplaceProducesOwnerOnlyPermissions() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let destination = dir.appendingPathComponent("doc.json")
        try live.atomicReplace(Data("content".utf8), at: destination)

        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        #expect(try live.read(from: destination) == Data("content".utf8))
        // No temp residue.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix(".atomic-") }
        #expect(leftovers.isEmpty)
    }

    @Test func exclusiveCreateCannotReplaceAnExistingClaim() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let claim = dir.appendingPathComponent("claim")
        let original = Data("original".utf8)
        try live.createFileExclusively(original, at: claim)

        #expect(throws: FileOperationError.createFailed(errno: EEXIST)) {
            try live.createFileExclusively(Data("replacement".utf8), at: claim)
        }
        #expect(try live.read(from: claim) == original)
        let attributes = try FileManager.default.attributesOfItem(atPath: claim.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
    }

    /// A symlink swapped in at the target path fails the open on both the
    /// read and the hash path instead of following the link.
    @Test func readAndHashRejectSymlinkTargets() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appendingPathComponent("real.bin")
        try Data("secret".utf8).write(to: real)
        let link = dir.appendingPathComponent("link.bin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        #expect(throws: (any Error).self) { try live.read(from: link) }
        #expect(throws: FileOperationError.hashFailed("link.bin")) {
            _ = try live.sha256(of: link)
        }
        // The regular file still reads and hashes.
        #expect(try live.read(from: real) == Data("secret".utf8))
        #expect(try live.sha256(of: real).count == 64)
    }

    /// The failure path after the descriptor has closed (rename onto an
    /// occupied directory) surfaces the error and leaves no temp residue.
    @Test func atomicReplaceFailurePathCleansUpTempFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let occupiedDirectory = dir.appendingPathComponent("occupied", isDirectory: true)
        try FileManager.default.createDirectory(at: occupiedDirectory, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: occupiedDirectory.appendingPathComponent("inner.txt"))

        #expect(throws: FileOperationError.self) {
            try live.atomicReplace(Data("data".utf8), at: occupiedDirectory)
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix(".atomic-") }
        #expect(leftovers.isEmpty)
        // The occupied directory is untouched.
        #expect(FileManager.default.fileExists(
            atPath: occupiedDirectory.appendingPathComponent("inner.txt").path
        ))
    }

    /// `moveItemExclusively` refuses to replace an existing target.
    @Test func exclusiveMoveRefusesOccupiedTargets() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.txt")
        let target = dir.appendingPathComponent("target.txt")
        try Data("a".utf8).write(to: source)
        try Data("b".utf8).write(to: target)

        #expect(throws: FileOperationError.renameFailed(errno: EEXIST)) {
            try live.moveItemExclusively(staging: source, final: target)
        }
        #expect(try Data(contentsOf: target) == Data("b".utf8))
        #expect(try Data(contentsOf: source) == Data("a".utf8))
    }
}

/// Byte-stability regressions for the migration snapshot: typed rows make
/// delimiter collisions impossible, and UTF-8 code-unit ordering keeps
/// canonically-equivalent-but-different strings deterministic.
@Suite("Migration Snapshot Rigor", .serialized)
struct MigrationSnapshotRigorTests {

    @MainActor
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: RecordingsStore.schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    /// Two stores whose values would collide under any "join fields with a
    /// separator" scheme must snapshot differently.
    @Test @MainActor
    func fieldValuesContainingSeparatorsNeverCollide() throws {
        let id = UUID()
        let stamp = Date(timeIntervalSince1970: 1_785_000_000)

        func makeStore(text: String, speaker: String?) throws -> ModelContainer {
            let container = try makeContainer()
            let context = ModelContext(container)
            let recording = Recording(id: id, title: "r", startDate: stamp)
            recording.createdAt = stamp
            recording.updatedAt = stamp
            let transcript = Transcript(fullText: "f", segments: [
                TranscriptEntry(startTime: 1, endTime: 2, text: text, speaker: speaker)
            ])
            transcript.createdAt = stamp
            recording.transcript = transcript
            context.insert(recording)
            try context.save()
            return container
        }

        // "x|1" + nil vs "x" + "1": a "text|speaker" join collides; typed
        // rows must not. The transcript ids differ across containers, so
        // compare the segment rows directly.
        let first = try MigrationStoreSnapshot.capture(
            container: makeStore(text: "x|1", speaker: nil)
        )
        let second = try MigrationStoreSnapshot.capture(
            container: makeStore(text: "x", speaker: "1")
        )
        let firstSegments = try #require(first.recordings.first?.transcript?.segments)
        let secondSegments = try #require(second.recordings.first?.transcript?.segments)
        #expect(firstSegments.first?.text.string == "x|1")
        #expect(secondSegments.first?.text.string == "x")
        #expect(firstSegments.first?.speaker == nil)
        #expect(secondSegments.first?.speaker?.string == "1")
    }

    /// NFC and NFD spellings are different byte strings: inserting them in
    /// opposite orders must still produce identical snapshots (order is
    /// decided by UTF-8 code units, not insertion or canonical
    /// equivalence), and the two spellings must never be conflated.
    @Test @MainActor
    func canonicallyEquivalentStringsStayDistinctAndOrdered() throws {
        let nfc = "é"  // U+00E9
        let nfd = "e\u{0301}"  // U+0065 U+0301
        #expect(nfc == nfd)  // Swift String equality is canonical…
        #expect(!nfc.utf8.elementsEqual(nfd.utf8))  // …the bytes are not.

        let recordingID = UUID()
        let stamp = Date(timeIntervalSince1970: 1_785_000_000)

        func makeStore(order: [String]) throws -> ModelContainer {
            let container = try makeContainer()
            let context = ModelContext(container)
            for label in order {
                let sample = SpeakerVoiceSample(
                    recordingID: recordingID, rawLabel: label, profile: nil,
                    embeddingData: Data([1]), embeddingDimension: 1,
                    sampleDuration: 1, nonOverlapRatio: 1, qualityScore: 1,
                    modelVersion: "v1"
                )
                sample.createdAt = stamp
                context.insert(sample)
            }
            try context.save()
            return container
        }

        let forward = try MigrationStoreSnapshot.capture(container: makeStore(order: [nfc, nfd]))
        let backward = try MigrationStoreSnapshot.capture(container: makeStore(order: [nfd, nfc]))
        #expect(forward.voiceSamples.count == 2)
        #expect(forward.voiceSamples == backward.voiceSamples)
        // Both spellings survive as distinct rows.
        let labels = forward.voiceSamples.map(\.rawLabel)
        #expect(labels.contains { $0.string.utf8.elementsEqual(nfc.utf8) })
        #expect(labels.contains { $0.string.utf8.elementsEqual(nfd.utf8) })
    }

    /// Row streams are bracketed per table: two databases with identical
    /// schemas whose identically-encoded row lives in table A in one and
    /// table B in the other must digest differently, and empty tables
    /// still contribute their marker deterministically.
    @Test func tableBoundariesPreventCrossTableRowCollisions() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("digest-collision-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        func makeDatabase(named name: String, rowInTable: String) throws -> URL {
            let url = dir.appendingPathComponent(name)
            var db: OpaquePointer?
            #expect(sqlite3_open_v2(
                url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil
            ) == SQLITE_OK)
            defer { sqlite3_close(db) }
            #expect(sqlite3_exec(
                db, "CREATE TABLE a(x INTEGER); CREATE TABLE b(x INTEGER);", nil, nil, nil
            ) == SQLITE_OK)
            #expect(sqlite3_exec(
                db, "INSERT INTO \(rowInTable) VALUES(7);", nil, nil, nil
            ) == SQLITE_OK)
            return url
        }

        let rowInA = try makeDatabase(named: "row-in-a.db", rowInTable: "a")
        let rowInB = try makeDatabase(named: "row-in-b.db", rowInTable: "b")
        let digestA = try SQLiteLogicalDigest.digest(of: rowInA)
        let digestB = try SQLiteLogicalDigest.digest(of: rowInB)
        #expect(digestA != digestB)
        // Deterministic across repeated reads, including the empty table.
        #expect(try SQLiteLogicalDigest.digest(of: rowInA) == digestA)
        #expect(try SQLiteLogicalDigest.digest(of: rowInB) == digestB)
    }

    /// A store holding only the NFC spelling and one holding only the NFD
    /// spelling contain different bytes and must snapshot differently,
    /// even though Swift String equality would call the values equal.
    @Test @MainActor
    func nfcOnlyAndNfdOnlyStoresSnapshotDifferently() throws {
        let nfc = "é"
        let nfd = "e\u{0301}"
        let id = UUID()
        let stamp = Date(timeIntervalSince1970: 1_785_000_000)

        func makeStore(title: String) throws -> ModelContainer {
            let container = try makeContainer()
            let context = ModelContext(container)
            let recording = Recording(id: id, title: title, startDate: stamp)
            recording.createdAt = stamp
            recording.updatedAt = stamp
            context.insert(recording)
            try context.save()
            return container
        }

        let nfcSnapshot = try MigrationStoreSnapshot.capture(container: makeStore(title: nfc))
        let nfdSnapshot = try MigrationStoreSnapshot.capture(container: makeStore(title: nfd))
        #expect(nfcSnapshot.recordings.first?.title.string == nfdSnapshot.recordings.first?.title.string)
        #expect(nfcSnapshot != nfdSnapshot)
    }
}
