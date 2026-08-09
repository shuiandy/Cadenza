import Foundation
import Testing

@testable import Cadenza

/// Player reload is decided by the resolved URL, not the reference value:
/// a directory migration keeps the relative reference while the file moves
/// roots, and the player must follow.
@Suite("Recording Detail Player Reload")
struct RecordingDetailPlayerReloadTests {

    @Test func reloadFollowsResolvedURLNotReferenceEquality() throws {
        let rootA = FileManager.default.temporaryDirectory
            .appendingPathComponent("player-A-\(UUID().uuidString)", isDirectory: true)
        let rootB = FileManager.default.temporaryDirectory
            .appendingPathComponent("player-B-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rootB, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: rootA)
            try? FileManager.default.removeItem(at: rootB)
        }
        let reference = AudioFileReference.relative("audio.m4a")
        let underA = try ProfileStorageResolver(root: rootA).resolveAudio(reference)
        let underB = try ProfileStorageResolver(root: rootB).resolveAudio(reference)

        // First load.
        #expect(RecordingDetailView.playerNeedsReload(loaded: nil, resolved: underA))
        // Same reference, same root: no reload.
        #expect(!RecordingDetailView.playerNeedsReload(loaded: underA, resolved: underA))
        // Same reference, migrated root: the resolved URL changed — reload.
        #expect(RecordingDetailView.playerNeedsReload(loaded: underA, resolved: underB))
        // Unresolvable: keep whatever is loaded.
        #expect(!RecordingDetailView.playerNeedsReload(loaded: underA, resolved: nil))
    }
}
