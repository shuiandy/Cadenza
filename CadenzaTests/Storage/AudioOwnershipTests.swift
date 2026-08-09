import Foundation
import SwiftData
import Testing

@testable import Cadenza

/// INV-18 write rules and the copy-on-write switch: finalization is the
/// only provenance the app asserts; imports record what actually happened;
/// nil and unrecognized column values degrade to `unknownLegacy`; and
/// `replaceAudioFile` swaps the row atomically without ever touching the
/// original file's bytes.
@Suite("Audio Ownership")
struct AudioOwnershipTests {

    @MainActor
    private func makeStore() throws -> RecordingsStore {
        let container = try ModelContainer(
            for: RecordingsStore.schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return RecordingsStore(modelContainer: container)
    }

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ownership-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func touch(_ url: URL, contents: String = "x") throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
    }

    @Test @MainActor
    func finalizationMarksAppCreated() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try makeStore()
        await store.setAudioRootForTesting(root)

        let id = UUID()
        #expect(await store.createRecording(
            id: id, title: "Live", startDate: .now, segmentsDirURL: nil
        ))
        #expect(await store.audioOwnership(recordingID: id) == .unknownLegacy)

        let audioURL = root.appendingPathComponent("live.m4a")
        try touch(audioURL)
        #expect(await store.finalizeRecording(
            id: id, duration: 120, audioFileURL: audioURL
        ) == .saved)
        #expect(await store.audioOwnership(recordingID: id) == .appCreated)
    }

    @Test @MainActor
    func importRecordsDeclaredOwnership() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try makeStore()
        await store.setAudioRootForTesting(root)

        let copiedID = UUID()
        let copiedURL = root.appendingPathComponent("copied.m4a")
        try touch(copiedURL)
        #expect(await store.importAudioFile(
            id: copiedID, title: "Copied", startDate: .now, duration: 60,
            audioURL: copiedURL, ownership: .appCreated
        ))
        #expect(await store.audioOwnership(recordingID: copiedID) == .appCreated)

        let reusedID = UUID()
        let reusedURL = root.appendingPathComponent("reused.m4a")
        try touch(reusedURL)
        #expect(await store.importAudioFile(
            id: reusedID, title: "Reused", startDate: .now, duration: 60,
            audioURL: reusedURL, ownership: .unknownLegacy
        ))
        #expect(await store.audioOwnership(recordingID: reusedID) == .unknownLegacy)
    }

    /// Pre-column rows (nil) and unrecognized future values must both read
    /// as `unknownLegacy` — deletion-adjacent code never assumes ownership
    /// it cannot prove.
    @Test func defensiveOwnershipDecoding() {
        let recording = Recording(id: UUID(), title: "Legacy")
        #expect(recording.audioFileOwnership == nil)
        #expect(recording.ownership == .unknownLegacy)
        recording.audioFileOwnership = "somethingFromTheFuture"
        #expect(recording.ownership == .unknownLegacy)
        recording.ownership = .userOwned
        #expect(recording.audioFileOwnership == "userOwned")
    }

    @Test @MainActor
    func replaceAudioFileSwitchesRowAndPreservesOriginalBytes() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try makeStore()
        await store.setAudioRootForTesting(root)

        // A user-provided original outside the root, referenced legacy.
        let outside = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: outside) }
        let originalURL = outside.appendingPathComponent("original.m4a")
        try touch(originalURL, contents: "original-bytes")
        let id = UUID()
        #expect(await store.createRecording(
            id: id, title: "UserFile", startDate: .now, segmentsDirURL: nil
        ))
        _ = await store.setRawAudioReferencesForTesting(
            recordingID: id, audioFilePath: originalURL.path, segmentsDirectory: nil
        )

        let compressedURL = root.appendingPathComponent("compressed.m4a")
        try touch(compressedURL, contents: "compressed-bytes")
        #expect(await store.replaceAudioFile(
            recordingID: id, newURL: compressedURL, ownership: .appCreated
        ))

        let detail = try #require(await store.fetchRecordingDetail(recordingID: id))
        #expect(detail.audioFile == .relative("compressed.m4a"))
        #expect(await store.audioOwnership(recordingID: id) == .appCreated)
        // Original bytes untouched at the original location.
        #expect(try String(decoding: Data(contentsOf: originalURL), as: UTF8.self)
            == "original-bytes")
    }

    /// An out-of-root replacement target is a contract violation: the row
    /// must stay unchanged.
    @Test @MainActor
    func replaceAudioFileRejectsOutOfRootTargets() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try makeStore()
        await store.setAudioRootForTesting(root)

        let id = UUID()
        let audioURL = root.appendingPathComponent("in-root.m4a")
        try touch(audioURL)
        #expect(await store.importAudioFile(
            id: id, title: "InRoot", startDate: .now, duration: 60,
            audioURL: audioURL, ownership: .unknownLegacy
        ))

        let outside = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: outside) }
        #expect(await store.replaceAudioFile(
            recordingID: id,
            newURL: outside.appendingPathComponent("elsewhere.m4a"),
            ownership: .appCreated
        ) == false)
        let detail = try #require(await store.fetchRecordingDetail(recordingID: id))
        #expect(detail.audioFile == .relative("in-root.m4a"))
        #expect(await store.audioOwnership(recordingID: id) == .unknownLegacy)
    }
}
