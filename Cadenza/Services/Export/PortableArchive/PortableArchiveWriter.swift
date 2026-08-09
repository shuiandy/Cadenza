import CryptoKit
import Foundation

// MARK: - Source / Errors / Result

/// Everything the writer reads, as injected closures — tests run against
/// stubs or a real in-memory store without touching AppState.
///
/// All fetch closures THROW: a failed store read must abort the archive
/// (or land in failures for per-recording fetches), never degrade into a
/// "successful" empty archive.
struct PortableArchiveSource: Sendable {
    /// One-shot catalog: sizing rows + folders/recaps/artifacts/speaker
    /// profiles captured atomically in a single store call (§6.4 一致性).
    var catalog: @Sendable () async throws -> ArchiveCatalog
    var record: @Sendable (UUID) async throws -> ArchiveRecordingRecord?
    var voiceSamples: @Sendable (UUID) async throws -> [ArchiveVoiceSampleRecord]
    var chatHistoryDirectory: URL?
    var appVersion: String
}

enum PortableArchiveError: LocalizedError, Equatable {
    case cancelled
    case insufficientDiskSpace(needed: Int64, available: Int64)
    /// The disk filled up mid-write. Deliberately fatal (staging is removed):
    /// a full disk is not a per-recording failure — degrading it to `failures`
    /// would finalize a "successful" archive with most of its audio missing.
    case diskFullDuringWrite

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return String(localized: "Archive export was cancelled.")
        case .insufficientDiskSpace(let needed, let available):
            let neededText = ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)
            let availableText = ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
            return String(localized: "Not enough disk space: about \(neededText) needed, \(availableText) available")
        case .diskFullDuringWrite:
            return String(localized: "The disk filled up while writing the archive.")
        }
    }
}

struct PortableArchiveResult: Sendable {
    var archiveURL: URL
    var recordingCount: Int
    var failureCount: Int
}

// MARK: - Writer

/// Writes a `.cadenza-archive/` directory: entities JSON + audio originals +
/// unmerged segments + chat history + (opt-in) voice embeddings, described by
/// a manifest with per-file SHA-256.
///
/// Flow (spec §12.2): staging directory → write everything → re-read and hash
/// every file → write manifest last → atomic rename to the final name.
/// Cancellation/failure removes staging; a half-written final archive can
/// never exist. Missing audio / segments land in `failures` and the archive
/// still completes (partial success is visible, never silent) — EXCEPT a full
/// disk, which is fatal (see `diskFullDuringWrite`).
///
/// Memory: the library is streamed one recording at a time and details are
/// fetched via the store's uncached path; transcripts are appended straight
/// to entities/transcripts.json — no phase holds the whole corpus in RAM.
enum PortableArchiveWriter {

    struct Options: Sendable {
        var includeVoiceEmbeddings = false
    }

    private static let freeSpaceMargin: Int64 = 100 * 1024 * 1024
    /// Flat per-recording allowance for rendered entity JSON (transcript ×
    /// formats + metadata). Deliberately generous — over-estimating rejects a
    /// marginal disk up front instead of dying mid-write.
    private static let perRecordingTextEstimate: Int64 = 512 * 1024
    static let stagingPrefix = ".cadenza-archive-staging-"

    static func write(
        toParent parent: URL,
        source: PortableArchiveSource,
        options: Options = Options(),
        diskSpace: DiskSpaceProviding = FileManagerDiskSpaceProvider(),
        now: Date = Date(),
        isCancelled: @escaping @Sendable () -> Bool = { false },
        onProgress: @escaping @Sendable (_ done: Int, _ total: Int) -> Void = { _, _ in },
        onVerifyProgress: @escaping @Sendable (_ done: Int, _ total: Int) -> Void = { _, _ in }
    ) async throws -> PortableArchiveResult {
        let staging = parent.appendingPathComponent(
            "\(stagingPrefix)\(UUID().uuidString)", isDirectory: true
        )
        do {
            return try await writeInto(
                staging: staging, parent: parent, source: source, options: options,
                diskSpace: diskSpace, now: now, isCancelled: isCancelled,
                onProgress: onProgress, onVerifyProgress: onVerifyProgress
            )
        } catch {
            try? FileManager.default.removeItem(at: staging)
            try? FileManager.default.removeItem(at: ownerMarkerURL(forStaging: staging))
            throw error
        }
    }

