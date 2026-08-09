import Foundation
import Testing
@testable import Cadenza

@Suite("Storage Ownership", .serialized)
struct StorageOwnershipTests {
    private func makeDirectory(_ name: String = UUID().uuidString) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cadenza-storage-ownership-tests", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func containmentRejectsLexicalSiblingPrefix() throws {
        let parent = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("Recordings", isDirectory: true)
        let sibling = parent.appendingPathComponent("Recordings-old", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let source = sibling.appendingPathComponent("outside.m4a")
        try Data([1, 2, 3]).write(to: source)

        #expect(!StorageOwnership.contains(source, in: root))
        #expect(StorageOwnership.importDisposition(for: source, storageRoot: root) == .copyIntoStorage)
    }

    @Test func containmentRejectsSymlinkEscape() throws {
        let parent = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("Recordings", isDirectory: true)
        let outside = parent.appendingPathComponent("outside.m4a")
        let link = root.appendingPathComponent("linked.m4a")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([4, 5, 6]).write(to: outside)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        #expect(!StorageOwnership.contains(link, in: root))
        #expect(StorageOwnership.canonicalImportSource(link) == StorageOwnership.canonicalURL(outside))
        #expect(StorageOwnership.importDisposition(for: link, storageRoot: root) == .copyIntoStorage)
    }

