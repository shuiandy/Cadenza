import Foundation
@testable import Cadenza

/// CI-only restore validator (spec §12.2 / plan Task 6).
///
/// Not a product importer: it proves the archive FORMAT is restorable —
/// manifest hashes match the files on disk, no unlisted files exist, every
/// entity decodes, counts agree — and, via `ArchiveNormalizer`, that the
/// relationship graph in the archive matches the source store. The product
/// importer (Phase 5) will replace the "rebuild" half; until then the
/// archive is named Portable, not Restorable.

struct ValidatedArchive {
    var manifest: PortableArchiveManifest
    var recordings: [ArchiveRecording]
    var transcripts: [ArchiveTranscript]
    var summaries: [ArchiveSummary]
    var folders: [ArchiveFolder]
    var tags: [String]
    var recaps: [ArchiveRecap]
    var artifacts: [ArchiveAgentArtifact]
    var speakerProfiles: [ArchiveSpeakerProfile]
    var voiceSamples: [ArchiveVoiceSample]
}

enum ArchiveValidationError: Error, CustomStringConvertible {
    case missingFile(String)
    case sizeMismatch(String)
    case hashMismatch(String)
    case unlistedFile(String)
    case countMismatch(entity: String, manifest: Int, actual: Int)
    case danglingReference(String)

    var description: String {
        switch self {
        case .missingFile(let path): return "missing file: \(path)"
        case .sizeMismatch(let path): return "size mismatch: \(path)"
        case .hashMismatch(let path): return "hash mismatch: \(path)"
        case .unlistedFile(let path): return "file on disk but not in manifest: \(path)"
        case .countMismatch(let entity, let manifest, let actual):
            return "count mismatch for \(entity): manifest=\(manifest) actual=\(actual)"
        case .danglingReference(let detail): return "dangling reference: \(detail)"
        }
    }
}

enum PortableArchiveValidator {

