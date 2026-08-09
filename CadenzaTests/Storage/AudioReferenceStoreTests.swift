import Foundation
import SwiftData
import Testing

@testable import Cadenza

/// Store-boundary regressions for the reference layer: normal writes are
/// strictly relative (out-of-root writes fail without side effects), the
/// move flow repairs legacy rows only through the migration's explicit
/// copy mapping, the split-root pin is transactional, and deletion of a
/// row must never remove another recording's file — neither through a
/// same-basename guess nor through symlink resolution.
@Suite("Audio Reference Store Boundary")
struct AudioReferenceStoreTests {

    @MainActor
    private func makeStore(root: URL) throws -> RecordingsStore {
        let schema = Schema([
            Recording.self, Transcript.self, MeetingSummary.self, Folder.self,
            Recap.self, SpeakerProfile.self, SpeakerVoiceSample.self,
            AgentArtifact.self, WebSyncRecord.self, ExternalRecordingImport.self,
        ])
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let store = RecordingsStore(modelContainer: container)
        return store
    }

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ref-store-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func touch(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("x".utf8).write(to: url)
    }

    // MARK: - Strict relative writes

    @Test func importAndFinalizeStoreRelativeValues() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await makeStore(root: root)
        await store.setAudioRootForTesting(root)

        let importedURL = root.appendingPathComponent("imported.m4a")
        try touch(importedURL)
        let importedID = UUID()
        #expect(await store.importAudioFile(
            id: importedID, title: "Imported", startDate: .now,
            duration: 120, audioURL: importedURL, ownership: .appCreated))
        let imported = try #require(await store.fetchRecordingDetail(recordingID: importedID))
        #expect(imported.audioFile == .relative("imported.m4a"))

        let liveID = UUID()
        let segmentsDir = root.appendingPathComponent("segments/\(liveID.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: segmentsDir, withIntermediateDirectories: true)
        #expect(await store.createRecording(
            id: liveID, title: "Live", startDate: .now, segmentsDirURL: segmentsDir
        ))
        let mergedURL = root.appendingPathComponent("\(liveID.uuidString).m4a")
        try touch(mergedURL)
        let result = await store.finalizeRecording(
            id: liveID, duration: 300, audioFileURL: mergedURL
        )
        #expect(result == .saved)
        let finalized = try #require(await store.fetchRecordingDetail(recordingID: liveID))
        #expect(finalized.audioFile == .relative("\(liveID.uuidString).m4a"))
    }

    @Test func recoveredRecordingStoresRelativeValue() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await makeStore(root: root)
        await store.setAudioRootForTesting(root)

        let id = UUID()
        let segmentsDir = root.appendingPathComponent("segments/\(id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: segmentsDir, withIntermediateDirectories: true)
        #expect(await store.createRecording(
            id: id, title: "Crashed", startDate: .now, segmentsDirURL: segmentsDir
        ))
        let recoveredURL = root.appendingPathComponent("recovered.m4a")
        try touch(recoveredURL)
        #expect(await store.updateRecoveredRecording(
            id: id, endDate: .now, duration: 200, audioFileURL: recoveredURL
        ))
        let detail = try #require(await store.fetchRecordingDetail(recordingID: id))
        #expect(detail.audioFile == .relative("recovered.m4a"))
    }

    /// Normal writes never degrade to legacy form: an out-of-root URL fails
    /// the operation without creating or mutating a row.
    @Test func outOfRootWritesFailWithoutSideEffects() async throws {
        let root = try makeTempDir()
        let outside = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let store = try await makeStore(root: root)
        await store.setAudioRootForTesting(root)

        let outsideURL = outside.appendingPathComponent("elsewhere.m4a")
        try touch(outsideURL)

        let importID = UUID()
        #expect(await store.importAudioFile(
            id: importID, title: "Outside", startDate: .now, duration: 90, audioURL: outsideURL, ownership: .appCreated) == false)
        #expect(await store.fetchRecordingDetail(recordingID: importID) == nil)

        let finalizeID = UUID()
        #expect(await store.createRecording(
            id: finalizeID, title: "Live", startDate: .now, segmentsDirURL: nil
        ))
        let result = await store.finalizeRecording(
            id: finalizeID, duration: 300, audioFileURL: outsideURL
        )
        #expect(result == .failed)
        let detail = try #require(await store.fetchRecordingDetail(recordingID: finalizeID))
        #expect(detail.audioFile == nil)
    }

    // MARK: - Deletion safety (legacy rows never alias by basename)

    /// A legacy row whose file is gone shares a filename with a healthy
    /// recording in the current root. Permanently deleting the legacy row
    /// must not touch the healthy recording's file.
    @Test func deletingLegacyRowNeverRemovesSameNamedFileInRoot() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await makeStore(root: root)
        await store.setAudioRootForTesting(root)

        let healthyID = UUID()
        let healthyURL = root.appendingPathComponent("same-name.m4a")
        try touch(healthyURL)
        #expect(await store.importAudioFile(
            id: healthyID, title: "Healthy", startDate: .now, duration: 60, audioURL: healthyURL, ownership: .appCreated))

        let legacyID = UUID()
        #expect(await store.createRecording(
            id: legacyID, title: "Legacy", startDate: .now, segmentsDirURL: nil
        ))
        #expect(await store.setRawAudioReferencesForTesting(
            recordingID: legacyID,
            audioFilePath: "/gone/old-root/same-name.m4a",
            segmentsDirectory: "/gone/old-root/segments/\(healthyID.uuidString)"
        ))

        #expect(await store.deleteRecording(recordingID: legacyID))
        #expect(await store.permanentlyDelete(recordingID: legacyID))

        #expect(FileManager.default.fileExists(atPath: healthyURL.path))
        let healthy = try #require(await store.fetchRecordingDetail(recordingID: healthyID))
        let resolved = try #require(await store.fetchAudioPaths(recordingIDs: [healthyID])[healthyID])
        #expect(healthy.audioFile == .relative("same-name.m4a"))
        #expect(FileManager.default.fileExists(atPath: resolved.path))
    }

    // MARK: - Move flow: mapping-driven relocation

    /// The move flow: files are copied, then relocation rewrites exactly
    /// the legacy rows whose subpath appears in the migration's copy
    /// mapping. Relative rows follow the root with no rewrite; legacy rows
    /// outside the old root are untouched.
    @Test func relocationRewritesOnlyMappedLegacyRows() async throws {
        let rootA = try makeTempDir()
        let rootB = try makeTempDir()
        let elsewhere = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: rootA)
            try? FileManager.default.removeItem(at: rootB)
            try? FileManager.default.removeItem(at: elsewhere)
        }
        let store = try await makeStore(root: rootA)
        await store.setAudioRootForTesting(rootA)

        // Relative row — follows the root, no rewrite expected.
        let relativeID = UUID()
        let relativeURL = rootA.appendingPathComponent("follows-root.m4a")
        try touch(relativeURL)
        #expect(await store.importAudioFile(
            id: relativeID, title: "Relative", startDate: .now, duration: 60, audioURL: relativeURL, ownership: .appCreated))

        // Legacy rows under root A: an audio file and a segments tree entry.
        let movedLegacyID = UUID()
        let movedLegacySegments = rootA.appendingPathComponent("segments/OLD-1", isDirectory: true)
        try FileManager.default.createDirectory(at: movedLegacySegments, withIntermediateDirectories: true)
        try touch(movedLegacySegments.appendingPathComponent("seg0.m4a"))
        let movedLegacyAudio = rootA.appendingPathComponent("legacy-moved.m4a")
        try touch(movedLegacyAudio)
        #expect(await store.createRecording(
            id: movedLegacyID, title: "LegacyMoved", startDate: .now, segmentsDirURL: nil
        ))
        #expect(await store.setRawAudioReferencesForTesting(
            recordingID: movedLegacyID,
            audioFilePath: movedLegacyAudio.path,
            segmentsDirectory: movedLegacySegments.path
        ))

        // Legacy row outside root A — must stay untouched.
        let outsideID = UUID()
        let outsideURL = elsewhere.appendingPathComponent("outside.m4a")
        try touch(outsideURL)
        #expect(await store.createRecording(
            id: outsideID, title: "Outside", startDate: .now, segmentsDirURL: nil
        ))
        #expect(await store.setRawAudioReferencesForTesting(
            recordingID: outsideID, audioFilePath: outsideURL.path, segmentsDirectory: nil
        ))

        let outcome = try StorageLocationManager.migrateFiles(from: rootA, to: rootB)
        let relocated = try await store.relocateAudioReferences(
            copies: outcome.copiedPairs, from: rootA, to: rootB
        )
        await store.setAudioRootForTesting(rootB)

        #expect(relocated == 1)
        let relative = try #require(await store.fetchRecordingDetail(recordingID: relativeID))
        #expect(relative.audioFile == .relative("follows-root.m4a"))
        let movedLegacy = try #require(await store.fetchRecordingDetail(recordingID: movedLegacyID))
        #expect(movedLegacy.audioFile == .relative("legacy-moved.m4a"))
        let outside = try #require(await store.fetchRecordingDetail(recordingID: outsideID))
        #expect(outside.audioFile == .legacyAbsolute(outsideURL.path))

        let resolved = try await store.fetchAudioPaths(
            recordingIDs: [relativeID, movedLegacyID, outsideID]
        )
        for id in [relativeID, movedLegacyID] {
            let url = try #require(resolved[id])
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
        #expect(resolved[outsideID]?.path == outsideURL.path)
    }

    /// Relocation only trusts the explicit copy mapping: a same-subpath
    /// file that already existed at the destination (not copied by this
    /// migration) never causes a rewrite, and neither does a row whose file
    /// was not part of the copy set.
    @Test func relocationIgnoresRowsOutsideTheCopyMapping() async throws {
        let rootA = try makeTempDir()
        let rootB = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: rootA)
            try? FileManager.default.removeItem(at: rootB)
        }
        let store = try await makeStore(root: rootA)
        await store.setAudioRootForTesting(rootA)

        // Row whose file is missing (nothing to copy) but whose subpath
        // exists at the destination for unrelated reasons.
        let preExistingID = UUID()
        try touch(rootB.appendingPathComponent("pre-existing.m4a"))
        #expect(await store.createRecording(
            id: preExistingID, title: "PreExisting", startDate: .now, segmentsDirURL: nil
        ))
        #expect(await store.setRawAudioReferencesForTesting(
            recordingID: preExistingID,
            audioFilePath: rootA.appendingPathComponent("pre-existing.m4a").path,
            segmentsDirectory: nil
        ))

        // Row whose file has a non-audio extension — the migration does not
        // copy it, so the row must stay legacy.
        let skippedID = UUID()
        let skippedURL = rootA.appendingPathComponent("notes.txt")
        try touch(skippedURL)
        #expect(await store.createRecording(
            id: skippedID, title: "Skipped", startDate: .now, segmentsDirURL: nil
        ))
        #expect(await store.setRawAudioReferencesForTesting(
            recordingID: skippedID, audioFilePath: skippedURL.path, segmentsDirectory: nil
        ))

        let outcome = try StorageLocationManager.migrateFiles(from: rootA, to: rootB)
        let relocated = try await store.relocateAudioReferences(
            copies: outcome.copiedPairs, from: rootA, to: rootB
        )

        #expect(relocated == 0)
        #expect(try #require(await store.fetchRecordingDetail(recordingID: preExistingID)).audioFile
            == .legacyAbsolute(rootA.appendingPathComponent("pre-existing.m4a").path))
        #expect(try #require(await store.fetchRecordingDetail(recordingID: skippedID)).audioFile
            == .legacyAbsolute(skippedURL.path))
    }

    @Test func relocationSaveFailureRollsBackEveryRow() async throws {
        let rootA = try makeTempDir()
        let rootB = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: rootA)
            try? FileManager.default.removeItem(at: rootB)
        }
        let store = try await makeStore(root: rootA)
        await store.setAudioRootForTesting(rootA)

        let id = UUID()
        let audio = rootA.appendingPathComponent("moved.m4a")
        try touch(audio)
        #expect(await store.createRecording(id: id, title: "L", startDate: .now, segmentsDirURL: nil))
        #expect(await store.setRawAudioReferencesForTesting(
            recordingID: id, audioFilePath: audio.path, segmentsDirectory: nil
        ))
        let outcome = try StorageLocationManager.migrateFiles(from: rootA, to: rootB)

        await store.failNextSaveForTesting()
        await #expect(throws: (any Error).self) {
            try await store.relocateAudioReferences(
                copies: outcome.copiedPairs, from: rootA, to: rootB
            )
        }
        #expect(try #require(await store.fetchRecordingDetail(recordingID: id)).audioFile
            == .legacyAbsolute(audio.path))
    }

    /// Exact case: the copies list holds only the whole segments tree, and
    /// a legacy segments row points at a leaf symlink inside that tree
    /// whose target lies outside the root. Coverage is lexical, so the row
    /// falls inside the copied tree; canonical resolution of the rewrite
    /// fails — the relocation must throw (aborting the migration before
    /// source cleanup), never skip the row.
    @Test func relocationThrowsForCoveredRowWhoseResolutionFails() async throws {
        let rootA = try makeTempDir()
        let rootB = try makeTempDir()
        let outside = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: rootA)
            try? FileManager.default.removeItem(at: rootB)
            try? FileManager.default.removeItem(at: outside)
        }
        let store = try await makeStore(root: rootA)
        await store.setAudioRootForTesting(rootA)

        let segments = rootA.appendingPathComponent("segments", isDirectory: true)
        try FileManager.default.createDirectory(at: segments, withIntermediateDirectories: true)
        try touch(segments.appendingPathComponent("REAL/seg0.m4a"))
        try FileManager.default.createSymbolicLink(
            at: segments.appendingPathComponent("LINK"),
            withDestinationURL: outside
        )

        let id = UUID()
        #expect(await store.createRecording(id: id, title: "Linked", startDate: .now, segmentsDirURL: nil))
        #expect(await store.setRawAudioReferencesForTesting(
            recordingID: id,
            audioFilePath: nil,
            segmentsDirectory: segments.appendingPathComponent("LINK").path
        ))

        let outcome = try StorageLocationManager.migrateFiles(from: rootA, to: rootB)
        await #expect(throws: (any Error).self) {
            try await store.relocateAudioReferences(
                copies: outcome.copiedPairs, from: rootA, to: rootB
            )
        }
        // The row is untouched — the migration flow discards its copies and
        // keeps the old root, so nothing dangles.
        #expect(try #require(await store.fetchRecordingDetail(recordingID: id)).audioFile == nil)
        let raw = try #require(await store.fetchArchiveDetailBundle(recordingID: id))
        #expect(raw.segmentsDirectory == .legacyAbsolute(segments.appendingPathComponent("LINK").path))
    }

    // MARK: - Symlink identity (lexical, never the resolved target)

    /// Importing a symlink stores the link as the recording's identity;
    /// deleting that recording removes the link and never the shared
    /// target file.
    @Test func importingASymlinkStoresTheLinkAndDeletesOnlyTheLink() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await makeStore(root: root)
        await store.setAudioRootForTesting(root)

        let targetID = UUID()
        let targetURL = root.appendingPathComponent("target.m4a")
        try touch(targetURL)
        #expect(await store.importAudioFile(
            id: targetID, title: "Target", startDate: .now, duration: 60, audioURL: targetURL, ownership: .appCreated))

        let aliasID = UUID()
        let aliasURL = root.appendingPathComponent("alias.m4a")
        try FileManager.default.createSymbolicLink(at: aliasURL, withDestinationURL: targetURL)
        #expect(await store.importAudioFile(
            id: aliasID, title: "Alias", startDate: .now, duration: 60, audioURL: aliasURL, ownership: .appCreated))
        let alias = try #require(await store.fetchRecordingDetail(recordingID: aliasID))
        #expect(alias.audioFile == .relative("alias.m4a"))

        #expect(await store.deleteRecording(recordingID: aliasID))
        #expect(await store.permanentlyDelete(recordingID: aliasID))
        #expect(FileManager.default.fileExists(atPath: targetURL.path))
        #expect(!FileManager.default.fileExists(atPath: aliasURL.path))
    }

    /// A stored relative row whose file is later replaced by a symlink to
    /// another recording's file: deletion removes the link only.
    @Test func replacingStoredFileWithSymlinkNeverDeletesTheTarget() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await makeStore(root: root)
        await store.setAudioRootForTesting(root)

        let victimID = UUID()
        let victimURL = root.appendingPathComponent("target.m4a")
        try touch(victimURL)
        #expect(await store.importAudioFile(
            id: victimID, title: "Victim", startDate: .now, duration: 60, audioURL: victimURL, ownership: .appCreated))

        let aliasID = UUID()
        let aliasURL = root.appendingPathComponent("alias.m4a")
        try touch(aliasURL)
        #expect(await store.importAudioFile(
            id: aliasID, title: "Alias", startDate: .now, duration: 60, audioURL: aliasURL, ownership: .appCreated))

        // Replace the alias row's data file with a link to the victim's file.
        try FileManager.default.removeItem(at: aliasURL)
        try FileManager.default.createSymbolicLink(at: aliasURL, withDestinationURL: victimURL)

        #expect(await store.deleteRecording(recordingID: aliasID))
        #expect(await store.permanentlyDelete(recordingID: aliasID))
        #expect(FileManager.default.fileExists(atPath: victimURL.path))
        #expect(!FileManager.default.fileExists(atPath: aliasURL.path))
    }

    /// Migration abort must cover the whole mutation span: the first row
    /// already rewrote when the second throws, and a later unrelated save
    /// must not persist the half-batch.
    @Test func relocationAbortRollsBackEarlierRewrites() async throws {
        let rootA = try makeTempDir()
        let rootB = try makeTempDir()
        let outside = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: rootA)
            try? FileManager.default.removeItem(at: rootB)
            try? FileManager.default.removeItem(at: outside)
        }
        let store = try await makeStore(root: rootA)
        await store.setAudioRootForTesting(rootA)

        // First (earlier startDate): a legacy row that relocates cleanly.
        let earlyID = UUID()
        let earlyAudio = rootA.appendingPathComponent("early.m4a")
        try touch(earlyAudio)
        #expect(await store.createRecording(
            id: earlyID, title: "Early", startDate: Date(timeIntervalSince1970: 100), segmentsDirURL: nil
        ))
        #expect(await store.setRawAudioReferencesForTesting(
            recordingID: earlyID, audioFilePath: earlyAudio.path, segmentsDirectory: nil
        ))

        // Second (later startDate): covered by the segments tree but its
        // canonical resolution escapes — relocation must throw after the
        // first row already mutated.
        let segments = rootA.appendingPathComponent("segments", isDirectory: true)
        try FileManager.default.createDirectory(at: segments, withIntermediateDirectories: true)
        try touch(segments.appendingPathComponent("REAL/seg0.m4a"))
        try FileManager.default.createSymbolicLink(
            at: segments.appendingPathComponent("LINK"), withDestinationURL: outside
        )
        let lateID = UUID()
        #expect(await store.createRecording(
            id: lateID, title: "Late", startDate: Date(timeIntervalSince1970: 200), segmentsDirURL: nil
        ))
        #expect(await store.setRawAudioReferencesForTesting(
            recordingID: lateID, audioFilePath: nil,
            segmentsDirectory: segments.appendingPathComponent("LINK").path
        ))

        let outcome = try StorageLocationManager.migrateFiles(from: rootA, to: rootB)
        await #expect(throws: (any Error).self) {
            try await store.relocateAudioReferences(
                copies: outcome.copiedPairs, from: rootA, to: rootB
            )
        }
        // An unrelated save afterwards must not persist the aborted batch.
        #expect(await store.updateTitle(recordingID: earlyID, title: "Early renamed"))
        #expect(try #require(await store.fetchRecordingDetail(recordingID: earlyID)).audioFile
            == .legacyAbsolute(earlyAudio.path))
        let lateRaw = try #require(await store.fetchArchiveDetailBundle(recordingID: lateID))
        #expect(lateRaw.segmentsDirectory
            == .legacyAbsolute(segments.appendingPathComponent("LINK").path))
    }

    /// A healthy relative row whose file is an absolute symlink would
    /// dangle once the old tree is cleaned up — the migration must abort
    /// with rows and source files intact. A relative-destination symlink is
    /// portable and passes.
    @Test func migrationAbortsWhenAbsoluteSymlinkWouldDangleAfterCleanup() async throws {
        let rootA = try makeTempDir()
        let rootB = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: rootA)
            try? FileManager.default.removeItem(at: rootB)
        }
        let store = try await makeStore(root: rootA)
        await store.setAudioRootForTesting(rootA)

        let realID = UUID()
        let realURL = rootA.appendingPathComponent("real.m4a")
        try touch(realURL)
        #expect(await store.importAudioFile(
            id: realID, title: "Real", startDate: .now, duration: 60, audioURL: realURL, ownership: .appCreated))
        let aliasID = UUID()
        let aliasURL = rootA.appendingPathComponent("alias.m4a")
        try FileManager.default.createSymbolicLink(at: aliasURL, withDestinationURL: realURL)
        #expect(await store.createRecording(
            id: aliasID, title: "Alias", startDate: .now, segmentsDirURL: nil
        ))
        #expect(await store.setRawAudioReferencesForTesting(
            recordingID: aliasID, audioFilePath: "alias.m4a", segmentsDirectory: nil
        ))

        let outcome = try StorageLocationManager.migrateFiles(from: rootA, to: rootB)
        await #expect(throws: (any Error).self) {
            try await store.relocateAudioReferences(
                copies: outcome.copiedPairs, from: rootA, to: rootB
            )
        }
        // Rows and old-root files are intact; the flow keeps the old root.
        #expect(try #require(await store.fetchRecordingDetail(recordingID: aliasID)).audioFile
            == .relative("alias.m4a"))
        #expect(FileManager.default.fileExists(atPath: realURL.path))
        let resolved = try #require(await store.fetchAudioPaths(recordingIDs: [aliasID])[aliasID])
        #expect(FileManager.default.fileExists(atPath: resolved.path))
    }

    @Test func relativeSymlinkSurvivesMigration() async throws {
        let rootA = try makeTempDir()
        let rootB = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: rootA)
            try? FileManager.default.removeItem(at: rootB)
        }
        let store = try await makeStore(root: rootA)
        await store.setAudioRootForTesting(rootA)

        let realID = UUID()
        let realURL = rootA.appendingPathComponent("real.m4a")
        try touch(realURL)
        #expect(await store.importAudioFile(
            id: realID, title: "Real", startDate: .now, duration: 60, audioURL: realURL, ownership: .appCreated))
        let aliasID = UUID()
        try FileManager.default.createSymbolicLink(
            atPath: rootA.appendingPathComponent("alias.m4a").path,
            withDestinationPath: "real.m4a"
        )
        #expect(await store.createRecording(
            id: aliasID, title: "Alias", startDate: .now, segmentsDirURL: nil
        ))
        #expect(await store.setRawAudioReferencesForTesting(
            recordingID: aliasID, audioFilePath: "alias.m4a", segmentsDirectory: nil
        ))

        let outcome = try StorageLocationManager.migrateFiles(from: rootA, to: rootB)
        let relocated = try await store.relocateAudioReferences(
            copies: outcome.copiedPairs, from: rootA, to: rootB
        )
        #expect(relocated == 0) // both rows are already relative
        await store.setAudioRootForTesting(rootB)
        let resolved = try await store.fetchAudioPaths(recordingIDs: [realID, aliasID])
        for id in [realID, aliasID] {
            let url = try #require(resolved[id])
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }

    // MARK: - Split-root pin

    @Test func pinConvertsRelativeRowsAndCountsLegacy() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await makeStore(root: root)
        await store.setAudioRootForTesting(root)

        let id = UUID()
        let url = root.appendingPathComponent("stays-behind.m4a")
        try touch(url)
        #expect(await store.importAudioFile(
            id: id, title: "Pinned", startDate: .now, duration: 60, audioURL: url, ownership: .appCreated))
        #expect(await store.countLegacyAudioReferences() == 0)

        let pinned = try await store.pinRelativeReferencesToAbsolute(root: root)
        #expect(pinned == 1)
        let detail = try #require(await store.fetchRecordingDetail(recordingID: id))
        let reference = try #require(detail.audioFile)
        #expect(reference.isLegacy)
        #expect(reference.storageValue.hasSuffix("/stays-behind.m4a"))
        #expect(await store.countLegacyAudioReferences() == 1)

        // Idempotent: a second pin finds nothing relative to convert.
        #expect(try await store.pinRelativeReferencesToAbsolute(root: root) == 0)
    }

    /// The pin is all-or-nothing: a save failure rolls back and throws, so
    /// the caller keeps the old root and no row is left half-pinned.
    @Test func pinSaveFailureRollsBackAndThrows() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await makeStore(root: root)
        await store.setAudioRootForTesting(root)

        let id = UUID()
        let url = root.appendingPathComponent("pin-me.m4a")
        try touch(url)
        #expect(await store.importAudioFile(
            id: id, title: "Pin", startDate: .now, duration: 60, audioURL: url, ownership: .appCreated))

        await store.failNextSaveForTesting()
        await #expect(throws: (any Error).self) {
            try await store.pinRelativeReferencesToAbsolute(root: root)
        }
        let detail = try #require(await store.fetchRecordingDetail(recordingID: id))
        #expect(detail.audioFile == .relative("pin-me.m4a"))
    }

    /// Pin is all-or-nothing across rows: a row whose relative reference
    /// cannot resolve aborts the whole pin after earlier rows already
    /// mutated, and an unrelated save afterwards persists none of it.
    @Test func pinAbortsWhollyWhenAnyRowIsUnresolvable() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await makeStore(root: root)
        await store.setAudioRootForTesting(root)

        let earlyID = UUID()
        let earlyURL = root.appendingPathComponent("early.m4a")
        try touch(earlyURL)
        #expect(await store.importAudioFile(
            id: earlyID, title: "Early", startDate: Date(timeIntervalSince1970: 100),
            duration: 60, audioURL: earlyURL, ownership: .appCreated))
        let badID = UUID()
        #expect(await store.createRecording(
            id: badID, title: "Bad", startDate: Date(timeIntervalSince1970: 200), segmentsDirURL: nil
        ))
        #expect(await store.setRawAudioReferencesForTesting(
            recordingID: badID, audioFilePath: "../escape.m4a", segmentsDirectory: nil
        ))

        await #expect(throws: (any Error).self) {
            try await store.pinRelativeReferencesToAbsolute(root: root)
        }
        #expect(await store.updateTitle(recordingID: earlyID, title: "Early renamed"))
        #expect(try #require(await store.fetchRecordingDetail(recordingID: earlyID)).audioFile
            == .relative("early.m4a"))
        #expect(try #require(await store.fetchRecordingDetail(recordingID: badID)).audioFile
            == .relative("../escape.m4a"))
    }
}