    @Test func importPlanResolvesValidExternalSymlinkToRegularTarget() throws {
        let parent = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("Recordings", isDirectory: true)
        let target = parent.appendingPathComponent("target.m4a")
        let link = parent.appendingPathComponent("incoming.m4a")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([2, 4, 6, 8]).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let plan = try #require(StorageOwnership.importPlan(for: link, storageRoot: root))
        #expect(plan == StorageImportPlan(
            sourceURL: StorageOwnership.canonicalURL(target),
            disposition: .copyIntoStorage
        ))
        let values = try plan.sourceURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        #expect(values.isRegularFile == true)
        #expect(values.isSymbolicLink != true)
    }

    @Test func secureCopyRejectsSourceReplacedBySymlink() throws {
        let parent = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("Recordings", isDirectory: true)
        let source = parent.appendingPathComponent("source.m4a")
        let external = parent.appendingPathComponent("external.m4a")
        let destination = root.appendingPathComponent("copied.m4a")
        let externalBytes = Data([9, 8, 7, 6])
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([1, 2, 3, 4]).write(to: source)
        try externalBytes.write(to: external)

        let plan = try #require(StorageOwnership.importPlan(for: source, storageRoot: root))
        try FileManager.default.removeItem(at: source)
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: external)

        #expect(throws: (any Error).self) {
            try StorageOwnership.copyRegularFile(from: plan.sourceURL, to: destination)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try Data(contentsOf: external) == externalBytes)
    }

    @Test func secureCopyCreatesRegularFileWithMatchingBytes() throws {
        let parent = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let source = parent.appendingPathComponent("source.m4a")
        let destination = parent.appendingPathComponent("destination.m4a")
        let sourceBytes = Data([0, 1, 2, 3, 4, 5, 255])
        try sourceBytes.write(to: source)

        try StorageOwnership.copyRegularFile(from: source, to: destination)

        #expect(try Data(contentsOf: destination) == sourceBytes)
        let values = try destination.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        #expect(values.isRegularFile == true)
        #expect(values.isSymbolicLink != true)
    }

    @Test func brokenSymlinkIsRejectedForContainmentAndImport() throws {
        let parent = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("Recordings", isDirectory: true)
        let missing = parent.appendingPathComponent("missing.m4a")
        let link = root.appendingPathComponent("broken.m4a")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: missing)

        #expect(!StorageOwnership.contains(link, in: root))
        #expect(StorageOwnership.canonicalImportSource(link) == nil)
        #expect(StorageOwnership.importDisposition(for: link, storageRoot: root) == .rejectInvalidSource)
    }

    @Test func symlinkLoopIsRejectedForContainmentAndImport() throws {
        let parent = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("Recordings", isDirectory: true)
        let first = root.appendingPathComponent("first.m4a")
        let second = root.appendingPathComponent("second.m4a")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: first, withDestinationURL: second)
        try FileManager.default.createSymbolicLink(at: second, withDestinationURL: first)

        #expect(!StorageOwnership.contains(first, in: root))
        #expect(StorageOwnership.canonicalImportSource(first) == nil)
        #expect(StorageOwnership.importDisposition(for: first, storageRoot: root) == .rejectInvalidSource)
    }

    @Test func containmentAcceptsStandardizedDescendant() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("one/../two/inside.m4a")
        try FileManager.default.createDirectory(at: nested.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([7]).write(to: nested.standardizedFileURL)

        #expect(StorageOwnership.contains(nested, in: root))
        #expect(StorageOwnership.importDisposition(for: nested, storageRoot: root) == .reuseOwnedFile)
    }

    @Test func nonM4ASourceRequiresTranscodeEvenInsideRoot() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("inside.wav")
        try Data([1, 2, 3]).write(to: source)

        #expect(StorageOwnership.importDisposition(for: source, storageRoot: root) == .transcodeIntoStorage)
    }

    @Test func usageSeparatesExternalBytesAndDeduplicatesOwnedPaths() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let owned = root.appendingPathComponent("owned.m4a")
        let external = root.appendingPathComponent("sync-metadata.bin")
        try Data(repeating: 1, count: 4).write(to: owned)
        try Data(repeating: 2, count: 9).write(to: external)

        let usage = StorageOwnership.measureUsage(
            in: root,
            ownedFiles: [owned, owned],
            ownedDirectories: []
        )

        #expect(usage.ownedBytes == 4)
        #expect(usage.externalBytes == 9)
        #expect(usage.ownedFileCount == 1)
        #expect(usage.externalFileCount == 1)
    }

    @Test func usageAttributesFilesInsideOwnedSegmentDirectory() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let segments = root.appendingPathComponent("segments/recording", isDirectory: true)
        try FileManager.default.createDirectory(at: segments, withIntermediateDirectories: true)
        try Data(repeating: 3, count: 5).write(to: segments.appendingPathComponent("segment-0001.m4a"))

        let usage = StorageOwnership.measureUsage(
            in: root,
            ownedFiles: [],
            ownedDirectories: [segments]
        )

        #expect(usage.ownedBytes == 5)
        #expect(usage.externalBytes == 0)
        #expect(usage.ownedFileCount == 1)
    }

    @Test func quotaStatusUsesOwnedBytesAndTreatsLimitAsInclusive() {
        let usage = StorageUsageSnapshot(
            ownedBytes: 10,
            externalBytes: 1_000,
            ownedFileCount: 1,
            externalFileCount: 1
        )

        #expect(!StorageQuotaStatus(usage: usage, limitBytes: nil).isOverLimit)
        #expect(!StorageQuotaStatus(usage: usage, limitBytes: -1).isOverLimit)
        #expect(!StorageQuotaStatus(usage: usage, limitBytes: 0).isOverLimit)
        #expect(!StorageQuotaStatus(usage: usage, limitBytes: 10).isOverLimit)
        #expect(StorageQuotaStatus(usage: usage, limitBytes: 9).isOverLimit)
    }

    @Test func quotaStatusHandlesMaximumByteBoundaryWithoutOverflow() {
        let usage = StorageUsageSnapshot(
            ownedBytes: .max,
            externalBytes: 0,
            ownedFileCount: 1,
            externalFileCount: 0
        )

        #expect(!StorageQuotaStatus(usage: usage, limitBytes: .max).isOverLimit)
        #expect(StorageQuotaStatus(usage: usage, limitBytes: .max - 1).isOverLimit)
    }

    @Test func quotaAdvisoryPrioritizesReviewOverExternalNotice() {
        let usage = StorageUsageSnapshot(
            ownedBytes: 20,
            externalBytes: 100,
            ownedFileCount: 2,
            externalFileCount: 1
        )
        let status = StorageQuotaStatus(usage: usage, limitBytes: 10)

        #expect(status.advisory == .reviewRequired)
    }

    @Test func quotaAdvisoryExplainsExcludedExternalFiles() {
        let usage = StorageUsageSnapshot(
            ownedBytes: 5,
            externalBytes: 100,
            ownedFileCount: 1,
            externalFileCount: 1
        )
        let status = StorageQuotaStatus(usage: usage, limitBytes: 10)

        #expect(status.advisory == .externalFilesExcluded)
    }

    @Test func quotaAdvisoryIsNoneForOwnedUsageWithinLimit() {
        let usage = StorageUsageSnapshot(
            ownedBytes: 5,
            externalBytes: 0,
            ownedFileCount: 1,
            externalFileCount: 0
        )
        let status = StorageQuotaStatus(usage: usage, limitBytes: 10)

        #expect(status.advisory == .none)
    }

    @Test func storageLimitConversionTreatsNonPositiveValuesAsUnlimited() {
        #expect(StorageQuotaStatus.limitBytes(fromMegabytes: -1) == nil)
        #expect(StorageQuotaStatus.limitBytes(fromMegabytes: 0) == nil)
    }

    @Test func storageLimitConversionClampsPositiveOverflow() {
        let bytesPerMegabyte: Int64 = 1_024 * 1_024
        let largestExactWholeMegabytes = Int(Int64.max / bytesPerMegabyte)
        let largestExactByteLimit = Int64(largestExactWholeMegabytes) * bytesPerMegabyte

        #expect(
            StorageQuotaStatus.limitBytes(fromMegabytes: largestExactWholeMegabytes)
                == largestExactByteLimit
        )
        #expect(
            StorageQuotaStatus.limitBytes(fromMegabytes: largestExactWholeMegabytes + 1)
                == Int64.max
        )
        #expect(StorageQuotaStatus.limitBytes(fromMegabytes: Int.max) == Int64.max)
    }
}