    static func validate(at archiveURL: URL) throws -> ValidatedArchive {
        let decoder = PortableArchiveSchema.makeDecoder()
        let manifest = try decoder.decode(
            PortableArchiveManifest.self,
            from: Data(contentsOf: archiveURL.appendingPathComponent("manifest.json"))
        )

        // 1. Every manifest entry exists with matching size + hash.
        let fm = FileManager.default
        for entry in manifest.files {
            let url = archiveURL.appendingPathComponent(entry.path)
            guard fm.fileExists(atPath: url.path) else {
                throw ArchiveValidationError.missingFile(entry.path)
            }
            let size = (try fm.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? -1
            guard size == entry.size else { throw ArchiveValidationError.sizeMismatch(entry.path) }
            guard try PortableArchiveWriter.sha256OfFile(at: url) == entry.sha256 else {
                throw ArchiveValidationError.hashMismatch(entry.path)
            }
        }

        // 2. No files on disk that the manifest doesn't list. Walked with an
        //    INDEPENDENT FileManager.enumerator — reusing the writer's
        //    hashAllFiles here would be circular: anything its traversal
        //    skips could never be detected.
        let listed = Set(manifest.files.map(\.path))
        let onDisk = try Self.independentFileWalk(root: archiveURL)
            .filter { $0 != "manifest.json" }
        for path in onDisk where !listed.contains(path) {
            throw ArchiveValidationError.unlistedFile(path)
        }

        // 3. Decode entities.
        func decodeEntity<T: Decodable>(_ type: T.Type, _ filename: String) throws -> T {
            try decoder.decode(
                T.self,
                from: Data(contentsOf: archiveURL.appendingPathComponent("entities/\(filename)"))
            )
        }
        let archive = ValidatedArchive(
            manifest: manifest,
            recordings: try decodeEntity([ArchiveRecording].self, "recordings.json"),
            transcripts: try decodeEntity([ArchiveTranscript].self, "transcripts.json"),
            summaries: try decodeEntity([ArchiveSummary].self, "summaries.json"),
            folders: try decodeEntity([ArchiveFolder].self, "folders.json"),
            tags: try decodeEntity([String].self, "tags.json"),
            recaps: try decodeEntity([ArchiveRecap].self, "recaps.json"),
            artifacts: try decodeEntity([ArchiveAgentArtifact].self, "agent-artifacts.json"),
            speakerProfiles: try decodeEntity([ArchiveSpeakerProfile].self, "speaker-profiles.json"),
            voiceSamples: manifest.includesVoiceEmbeddings
                ? try decodeEntity([ArchiveVoiceSample].self, "embeddings.json")
                : []
        )

        // 4. Counts agree with the manifest.
        let actualCounts = [
            "recordings": archive.recordings.count,
            "transcripts": archive.transcripts.count,
            "summaries": archive.summaries.count,
            "folders": archive.folders.count,
            "tags": archive.tags.count,
            "recaps": archive.recaps.count,
            "agentArtifacts": archive.artifacts.count,
            "speakerProfiles": archive.speakerProfiles.count,
            "voiceSamples": archive.voiceSamples.count,
        ]
        for (entity, actual) in actualCounts {
            let expected = manifest.counts[entity] ?? -1
            guard expected == actual else {
                throw ArchiveValidationError.countMismatch(entity: entity, manifest: expected, actual: actual)
            }
        }

        // 5. Referential integrity + payload presence.
        //    （Recap.recordingIDs 刻意不校验：历史性引用，录音先删是合法状态。）
        let recordingIDs = Set(archive.recordings.map(\.id))
        for transcript in archive.transcripts where !recordingIDs.contains(transcript.recordingID) {
            throw ArchiveValidationError.danglingReference("transcript → \(transcript.recordingID)")
        }
        for summary in archive.summaries where !recordingIDs.contains(summary.recordingID) {
            throw ArchiveValidationError.danglingReference("summary → \(summary.recordingID)")
        }
        let profileIDs = Set(archive.speakerProfiles.map(\.id))
        for recording in archive.recordings {
            for mapping in recording.speakerMappings where !profileIDs.contains(mapping.profileID) {
                throw ArchiveValidationError.danglingReference(
                    "recording \(recording.id) mapping '\(mapping.rawLabel)' → profile \(mapping.profileID)"
                )
            }
        }
        for sample in archive.voiceSamples {
            if !recordingIDs.contains(sample.recordingID) {
                throw ArchiveValidationError.danglingReference("voice sample → recording \(sample.recordingID)")
            }
            if let profileID = sample.profileID, !profileIDs.contains(profileID) {
                throw ArchiveValidationError.danglingReference("voice sample → profile \(profileID)")
            }
        }
        let folderIDs = Set(archive.folders.map(\.id))
        for recording in archive.recordings {
            if let folderID = recording.folderID, !folderIDs.contains(folderID) {
                throw ArchiveValidationError.danglingReference("recording \(recording.id) → folder \(folderID)")
            }
            if recording.hasAudio, !listed.contains("audio/\(recording.id.uuidString).m4a") {
                throw ArchiveValidationError.danglingReference("recording \(recording.id) hasAudio but no audio file")
            }
            if recording.hasUnmergedSegments,
               !listed.contains(where: { $0.hasPrefix("segments/\(recording.id.uuidString)/") }) {
                throw ArchiveValidationError.danglingReference("recording \(recording.id) hasUnmergedSegments but no segment files")
            }
        }
        return archive
    }

    private static func independentFileWalk(root: URL) throws -> [String] {
        var paths: [String] = []
        let rootPath = root.standardizedFileURL.path
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [] }
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let full = url.standardizedFileURL.path
            guard full.hasPrefix(rootPath + "/") else { continue }
            paths.append(String(full.dropFirst(rootPath.count + 1)))
        }
        return paths
    }
}

// MARK: - Normalizer

/// Canonical per-recording tuple, built INDEPENDENTLY from the live store and
/// from decoded archive entities. The archive side joins entities by
/// recordingID itself — a transcript/summary attached to the wrong recording
/// in the archive shows up as a mismatch here even when counts and hashes
/// are all green.
struct NormalizedRecording: Equatable {
    var id: UUID
    var title: String
    var startDate: Date
    var duration: TimeInterval
    var tags: [String]
    var folderPath: [String]
    var isTrashed: Bool
    var transcriptFullText: String?
    var transcriptSegments: [String]
    var summaryOverview: String?
    var actionItems: [String]
    var speakerMappings: [String]
    var hasAudio: Bool
    var hasUnmergedSegments: Bool
    var audioOwnership: String?
}

enum ArchiveNormalizer {