    // swiftlint:disable:next function_body_length
    private static func writeInto(
        staging: URL,
        parent: URL,
        source: PortableArchiveSource,
        options: Options,
        diskSpace: DiskSpaceProviding,
        now: Date,
        isCancelled: @Sendable () -> Bool,
        onProgress: @Sendable (Int, Int) -> Void,
        onVerifyProgress: @Sendable (Int, Int) -> Void
    ) async throws -> PortableArchiveResult {
        let fm = FileManager.default
        let encoder = PortableArchiveSchema.makeEncoder()

        // 1. Catalog: sizing + store-level entities in ONE atomic store call.
        //    Store errors propagate — never an empty "successful" archive.
        let catalog = try await source.catalog()
        let sizingRows = catalog.sizing
        let knownFolderIDs = Set(catalog.folders.map(\.id))
        let knownProfileIDs = Set(catalog.speakerProfiles.map(\.id))
        var estimated: Int64 = 0
        for row in sizingRows {
            estimated += perRecordingTextEstimate
            if let url = row.audioFileURL,
               let size = try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64 {
                estimated += size
            } else if let segURL = row.audioSegmentsDirectoryURL {
                estimated += directorySize(atPath: segURL.path)
            }
        }
        if let chatDir = source.chatHistoryDirectory {
            estimated += directorySize(atPath: chatDir.path)
        }

        // 2. Preflight disk space (fail before writing anything).
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let available = try diskSpace.availableCapacity(at: parent)
        if available < estimated + freeSpaceMargin {
            throw PortableArchiveError.insufficientDiskSpace(
                needed: estimated, available: available
            )
        }

        // 3. Sweep stale staging leftovers (crash/force-quit of a previous
        //    run leaks an invisible dot-directory — reclaim it now).
        //    Owner markers keep a second live instance's staging safe.
        sweepStaleStaging(in: parent)

        // 4. Owner marker FIRST, then the staging skeleton — a second
        //    instance's sweep must never observe a marker-less live dir.
        try Data("\(ProcessInfo.processInfo.processIdentifier)".utf8)
            .write(to: ownerMarkerURL(forStaging: staging), options: .atomic)
        let entitiesDir = staging.appendingPathComponent("entities", isDirectory: true)
        let audioDir = staging.appendingPathComponent("audio", isDirectory: true)
        try fm.createDirectory(at: entitiesDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: audioDir, withIntermediateDirectories: true)
        let transcriptWriter = try JSONArrayFileWriter(
            url: entitiesDir.appendingPathComponent("transcripts.json"), encoder: encoder
        )

        // 5. Per-recording streaming loop — fetch, use, drop.
        var archiveRecordings: [ArchiveRecording] = []
        var archiveSummaries: [ArchiveSummary] = []
        var archiveVoiceSamples: [ArchiveVoiceSample] = []
        var failures: [PortableArchiveManifest.Failure] = []
        var unmergedIDs: [UUID] = []
        var transcriptCount = 0

        for (index, row) in sizingRows.enumerated() {
            if isCancelled() { throw PortableArchiveError.cancelled }
            let record: ArchiveRecordingRecord
            do {
                guard let fetched = try await source.record(row.recordingID) else {
                    failures.append(.init(
                        recordingID: row.recordingID,
                        reason: "recording missing (deleted during export)"
                    ))
                    onProgress(index + 1, sizingRows.count)
                    continue
                }
                record = fetched
            } catch {
                failures.append(.init(
                    recordingID: row.recordingID,
                    reason: "recording fetch failed: \(error.localizedDescription)"
                ))
                onProgress(index + 1, sizingRows.count)
                continue
            }
            let detail = record.detail
            var hasAudio = false
            var hasUnmergedSegments = false

            // 一致性守卫（§catalog）：录音引用了 catalog 快照之外的 folder /
            // speaker profile → 归档里清除该引用并记 failure，绝不产出
            // dangling 引用的"已验证归档"。（Recap.recordingIDs 例外：那是
            // 历史性引用，录音先删、recap 留存是合法状态，validator 不校验。）
            var archivedFolderID = detail.folderID
            if let folderID = detail.folderID, !knownFolderIDs.contains(folderID) {
                archivedFolderID = nil
                failures.append(.init(
                    recordingID: detail.id,
                    reason: "folder \(folderID.uuidString) disappeared during export; reference cleared"
                ))
            }
            var archivedMappings = detail.speakerMappings
            let danglingMappings = archivedMappings.filter { !knownProfileIDs.contains($0.profileID) }
            if !danglingMappings.isEmpty {
                archivedMappings.removeAll { !knownProfileIDs.contains($0.profileID) }
                failures.append(.init(
                    recordingID: detail.id,
                    reason: "speaker mapping(s) reference profiles created after export started; dropped: "
                        + danglingMappings.map(\.rawLabel).joined(separator: ", ")
                ))
            }

            if let audioURL = record.audioFileURL {
                if fm.fileExists(atPath: audioURL.path) {
                    let target = audioDir.appendingPathComponent("\(detail.id.uuidString).m4a")
                    do {
                        try fm.copyItem(at: audioURL, to: target)
                        hasAudio = true
                    } catch {
                        try? fm.removeItem(at: target) // 不留半截文件进 manifest
                        if isOutOfSpace(error) { throw PortableArchiveError.diskFullDuringWrite }
                        failures.append(.init(
                            recordingID: detail.id,
                            reason: "audio copy failed: \(error.localizedDescription)"
                        ))
                    }
                } else {
                    failures.append(.init(recordingID: detail.id, reason: "audio file missing: \(audioURL.path)"))
                }
            } else if detail.audioFile != nil {
                // Reference present but unresolvable — surface it instead of
                // silently archiving the recording as audio-less.
                failures.append(.init(
                    recordingID: detail.id,
                    reason: "audio reference unresolvable: \(detail.audioFile?.storageValue ?? "")"
                ))
            } else if let segURL = record.audioSegmentsDirectoryURL {
                // No merged audio — the crash-recovery segments ARE the audio.
                if fm.fileExists(atPath: segURL.path) {
                    let target = staging
                        .appendingPathComponent("segments", isDirectory: true)
                        .appendingPathComponent(detail.id.uuidString, isDirectory: true)
                    do {
                        try fm.createDirectory(
                            at: target.deletingLastPathComponent(), withIntermediateDirectories: true
                        )
                        try fm.copyItem(at: segURL, to: target)
                        hasUnmergedSegments = true
                        unmergedIDs.append(detail.id)
                    } catch {
                        try? fm.removeItem(at: target)
                        if isOutOfSpace(error) { throw PortableArchiveError.diskFullDuringWrite }
                        failures.append(.init(
                            recordingID: detail.id,
                            reason: "segments copy failed: \(error.localizedDescription)"
                        ))
                    }
                } else {
                    failures.append(.init(recordingID: detail.id, reason: "segments directory missing: \(segURL.path)"))
                }
            }

            archiveRecordings.append(PortableArchiveMapping.archiveRecording(
                from: record, folderID: archivedFolderID, speakerMappings: archivedMappings,
                hasAudio: hasAudio, hasUnmergedSegments: hasUnmergedSegments
            ))
            if let transcript = detail.transcript {
                do {
                    try transcriptWriter.append(
                        PortableArchiveMapping.archiveTranscript(recordingID: detail.id, transcript)
                    )
                    transcriptCount += 1
                } catch {
                    if isOutOfSpace(error) { throw PortableArchiveError.diskFullDuringWrite }
                    throw error
                }
            }
            if let summary = detail.summary {
                archiveSummaries.append(
                    PortableArchiveMapping.archiveSummary(recordingID: detail.id, summary)
                )
            }
            if options.includeVoiceEmbeddings {
                do {
                    let samples = try await source.voiceSamples(detail.id)
                    for rawSample in samples {
                        var sample = PortableArchiveMapping.archiveVoiceSample(rawSample)
                        if let profileID = sample.profileID, !knownProfileIDs.contains(profileID) {
                            sample.profileID = nil
                            failures.append(.init(
                                recordingID: detail.id,
                                reason: "voice sample references profile created after export started; link cleared"
                            ))
                        }
                        archiveVoiceSamples.append(sample)
                    }
                } catch {
                    failures.append(.init(
                        recordingID: detail.id,
                        reason: "voice samples fetch failed: \(error.localizedDescription)"
                    ))
                }
            }
            onProgress(index + 1, sizingRows.count)
        }
        try transcriptWriter.finish()

        // 6. Store-level entities — already captured atomically in the catalog.
        let folders = catalog.folders
        let recaps = catalog.recaps
        let artifacts = catalog.artifacts
        let speakerProfiles = catalog.speakerProfiles
        let tags = Array(Set(archiveRecordings.flatMap(\.tags))).sorted()

        func writeEntity(_ value: some Encodable, _ filename: String) throws {
            do {
                try encoder.encode(value).write(
                    to: entitiesDir.appendingPathComponent(filename), options: .atomic
                )
            } catch {
                if isOutOfSpace(error) { throw PortableArchiveError.diskFullDuringWrite }
                throw error
            }
        }
        try writeEntity(archiveRecordings, "recordings.json")
        try writeEntity(archiveSummaries, "summaries.json")
        try writeEntity(folders, "folders.json")
        try writeEntity(tags, "tags.json")
        try writeEntity(recaps, "recaps.json")
        try writeEntity(artifacts, "agent-artifacts.json")
        try writeEntity(speakerProfiles, "speaker-profiles.json")
        if options.includeVoiceEmbeddings {
            try writeEntity(archiveVoiceSamples, "embeddings.json")
        }

        // 7. Chat history (best effort — absence is not a failure).
        if let chatDir = source.chatHistoryDirectory,
           fm.fileExists(atPath: chatDir.path) {
            do {
                try fm.copyItem(
                    at: chatDir,
                    to: staging.appendingPathComponent("chat-history", isDirectory: true)
                )
            } catch {
                if isOutOfSpace(error) { throw PortableArchiveError.diskFullDuringWrite }
                failures.append(.init(recordingID: nil, reason: "chat history copy failed: \(error.localizedDescription)"))
            }
        }

        if isCancelled() { throw PortableArchiveError.cancelled }

        // 8. Verification pass: re-read EVERY staged file and hash it.
        //    Cancellable and reports progress — on a large archive this
        //    re-reads the whole payload and takes real time.
        let fileEntries = try hashAllFiles(
            under: staging, isCancelled: isCancelled, onProgress: onVerifyProgress
        )

        // 9. Manifest — written last, so its presence implies a verified archive.
        let manifest = PortableArchiveManifest(
            archiveSchemaVersion: PortableArchiveSchema.version,
            appVersion: source.appVersion,
            createdAt: now,
            counts: [
                "recordings": archiveRecordings.count,
                "transcripts": transcriptCount,
                "summaries": archiveSummaries.count,
                "folders": folders.count,
                "tags": tags.count,
                "recaps": recaps.count,
                "agentArtifacts": artifacts.count,
                "speakerProfiles": speakerProfiles.count,
                "voiceSamples": archiveVoiceSamples.count,
            ],
            unmergedRecordingIDs: unmergedIDs,
            includesVoiceEmbeddings: options.includeVoiceEmbeddings,
            files: fileEntries,
            failures: failures
        )
        try encoder.encode(manifest).write(
            to: staging.appendingPathComponent("manifest.json"), options: .atomic
        )

        // 10. Atomic finalize.
        let finalURL = try uniqueArchiveURL(in: parent, date: now)
        try fm.moveItem(at: staging, to: finalURL)
        try? fm.removeItem(at: ownerMarkerURL(forStaging: staging))

        return PortableArchiveResult(
            archiveURL: finalURL,
            recordingCount: archiveRecordings.count,
            failureCount: failures.count
        )
    }

