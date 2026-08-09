import AVFoundation
import Foundation
import SwiftData
import Testing

@testable import Cadenza

/// Integration coverage for ownership-aware compression on real audio:
/// non-appCreated originals keep their bytes and gain a NEW appCreated
/// file with an atomically switched reference; appCreated originals are
/// replaced in place; failures clean up without leaking files or leaving
/// the row pointing at a discarded one; and a root drift between the
/// coordinator and the store fails safely.
@Suite("Audio Compression Ownership", .serialized)
struct AudioCompressionOwnershipTests {

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
            .appendingPathComponent("compression-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A real high-bitrate AAC file above the 24 kHz sample-rate threshold
    /// whose re-encode with the compressed preset is genuinely smaller:
    /// fixture seed (32 kbps) re-exported at import quality (128 kbps).
    private func writeHighRateAudio(to url: URL) async throws {
        let seed = url.deletingLastPathComponent()
            .appendingPathComponent("seed-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: seed) }
        let samples = AudioTestFixtures.sine(count: 240_000, amplitude: 0.4, sampleRate: 48_000)
        try await AudioTestFixtures.writeM4A(tracks: [samples], sampleRate: 48_000, to: seed)
        let asset = AVURLAsset(url: seed)
        let track = try #require(await asset.loadTracks(withMediaType: .audio).first)
        try await AudioExporter.exportToM4A(
            asset: asset, track: track, outputURL: url, settings: .importQuality
        )
    }

    @Test @MainActor
    func unknownLegacyOriginalIsNeverTouchedAndGainsAppCreatedCopy() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try makeStore()
        await store.setAudioRootForTesting(root)
        let coordinator = PostProcessingCoordinator(
            store: store, recordingsDirectory: root
        )

        let originalURL = root.appendingPathComponent("legacy-original.m4a")
        try await writeHighRateAudio(to: originalURL)
        let originalBytes = try Data(contentsOf: originalURL)
        let id = UUID()
        #expect(await store.importAudioFile(
            id: id, title: "Legacy", startDate: .now, duration: 60,
            audioURL: originalURL, ownership: .unknownLegacy
        ))

        await coordinator.compressAudioIfNeeded(audioURL: originalURL, recordingID: id)

        // Original bytes untouched at the original path.
        #expect(try Data(contentsOf: originalURL) == originalBytes)
        // The row switched to a NEW appCreated file inside the root.
        let detail = try #require(await store.fetchRecordingDetail(recordingID: id))
        guard case .relative(let subpath) = detail.audioFile else {
            Issue.record("expected relative reference, got \(String(describing: detail.audioFile))")
            return
        }
        #expect(subpath != "legacy-original.m4a")
        let newURL = root.appendingPathComponent(subpath)
        #expect(FileManager.default.fileExists(atPath: newURL.path))
        #expect(await store.audioOwnership(recordingID: id) == .appCreated)
    }

    @Test @MainActor
    func appCreatedOriginalIsReplacedInPlace() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try makeStore()
        await store.setAudioRootForTesting(root)
        let coordinator = PostProcessingCoordinator(
            store: store, recordingsDirectory: root
        )

        let audioURL = root.appendingPathComponent("owned.m4a")
        try await writeHighRateAudio(to: audioURL)
        let originalBytes = try Data(contentsOf: audioURL)
        let id = UUID()
        #expect(await store.importAudioFile(
            id: id, title: "Owned", startDate: .now, duration: 60,
            audioURL: audioURL, ownership: .appCreated
        ))

        await coordinator.compressAudioIfNeeded(audioURL: audioURL, recordingID: id)

        // Reference unchanged; the file at the same path was rewritten
        // (compressed output differs from the original bytes).
        let detail = try #require(await store.fetchRecordingDetail(recordingID: id))
        #expect(detail.audioFile == .relative("owned.m4a"))
        #expect(FileManager.default.fileExists(atPath: audioURL.path))
        #expect(try Data(contentsOf: audioURL) != originalBytes)
        #expect(await store.audioOwnership(recordingID: id) == .appCreated)
        // No stray compressed_* leftovers.
        let strays = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix("compressed_") }
        #expect(strays.isEmpty)
    }

    /// A failed store switch (injected save failure) leaves the row on the
    /// original file and ownership, and removes the new file.
    @Test @MainActor
    func failedReferenceSwitchRollsBackAndCleansUp() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try makeStore()
        await store.setAudioRootForTesting(root)
        let coordinator = PostProcessingCoordinator(
            store: store, recordingsDirectory: root
        )

        let originalURL = root.appendingPathComponent("rollback-original.m4a")
        try await writeHighRateAudio(to: originalURL)
        let originalBytes = try Data(contentsOf: originalURL)
        let id = UUID()
        #expect(await store.importAudioFile(
            id: id, title: "Rollback", startDate: .now, duration: 60,
            audioURL: originalURL, ownership: .unknownLegacy
        ))

        await store._test_failNextSave()
        await coordinator.compressAudioIfNeeded(audioURL: originalURL, recordingID: id)

        #expect(try Data(contentsOf: originalURL) == originalBytes)
        let detail = try #require(await store.fetchRecordingDetail(recordingID: id))
        #expect(detail.audioFile == .relative("rollback-original.m4a"))
        #expect(await store.audioOwnership(recordingID: id) == .unknownLegacy)
        let strays = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix("compressed_") }
        #expect(strays.isEmpty)
    }

    /// Root drift between the coordinator's output root and the store's
    /// resolver root: the reference is rejected, the row is unchanged, and
    /// the drifted output file is removed.
    @Test @MainActor
    func rootDriftFailsSafelyWithoutRowChangeOrLeak() async throws {
        let storeRoot = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: storeRoot) }
        let driftedRoot = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: driftedRoot) }
        let store = try makeStore()
        await store.setAudioRootForTesting(storeRoot)
        let coordinator = PostProcessingCoordinator(
            store: store, recordingsDirectory: driftedRoot
        )

        let originalURL = storeRoot.appendingPathComponent("drift-original.m4a")
        try await writeHighRateAudio(to: originalURL)
        let originalBytes = try Data(contentsOf: originalURL)
        let id = UUID()
        #expect(await store.importAudioFile(
            id: id, title: "Drift", startDate: .now, duration: 60,
            audioURL: originalURL, ownership: .unknownLegacy
        ))

        await coordinator.compressAudioIfNeeded(audioURL: originalURL, recordingID: id)

        #expect(try Data(contentsOf: originalURL) == originalBytes)
        let detail = try #require(await store.fetchRecordingDetail(recordingID: id))
        #expect(detail.audioFile == .relative("drift-original.m4a"))
        #expect(await store.audioOwnership(recordingID: id) == .unknownLegacy)
        let strays = try FileManager.default.contentsOfDirectory(atPath: driftedRoot.path)
            .filter { $0.hasPrefix("compressed_") }
        #expect(strays.isEmpty)
    }
}