    static func fromStore(_ store: RecordingsStore) async throws -> [NormalizedRecording] {
        let folders = await store.fetchFolders()
        var result: [NormalizedRecording] = []
        for id in try await store.fetchArchiveRecordingIDs() {
            guard let record = try await store.fetchArchiveRecording(recordingID: id) else { continue }
            let detail = record.detail
            let audioExists = record.audioFileURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            let segmentsExist = detail.audioFile == nil
                && (record.audioSegmentsDirectoryURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false)
            result.append(NormalizedRecording(
                id: detail.id,
                title: detail.title,
                startDate: detail.startDate,
                duration: detail.duration,
                tags: detail.tags.sorted(),
                folderPath: FolderPathBuilder.path(to: detail.folderID, in: folders),
                isTrashed: record.trashedDate != nil,
                transcriptFullText: detail.transcript?.fullText,
                transcriptSegments: detail.transcript?.segments.map(Self.segmentKey) ?? [],
                summaryOverview: detail.summary?.overview,
                actionItems: detail.summary?.actionItems.map(Self.actionItemKey).sorted() ?? [],
                speakerMappings: detail.speakerMappings
                    .map { "\($0.rawLabel)→\($0.profileName)" }.sorted(),
                hasAudio: audioExists,
                hasUnmergedSegments: segmentsExist,
                audioOwnership: record.audioOwnership
            ))
        }
        return result.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    static func fromArchive(_ archive: ValidatedArchive) -> [NormalizedRecording] {
        let transcriptByID = Dictionary(uniqueKeysWithValues: archive.transcripts.map { ($0.recordingID, $0) })
        let summaryByID = Dictionary(uniqueKeysWithValues: archive.summaries.map { ($0.recordingID, $0) })
        let folderByID = Dictionary(uniqueKeysWithValues: archive.folders.map { ($0.id, $0) })

        func folderPath(_ folderID: UUID?) -> [String] {
            var names: [String] = []
            var current = folderID.flatMap { folderByID[$0] }
            var visited = Set<UUID>()
            while let folder = current, visited.insert(folder.id).inserted {
                names.append(folder.name)
                current = folder.parentFolderID.flatMap { folderByID[$0] }
            }
            return names.reversed()
        }

        return archive.recordings.map { recording in
            let transcript = transcriptByID[recording.id]
            let summary = summaryByID[recording.id]
            return NormalizedRecording(
                id: recording.id,
                title: recording.title,
                startDate: recording.startDate,
                duration: recording.duration,
                tags: recording.tags.sorted(),
                folderPath: folderPath(recording.folderID),
                isTrashed: recording.trashedDate != nil,
                transcriptFullText: transcript?.fullText,
                transcriptSegments: transcript?.segments.map {
                    Self.segmentKey(startTime: $0.startTime, endTime: $0.endTime, text: $0.text, speaker: $0.speaker)
                } ?? [],
                summaryOverview: summary?.overview,
                actionItems: summary?.actionItems.map {
                    Self.actionItemKey(task: $0.task, assignee: $0.assignee, deadline: $0.deadline, isCompleted: $0.isCompleted)
                }.sorted() ?? [],
                speakerMappings: recording.speakerMappings
                    .map { "\($0.rawLabel)→\($0.profileName)" }.sorted(),
                hasAudio: recording.hasAudio,
                hasUnmergedSegments: recording.hasUnmergedSegments,
                audioOwnership: recording.audioOwnership
            )
        }
        .sorted { $0.id.uuidString < $1.id.uuidString }
    }

    // MARK: - Keys

    private static func segmentKey(_ entry: TranscriptEntryDTO) -> String {
        segmentKey(startTime: entry.startTime, endTime: entry.endTime, text: entry.text, speaker: entry.speaker)
    }

    private static func segmentKey(
        startTime: TimeInterval, endTime: TimeInterval, text: String, speaker: String?
    ) -> String {
        "\(startTime)|\(endTime)|\(speaker ?? "-")|\(text)"
    }

    private static func actionItemKey(_ item: ActionItemDTO) -> String {
        actionItemKey(task: item.task, assignee: item.assignee, deadline: item.deadline, isCompleted: item.isCompleted)
    }

    private static func actionItemKey(
        task: String, assignee: String?, deadline: String?, isCompleted: Bool
    ) -> String {
        "\(task)|\(assignee ?? "-")|\(deadline ?? "-")|\(isCompleted)"
    }
}