    // MARK: - Helpers

    /// Recursively hashes every regular file under `root`; archive-relative
    /// "/"-separated paths, sorted ascending.
    static func hashAllFiles(
        under root: URL,
        isCancelled: @Sendable () -> Bool = { false },
        onProgress: @Sendable (_ done: Int, _ total: Int) -> Void = { _, _ in }
    ) throws -> [PortableArchiveManifest.FileEntry] {
        var paths: [(url: URL, relativePath: String)] = []
        try collectRegularFiles(under: root, relativePrefix: "", into: &paths)
        paths.sort { $0.relativePath < $1.relativePath }

        var entries: [PortableArchiveManifest.FileEntry] = []
        entries.reserveCapacity(paths.count)
        for (index, file) in paths.enumerated() {
            if isCancelled() { throw PortableArchiveError.cancelled }
            let size = (try FileManager.default.attributesOfItem(atPath: file.url.path)[.size] as? Int64) ?? 0
            entries.append(.init(
                path: file.relativePath,
                size: size,
                sha256: try sha256OfFile(at: file.url)
            ))
            onProgress(index + 1, paths.count)
        }
        return entries
    }

    private static func collectRegularFiles(
        under directory: URL,
        relativePrefix: String,
        into paths: inout [(url: URL, relativePath: String)]
    ) throws {
        let children = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey]
        )
        for child in children {
            let values = try child.resourceValues(forKeys: [.isDirectoryKey])
            let relativePath = relativePrefix.isEmpty
                ? child.lastPathComponent
                : "\(relativePrefix)/\(child.lastPathComponent)"
            if values.isDirectory == true {
                try collectRegularFiles(under: child, relativePrefix: relativePath, into: &paths)
            } else {
                paths.append((child, relativePath))
            }
        }
    }

    static func sha256OfFile(at url: URL) throws -> String {
        var hasher = SHA256()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while true {
            let chunk = autoreleasepool { handle.readData(ofLength: 1 << 20) }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Total allocated size of all regular files under `path` (0 if absent).
    static func directorySize(atPath path: String) -> Int64 {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(
                forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]
            ), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// Sibling owner-marker file for a staging directory (contains the
    /// writer's pid). Lives NEXT to staging, not inside it, so it never
    /// pollutes the archive contents or the manifest.
    static func ownerMarkerURL(forStaging staging: URL) -> URL {
        staging.deletingLastPathComponent()
            .appendingPathComponent("\(staging.lastPathComponent).owner")
    }

    /// Removes leftover `.cadenza-archive-staging-*` directories from a
    /// crashed/killed previous run.
    ///
    /// 安全模型（写侧配合：marker 先于目录创建，见 writeInto 第 4 步）：
    /// - marker 存在且 pid 存活且目录未超龄 → 跳过（另一实例在途导出）。
    /// - marker 的 pid 已死 → 立即清除（死亡是确证）。
    /// - **无 marker 的目录 / 无目录的 marker → 必须过 `orphanGracePeriod`
    ///   才清除**：marker 先行与目录创建之间存在极短窗口，另一实例的 sweep
    ///   可能恰好看到 marker-only（或把 marker 当孤儿清掉后留下无 marker 活
    ///   目录）——宽限期让"新鲜的中间态"永不被清，只清真正的残留。
    /// - PID 重用的方向性：误判"存活"只会导致跳过（泄漏保留到下次 sweep），
    ///   永不误删活目录；配 `staleAgeLimit` 超龄兜底。
    static let staleAgeLimit: TimeInterval = 24 * 60 * 60
    static let orphanGracePeriod: TimeInterval = 15 * 60

    static func sweepStaleStaging(in parent: URL, now: Date = Date()) {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(atPath: parent.path) else { return }

        func age(ofPath path: String) -> TimeInterval {
            let created = (try? fm.attributesOfItem(atPath: path)[.creationDate] as? Date) ?? .distantPast
            return now.timeIntervalSince(created)
        }

        for name in children where name.hasPrefix(stagingPrefix) && !name.hasSuffix(".owner") {
            let staging = parent.appendingPathComponent(name)
            let marker = ownerMarkerURL(forStaging: staging)
            if let pidText = try? String(contentsOf: marker, encoding: .utf8),
               let pid = Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)) {
                if kill(pid, 0) == 0, age(ofPath: staging.path) < staleAgeLimit {
                    continue // 属主仍存活且未超龄
                }
                // pid 已死或超龄 → 确证残留
            } else {
                // 无 marker：可能是竞态中间态（另一实例刚清走 marker），留宽限
                if age(ofPath: staging.path) < orphanGracePeriod { continue }
            }
            try? fm.removeItem(at: staging)
            try? fm.removeItem(at: marker)
        }
        // marker-only（目录已搬走/删除，或 marker 先行窗口）：过宽限才清
        for name in children where name.hasPrefix(stagingPrefix) && name.hasSuffix(".owner") {
            let markerPath = parent.appendingPathComponent(name)
            let dirName = String(name.dropLast(".owner".count))
            guard !fm.fileExists(atPath: parent.appendingPathComponent(dirName).path) else { continue }
            if age(ofPath: markerPath.path) < orphanGracePeriod { continue }
            try? fm.removeItem(at: markerPath)
        }
    }

    private static func isOutOfSpace(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == CocoaError.fileWriteOutOfSpace.rawValue { return true }
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ENOSPC) { return true }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isOutOfSpace(underlying)
        }
        return false
    }

    private static func uniqueArchiveURL(in parent: URL, date: Date) throws -> URL {
        let base = "Cadenza Archive \(ExportFileNaming.dateComponent(for: date))"
        let fm = FileManager.default
        for attempt in 1...1000 {
            let name = attempt == 1 ? base : "\(base) -\(attempt)"
            let candidate = parent.appendingPathComponent("\(name).cadenza-archive", isDirectory: true)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        throw CocoaError(.fileWriteFileExists)
    }
}

