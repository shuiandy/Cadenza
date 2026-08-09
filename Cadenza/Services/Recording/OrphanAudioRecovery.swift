import AVFoundation
import Foundation

/// Production orphan scan, shared by the boot recovery pass and its
/// tests: untracked audio files in the storage root become recordings.
/// Recovery cannot prove who wrote a file — the user may have dropped
/// personal audio into the storage directory — so every imported row is
/// `unknownLegacy`, never app-owned. Files too short to transcribe
/// usefully are skipped.
enum OrphanAudioRecovery {
    static let minimumDuration: TimeInterval = 30
    static let audioExtensions: Set<String> = ["m4a", "mp3", "wav", "caf", "aac"]

    /// Returns the number of recovered recordings.
    @discardableResult
    static func run(storageRoot: URL, store: RecordingsStore) async -> Int {
        guard FileManager.default.fileExists(atPath: storageRoot.path) else { return 0 }
        let trackedPaths: Set<String>
        do {
            trackedPaths = try await store.allTrackedAudioPaths()
        } catch {
            // An unknown catalogue is not an empty catalogue. Scanning in this
            // state could re-import every tracked file as a duplicate.
            NSLog(
                "[OrphanAudioRecovery] tracked audio fetch failed; scan skipped: %@",
                error.localizedDescription
            )
            return 0
        }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: storageRoot, includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let audioFiles = contents.filter { url in
            // Tracked paths are resolver-canonical; compare both spellings so
            // a symlinked storage root never re-imports tracked files.
            audioExtensions.contains(url.pathExtension.lowercased())
                && !trackedPaths.contains(url.path)
                && !trackedPaths.contains(url.resolvingSymlinksInPath().path)
        }
        guard !audioFiles.isEmpty else { return 0 }
        NSLog("[OrphanAudioRecovery] found %d orphaned audio file(s), recovering...", audioFiles.count)

        var recovered = 0
        for url in audioFiles {
            let filename = url.lastPathComponent
            let title = url.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "recording_", with: "")
                .replacingOccurrences(of: "_", with: " ")

            let asset = AVURLAsset(url: url)
            let duration = (try? await asset.load(.duration).seconds) ?? 0
            guard duration >= minimumDuration else { continue }

            let startDate = RecordingFilenameDateParser.parse(filename)
                ?? (try? FileManager.default.attributesOfItem(atPath: url.path)[.creationDate] as? Date)
                ?? Date()

            let saved = await store.importAudioFile(
                id: UUID(), title: title, startDate: startDate,
                duration: duration, audioURL: url, ownership: .unknownLegacy
            )
            if saved { recovered += 1 }
        }
        return recovered
    }
}
