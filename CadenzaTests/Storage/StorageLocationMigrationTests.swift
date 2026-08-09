import Foundation
import Testing

@testable import Cadenza

/// Failure boundaries of the copy-first directory migration: sources stay
/// complete until cleanup, collisions abort and discard only the copies,
/// a missing source directory is an empty migration (fresh installs), and
/// enumeration errors on an existing directory are never treated as an
/// empty directory.
@Suite("Storage Location Migration")
struct StorageLocationMigrationTests {

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("migration-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func touch(_ url: URL, contents: String = "x") throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
    }

    @Test func copiesSegmentsTreeAndTopLevelAudioLeavingSourcesIntact() throws {
        let old = try makeTempDir()
        let new = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.removeItem(at: new)
        }
        try touch(old.appendingPathComponent("a.m4a"))
        try touch(old.appendingPathComponent("b.mp3"))
        try touch(old.appendingPathComponent("notes.txt"))
        try touch(old.appendingPathComponent("segments/U1/seg0.m4a"))

        let outcome = try StorageLocationManager.migrateFiles(from: old, to: new)

        #expect(outcome.count == 3) // segments tree + two audio files
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: new.appendingPathComponent("a.m4a").path))
        #expect(fm.fileExists(atPath: new.appendingPathComponent("b.mp3").path))
        #expect(fm.fileExists(atPath: new.appendingPathComponent("segments/U1/seg0.m4a").path))
        // Copy-first: every source is still in place until cleanup runs.
        #expect(fm.fileExists(atPath: old.appendingPathComponent("a.m4a").path))
        #expect(fm.fileExists(atPath: old.appendingPathComponent("b.mp3").path))
        #expect(fm.fileExists(atPath: old.appendingPathComponent("segments/U1/seg0.m4a").path))
        // Non-audio files are not part of the migration.
        #expect(!fm.fileExists(atPath: new.appendingPathComponent("notes.txt").path))
    }

    @Test func missingSourceDirectoryIsAnEmptyMigration() throws {
        let new = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: new) }
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("never-existed-\(UUID().uuidString)", isDirectory: true)

        let outcome = try StorageLocationManager.migrateFiles(from: missing, to: new)
        #expect(outcome.count == 0)

        // Missing source wins over the overlap preflight: nothing exists to
        // recurse into.
        let nested = missing.appendingPathComponent("nested", isDirectory: true)
        #expect(try StorageLocationManager.migrateFiles(from: missing, to: nested).count == 0)
    }

    @Test func audioCollisionAbortsDiscardingOnlyTheCopies() throws {
        let old = try makeTempDir()
        let new = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.removeItem(at: new)
        }
        try touch(old.appendingPathComponent("a.m4a"), contents: "old-a")
        try touch(old.appendingPathComponent("z.m4a"), contents: "old-z")
        try touch(new.appendingPathComponent("z.m4a"), contents: "pre-existing")

        #expect(throws: StorageLocationManager.MigrationError.destinationCollision("z.m4a")) {
            try StorageLocationManager.migrateFiles(from: old, to: new)
        }

        let fm = FileManager.default
        // Sources untouched; the copy of a.m4a discarded; the pre-existing
        // destination file preserved byte-for-byte.
        #expect(fm.fileExists(atPath: old.appendingPathComponent("a.m4a").path))
        #expect(fm.fileExists(atPath: old.appendingPathComponent("z.m4a").path))
        #expect(!fm.fileExists(atPath: new.appendingPathComponent("a.m4a").path))
        let preserved = try String(
            contentsOf: new.appendingPathComponent("z.m4a"), encoding: .utf8
        )
        #expect(preserved == "pre-existing")
    }

    @Test func segmentsCollisionAbortsBeforeCopyingAnything() throws {
        let old = try makeTempDir()
        let new = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.removeItem(at: new)
        }
        try touch(old.appendingPathComponent("a.m4a"))
        try touch(old.appendingPathComponent("segments/U1/seg0.m4a"))
        try touch(new.appendingPathComponent("segments/OTHER/seg0.m4a"))

        #expect(throws: StorageLocationManager.MigrationError.destinationCollision("segments")) {
            try StorageLocationManager.migrateFiles(from: old, to: new)
        }
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: old.appendingPathComponent("a.m4a").path))
        #expect(!fm.fileExists(atPath: new.appendingPathComponent("a.m4a").path))
        #expect(fm.fileExists(atPath: new.appendingPathComponent("segments/OTHER/seg0.m4a").path))
    }

    @Test func enumerationFailureThrowsInsteadOfTreatingDirectoryAsEmpty() throws {
        let old = try makeTempDir()
        let new = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.removeItem(at: new)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: old.path
            )
        }
        try touch(old.appendingPathComponent("a.m4a"))
        // Remove read permission so enumeration fails while the directory exists.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o200], ofItemAtPath: old.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: old.path
            )
        }

        #expect(throws: StorageLocationManager.MigrationError.enumerationFailed(old.path)) {
            try StorageLocationManager.migrateFiles(from: old, to: new)
        }
    }

    /// A copy that fails mid-item (unreadable child inside the segments
    /// tree) must clean its own partial destination — a leftover would
    /// collide with the retry after the user fixes the cause.
    @Test func partialItemFailureLeavesNoDestinationResidue() throws {
        let old = try makeTempDir()
        let new = try makeTempDir()
        let locked = old.appendingPathComponent("segments/U1/locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try touch(old.appendingPathComponent("segments/U1/seg0.m4a"))
        try touch(locked.appendingPathComponent("inner.m4a"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.removeItem(at: new)
        }

        #expect(throws: (any Error).self) {
            try StorageLocationManager.migrateFiles(from: old, to: new)
        }

        let fm = FileManager.default
        // Source intact (modulo the deliberately locked child)…
        #expect(fm.fileExists(atPath: old.appendingPathComponent("segments/U1/seg0.m4a").path))
        // …and the destination carries no partial segments tree.
        #expect(!fm.fileExists(atPath: new.appendingPathComponent("segments").path))
    }

    @Test func verifyCopyThrowsInsteadOfComparingSwallowedErrors() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("src.m4a")
        try touch(source, contents: "1234")

        // Missing destination is a failure, not an empty measurement.
        #expect(throws: StorageLocationManager.MigrationError.self) {
            try StorageLocationManager.verifyCopy(
                from: source, to: dir.appendingPathComponent("missing.m4a")
            )
        }
        // Size mismatch fails.
        let shorter = dir.appendingPathComponent("short.m4a")
        try touch(shorter, contents: "12")
        #expect(throws: StorageLocationManager.MigrationError.self) {
            try StorageLocationManager.verifyCopy(from: source, to: shorter)
        }
        // Unreadable directory fails rather than measuring as empty on both
        // sides — Cocoa listing errors surface as the migration's own case.
        let treeA = dir.appendingPathComponent("treeA", isDirectory: true)
        let treeB = dir.appendingPathComponent("treeB", isDirectory: true)
        try touch(treeA.appendingPathComponent("a.m4a"))
        try touch(treeB.appendingPathComponent("a.m4a"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: treeA.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: treeA.path)
        }
        #expect(throws: StorageLocationManager.MigrationError.self) {
            try StorageLocationManager.verifyCopy(from: treeA, to: treeB)
        }
    }

    /// Aggregate counts are not item identity: same file count and total
    /// bytes with different names or size distribution must fail.
    @Test func verifyCopyComparesItemsNotAggregates() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let treeA = dir.appendingPathComponent("treeA", isDirectory: true)
        let treeB = dir.appendingPathComponent("treeB", isDirectory: true)

        // Same totals (2 files, 6 bytes), different distribution.
        try touch(treeA.appendingPathComponent("a.m4a"), contents: "1234")
        try touch(treeA.appendingPathComponent("sub/b.m4a"), contents: "12")
        try touch(treeB.appendingPathComponent("a.m4a"), contents: "12")
        try touch(treeB.appendingPathComponent("sub/b.m4a"), contents: "1234")
        #expect(throws: StorageLocationManager.MigrationError.self) {
            try StorageLocationManager.verifyCopy(from: treeA, to: treeB)
        }

        // Same sizes under different relative paths.
        let treeC = dir.appendingPathComponent("treeC", isDirectory: true)
        let treeD = dir.appendingPathComponent("treeD", isDirectory: true)
        try touch(treeC.appendingPathComponent("x/a.m4a"), contents: "123")
        try touch(treeD.appendingPathComponent("y/a.m4a"), contents: "123")
        #expect(throws: StorageLocationManager.MigrationError.self) {
            try StorageLocationManager.verifyCopy(from: treeC, to: treeD)
        }
    }

    /// Empty directories and symlinks inside a copied tree are part of the
    /// manifest: they round-trip through the migration, and a tampered link
    /// destination fails verification.
    @Test func manifestCoversEmptyDirectoriesAndSymlinks() throws {
        let old = try makeTempDir()
        let new = try makeTempDir()
        let outside = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.removeItem(at: new)
            try? FileManager.default.removeItem(at: outside)
        }
        let segments = old.appendingPathComponent("segments", isDirectory: true)
        try FileManager.default.createDirectory(
            at: segments.appendingPathComponent("EMPTY", isDirectory: true),
            withIntermediateDirectories: true
        )
        try touch(segments.appendingPathComponent("U1/seg0.m4a"))
        try FileManager.default.createSymbolicLink(
            at: segments.appendingPathComponent("LINK"),
            withDestinationURL: outside
        )

        let outcome = try StorageLocationManager.migrateFiles(from: old, to: new)
        #expect(outcome.count == 1)
        let copiedSegments = new.appendingPathComponent("segments", isDirectory: true)
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(
            atPath: copiedSegments.appendingPathComponent("EMPTY").path, isDirectory: &isDirectory
        ) && isDirectory.boolValue)

        // Tampering with the copied link's destination breaks verification.
        let copiedLink = copiedSegments.appendingPathComponent("LINK")
        try FileManager.default.removeItem(at: copiedLink)
        try FileManager.default.createSymbolicLink(
            at: copiedLink, withDestinationURL: outside.appendingPathComponent("elsewhere")
        )
        #expect(throws: StorageLocationManager.MigrationError.self) {
            try StorageLocationManager.verifyCopy(from: segments, to: copiedSegments)
        }
    }

    /// A node occupying the final name is never deleted: a dangling symlink
    /// (invisible to fileExists) is a collision, and a node appearing after
    /// the pre-check fails the exclusive claim instead of being replaced.
    @Test func occupiedFinalNamesAreCollisionsAndNeverDeleted() throws {
        let old = try makeTempDir()
        let new = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.removeItem(at: new)
        }
        try touch(old.appendingPathComponent("a.m4a"))
        let danglingTarget = new.appendingPathComponent("never-created")
        let occupied = new.appendingPathComponent("a.m4a")
        try FileManager.default.createSymbolicLink(at: occupied, withDestinationURL: danglingTarget)

        #expect(throws: StorageLocationManager.MigrationError.destinationCollision("a.m4a")) {
            try StorageLocationManager.migrateFiles(from: old, to: new)
        }
        // The dangling link is preserved and the source untouched.
        let attributes = try FileManager.default.attributesOfItem(atPath: occupied.path)
        #expect(attributes[.type] as? FileAttributeType == .typeSymbolicLink)
        #expect(FileManager.default.fileExists(atPath: old.appendingPathComponent("a.m4a").path))

        // Race shape: the final name gets occupied after the pre-check —
        // the exclusive claim fails and the occupying node survives.
        let staging = new.appendingPathComponent(".cadenza-migration-race")
        try touch(staging, contents: "staged")
        #expect(throws: StorageLocationManager.MigrationError.destinationCollision("a.m4a")) {
            try StorageLocationManager.claimFinalNameExclusively(
                staging: staging, final: occupied
            )
        }
        #expect((try? FileManager.default.attributesOfItem(atPath: occupied.path)) != nil)
        try FileManager.default.removeItem(at: staging)
    }

    @Test func overlappingRootsAreRejectedBeforeAnyCopy() throws {
        let old = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: old) }
        try touch(old.appendingPathComponent("a.m4a"))

        let nestedNew = old.appendingPathComponent("sub/new", isDirectory: true)
        #expect(throws: StorageLocationManager.MigrationError.overlappingRoots) {
            try StorageLocationManager.migrateFiles(from: old, to: nestedNew)
        }
        // Nothing was created or copied.
        #expect(!FileManager.default.fileExists(atPath: nestedNew.path))

        // Reverse direction with a real nested source — a missing source is
        // an empty migration and takes precedence over the overlap check.
        try FileManager.default.createDirectory(at: nestedNew, withIntermediateDirectories: true)
        try touch(nestedNew.appendingPathComponent("b.m4a"))
        #expect(throws: StorageLocationManager.MigrationError.overlappingRoots) {
            try StorageLocationManager.migrateFiles(from: nestedNew, to: old)
        }
    }

    /// A source modified after the copy holds data the copy does not —
    /// cleanup must keep it. Both a size-visible edit and a same-size edit
    /// (caught via the modification date in the snapshot) are covered.
    @Test func cleanupKeepsSourcesModifiedAfterTheCopy() throws {
        let old = try makeTempDir()
        let new = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.removeItem(at: new)
        }
        try touch(old.appendingPathComponent("grew.m4a"), contents: "1234")
        try touch(old.appendingPathComponent("edited.m4a"), contents: "abcd")
        try touch(old.appendingPathComponent("untouched.m4a"), contents: "keep")

        let outcome = try StorageLocationManager.migrateFiles(from: old, to: new)
        #expect(outcome.count == 3)

        // Size-visible change.
        try Data("123456".utf8).write(to: old.appendingPathComponent("grew.m4a"))
        // Same-size change, distinguished by the modification date.
        try Data("wxyz".utf8).write(to: old.appendingPathComponent("edited.m4a"))
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(120)],
            ofItemAtPath: old.appendingPathComponent("edited.m4a").path
        )

        StorageLocationManager.cleanupMigrationSources(outcome)

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: old.appendingPathComponent("grew.m4a").path))
        #expect(fm.fileExists(atPath: old.appendingPathComponent("edited.m4a").path))
        #expect(!fm.fileExists(atPath: old.appendingPathComponent("untouched.m4a").path))
        let preserved = try String(
            contentsOf: old.appendingPathComponent("grew.m4a"), encoding: .utf8
        )
        #expect(preserved == "123456")
    }

    /// Symlink destinations are untrusted strings: two links whose targets
    /// differ only inside characters that once doubled as encoding
    /// delimiters must still compare as different content.
    @Test func symlinkTargetsWithDelimiterLookalikesStayDistinct() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let linkA = dir.appendingPathComponent("a.m4a")
        let linkB = dir.appendingPathComponent("b.m4a")
        try FileManager.default.createSymbolicLink(
            atPath: linkA.path, withDestinationPath: "A|m:X"
        )
        try FileManager.default.createSymbolicLink(
            atPath: linkB.path, withDestinationPath: "A|m:Y"
        )

        #expect(throws: StorageLocationManager.MigrationError.self) {
            try StorageLocationManager.verifyCopy(from: linkA, to: linkB)
        }
        let snapshotA = try StorageLocationManager.ownershipSnapshot(of: linkA)
        let snapshotB = try StorageLocationManager.ownershipSnapshot(of: linkB)
        #expect(snapshotA.content != snapshotB.content)
    }

    /// Same size, different bytes: the digest in the manifest must fail the
    /// comparison — sizes and dates alone are not content evidence.
    @Test func verifyCopyFailsForSameSizeDifferentContent() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.m4a")
        let b = dir.appendingPathComponent("b.m4a")
        try touch(a, contents: "abcd")
        try touch(b, contents: "wxyz")

        #expect(throws: StorageLocationManager.MigrationError.self) {
            try StorageLocationManager.verifyCopy(from: a, to: b)
        }
    }

    /// The same destination inode edited in place is no longer the copy the
    /// migration placed — cleanup must keep the source.
    @Test func cleanupKeepsSourceWhenDestinationEditedInPlace() throws {
        let old = try makeTempDir()
        let new = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.removeItem(at: new)
        }
        try touch(old.appendingPathComponent("a.m4a"), contents: "original")

        let outcome = try StorageLocationManager.migrateFiles(from: old, to: new)
        #expect(outcome.count == 1)

        // In-place rewrite: same inode, different bytes.
        let placed = new.appendingPathComponent("a.m4a")
        let identityBefore = try StorageLocationManager.fileIdentity(of: placed)
        let handle = try FileHandle(forWritingTo: placed)
        try handle.write(contentsOf: Data("REWRITTE".utf8))
        try handle.close()
        #expect(try StorageLocationManager.fileIdentity(of: placed) == identityBefore)

        StorageLocationManager.cleanupMigrationSources(outcome)

        #expect(FileManager.default.fileExists(atPath: old.appendingPathComponent("a.m4a").path))
        #expect(try String(
            contentsOf: old.appendingPathComponent("a.m4a"), encoding: .utf8
        ) == "original")
    }

    /// A destination replaced after placement is no longer this migration's
    /// node — discard must keep the replacement.
    @Test func discardKeepsReplacedDestinations() throws {
        let old = try makeTempDir()
        let new = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.removeItem(at: new)
        }
        try touch(old.appendingPathComponent("mine.m4a"), contents: "copied")
        try touch(old.appendingPathComponent("swapped.m4a"), contents: "copied-too")

        let outcome = try StorageLocationManager.migrateFiles(from: old, to: new)
        #expect(outcome.count == 2)

        // Replace one placed copy with an unrelated node (new inode).
        let swapped = new.appendingPathComponent("swapped.m4a")
        try FileManager.default.removeItem(at: swapped)
        try Data("replacement".utf8).write(to: swapped)

        StorageLocationManager.discardMigrationCopies(outcome)

        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: new.appendingPathComponent("mine.m4a").path))
        #expect(fm.fileExists(atPath: swapped.path))
        #expect(try String(contentsOf: swapped, encoding: .utf8) == "replacement")
    }

    @Test func discardRemovesCopiesAndCleanupRemovesSources() throws {
        let old = try makeTempDir()
        let new = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.removeItem(at: new)
        }
        try touch(old.appendingPathComponent("a.m4a"))
        try touch(old.appendingPathComponent("segments/U1/seg0.m4a"))

        let fm = FileManager.default
        let discarded = try StorageLocationManager.migrateFiles(from: old, to: new)
        StorageLocationManager.discardMigrationCopies(discarded)
        #expect(fm.fileExists(atPath: old.appendingPathComponent("a.m4a").path))
        #expect(!fm.fileExists(atPath: new.appendingPathComponent("a.m4a").path))
        #expect(!fm.fileExists(atPath: new.appendingPathComponent("segments").path))

        let committed = try StorageLocationManager.migrateFiles(from: old, to: new)
        StorageLocationManager.cleanupMigrationSources(committed)
        #expect(!fm.fileExists(atPath: old.appendingPathComponent("a.m4a").path))
        #expect(!fm.fileExists(atPath: old.appendingPathComponent("segments").path))
        #expect(fm.fileExists(atPath: new.appendingPathComponent("a.m4a").path))
        #expect(fm.fileExists(atPath: new.appendingPathComponent("segments/U1/seg0.m4a").path))
    }
}