// MARK: - Streaming JSON array writer

/// Appends elements straight to disk as a valid JSON array so large entity
/// files (transcripts) never accumulate in memory. Deterministic: same
/// encoder settings as full-array encoding; decoders don't care about the
/// framing whitespace.
private final class JSONArrayFileWriter {
    private let handle: FileHandle
    private let encoder: JSONEncoder
    private var isFirst = true

    init(url: URL, encoder: JSONEncoder) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        self.handle = try FileHandle(forWritingTo: url)
        self.encoder = encoder
        try handle.write(contentsOf: Data("[".utf8))
    }

    func append(_ value: some Encodable) throws {
        if !isFirst { try handle.write(contentsOf: Data(",\n".utf8)) }
        isFirst = false
        try handle.write(contentsOf: try encoder.encode(value))
    }

    func finish() throws {
        try handle.write(contentsOf: Data("]".utf8))
        try handle.close()
    }
}

// MARK: - DTO → Archive mapping (writer-side; the CI validator decodes
// archives independently and must never route through these functions)

enum PortableArchiveMapping {

    static func archiveRecording(
        from record: ArchiveRecordingRecord,
        folderID: UUID?,
        speakerMappings: [SpeakerLabelMappingDTO],
        hasAudio: Bool,
        hasUnmergedSegments: Bool
    ) -> ArchiveRecording {
        let detail = record.detail
        return ArchiveRecording(
            id: detail.id,
            title: detail.title,
            startDate: detail.startDate,
            endDate: detail.endDate,
            duration: detail.duration,
            meetingApp: detail.meetingApp,
            meetingURL: detail.meetingURL,
            meetingType: detail.meetingType,
            linkedCalendarEventID: detail.linkedCalendarEventID,
            calendarAutoLinkState: record.calendarAutoLinkState,
            language: detail.language,
            tags: detail.tags,
            folderID: folderID,
            trashedDate: record.trashedDate,
            source: detail.source,
            createdAt: detail.createdAt,
            updatedAt: detail.updatedAt,
            speakerMappings: speakerMappings.map {
                ArchiveSpeakerMapping(rawLabel: $0.rawLabel, profileID: $0.profileID, profileName: $0.profileName)
            },
            hasAudio: hasAudio,
            hasUnmergedSegments: hasUnmergedSegments,
            audioOwnership: record.audioOwnership
        )
    }

    static func archiveTranscript(recordingID: UUID, _ transcript: TranscriptDTO) -> ArchiveTranscript {
        ArchiveTranscript(
            recordingID: recordingID,
            fullText: transcript.fullText,
            detectedLanguage: transcript.detectedLanguage,
            createdAt: transcript.createdAt,
            segments: transcript.segments.map {
                ArchiveTranscriptSegment(
                    id: $0.id, startTime: $0.startTime, endTime: $0.endTime,
                    text: $0.text, speaker: $0.speaker
                )
            }
        )
    }

    static func archiveSummary(recordingID: UUID, _ summary: SummaryDTO) -> ArchiveSummary {
        ArchiveSummary(
            recordingID: recordingID,
            overview: summary.overview,
            keyPoints: summary.keyPoints,
            decisions: summary.decisions,
            followUps: summary.followUps,
            yourTasks: summary.yourTasks,
            provider: summary.provider,
            model: summary.model,
            language: summary.language,
            createdAt: summary.createdAt,
            chapters: summary.chapters.map {
                ArchiveChapter(title: $0.title, startSeconds: $0.startSeconds, summary: $0.summary)
            },
            actionItems: summary.actionItems.map {
                ArchiveActionItem(
                    id: $0.id, assignee: $0.assignee, task: $0.task,
                    deadline: $0.deadline, isCompleted: $0.isCompleted, priority: $0.priority,
                    createdAt: $0.createdAt, updatedAt: $0.updatedAt
                )
            }
        )
    }

    // folders / recaps / artifacts / speaker profiles 由 store 侧在
    // fetchArchiveCatalog 内直接映射（模型全字段，且与 sizing 同一事务窗口）。

    static func archiveVoiceSample(_ sample: ArchiveVoiceSampleRecord) -> ArchiveVoiceSample {
        ArchiveVoiceSample(
            recordingID: sample.recordingID,
            rawLabel: sample.rawLabel,
            profileID: sample.profileID,
            embeddingData: sample.embeddingData,
            embeddingDimension: sample.embeddingDimension,
            sampleDuration: sample.sampleDuration,
            nonOverlapRatio: sample.nonOverlapRatio,
            qualityScore: sample.qualityScore,
            modelVersion: sample.modelVersion,
            createdAt: sample.createdAt
        )
    }
}
