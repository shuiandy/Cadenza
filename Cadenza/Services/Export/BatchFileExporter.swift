import Foundation

// MARK: - Options / Failures / Disk space

struct BatchExportOptions: Equatable, Sendable {
    var transcriptTxt = true
    var transcriptSRT = false
    var transcriptMarkdown = true
    var summaryMarkdown = true
    var audio = true

    var wantsAnything: Bool {
        transcriptTxt || transcriptSRT || transcriptMarkdown || summaryMarkdown || audio
    }
}

struct BatchExportFailure: Equatable, Sendable, Identifiable {
    let id: UUID          // recordingID
    let title: String
    let reason: String
}

protocol DiskSpaceProviding: Sendable {
    /// Available bytes on the volume containing `url`.
    func availableCapacity(at url: URL) throws -> Int64
}

struct FileManagerDiskSpaceProvider: DiskSpaceProviding {
    func availableCapacity(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return Int64(values.volumeAvailableCapacityForImportantUsage ?? 0)
    }
}

// MARK: - BatchFileExporter

/// Local-file bulk export: one directory per recording
/// (`yyyy-MM-dd - Title/` with audio.m4a / transcript.* / summary.md /
/// metadata.json). State machine mirrors `BulkExportCoordinator`; all
/// dependencies are injected so tests run against a temp directory with
/// no SwiftData or UI.
///
/// Failure semantics (spec §12.1): a single bad recording never aborts the
/// batch — it lands in `failures` and the run continues. "DB references an
/// audio file that is gone" is a failure; "recording legitimately has no
/// transcript/summary/audio" is not. Cancellation keeps completed items.
@Observable @MainActor
final class BatchFileExporter {

    enum Phase: Equatable {
        case idle
        case preparing
        case confirming(pending: Int, estimatedBytes: Int64)
        case running(done: Int, total: Int)
        case finished(succeeded: Int, failures: [BatchExportFailure])
        case failed(message: String)
        case cancelled(exported: Int, failures: [BatchExportFailure])
    }

    struct Dependencies {
        var fetchDetail: @MainActor (UUID) async -> RecordingDetailDTO?
        /// Resolved audio URLs for the selected ids — lightweight preflight
        /// input, so `prepare` never loads full details. Throwing: a failed
        /// store read must fail the preflight, not estimate against an empty
        /// map.
        var fetchAudioPaths: @MainActor ([UUID]) async throws -> [UUID: URL]
        /// Fetched ONCE per run; per-item folder paths are built in-memory.
        var fetchFolders: @MainActor () async -> [FolderDTO]
        /// Reference-to-URL resolution for the per-item audio copy; tests
        /// inject a resolver rooted in their temp directory.
        var resolveAudio: @Sendable (AudioFileReference) -> URL?
        var diskSpace: DiskSpaceProviding
        /// Injectable clock for deterministic `exportedAt` in tests.
        var now: @Sendable () -> Date

        init(
            fetchDetail: @escaping @MainActor (UUID) async -> RecordingDetailDTO?,
            fetchAudioPaths: @escaping @MainActor ([UUID]) async throws -> [UUID: URL],
            fetchFolders: @escaping @MainActor () async -> [FolderDTO],
            resolveAudio: @escaping @Sendable (AudioFileReference) -> URL? = {
                try? ProfileStorageResolver.current.resolveAudio($0)
            },
            diskSpace: DiskSpaceProviding = FileManagerDiskSpaceProvider(),
            now: @escaping @Sendable () -> Date = { Date() }
        ) {
            self.fetchDetail = fetchDetail
            self.fetchAudioPaths = fetchAudioPaths
            self.fetchFolders = fetchFolders
            self.resolveAudio = resolveAudio
            self.diskSpace = diskSpace
            self.now = now
        }
    }

    /// Storage-migration exclusion for export IO; tests inject an isolated
    /// gate.
    @ObservationIgnored var migrationGate: StorageMigrationGate = .shared

    var phase: Phase = .idle
    @ObservationIgnored var dependencies: Dependencies?

    @ObservationIgnored private var pendingIDs: [UUID] = []
    @ObservationIgnored private var pendingOptions = BatchExportOptions()
    @ObservationIgnored private var pendingDestination: URL?
    @ObservationIgnored private var pendingRequestID: UUID?
    @ObservationIgnored private var cancelRequested = false

    /// Extra bytes required beyond the estimate before a run may start.
    private static let freeSpaceMargin: Int64 = 100 * 1024 * 1024
    /// Flat per-recording allowance for rendered text + metadata (estimate
    /// runs without loading transcripts, so this is deliberately generous).
    private static let perRecordingTextEstimate: Int64 = 512 * 1024

    var isBusy: Bool {
        switch phase {
        case .preparing, .confirming, .running: return true
        case .idle, .finished, .failed, .cancelled: return false
        }
    }

    // MARK: - Prepare (estimate + preflight)

    /// Returns a claim token when THIS call reached `.confirming`; nil when
    /// the exporter was busy or preflight failed. Callers that auto-confirm
    /// (`prepareAndRun`) must verify the token — checking the shared phase
    /// alone could confirm someone else's pending run.
    @discardableResult
    func prepare(recordingIDs: [UUID], options: BatchExportOptions, destination: URL) async -> UUID? {
        guard !isBusy, let deps = dependencies, options.wantsAnything, !recordingIDs.isEmpty else { return nil }
        phase = .preparing

        // 轻量估算：只取音频路径，不加载任何 detail/transcript。
        // store 读失败 → 直接失败，不允许按空表估算后"成功"导出 0 条。
        var estimated = Int64(recordingIDs.count) * Self.perRecordingTextEstimate
        if options.audio {
            let audioPaths: [UUID: URL]
            do {
                audioPaths = try await deps.fetchAudioPaths(recordingIDs)
            } catch {
                guard case .preparing = phase else { return nil }
                NSLog(
                    "[BatchFileExporter] Audio path preflight failed: %@",
                    error.localizedDescription
                )
                phase = .failed(message: Self.genericFailureMessage)
                return nil
            }
            for url in audioPaths.values {
                if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64 {
                    estimated += size
                }
            }
        }
        guard case .preparing = phase else { return nil }

        do {
            let available = try deps.diskSpace.availableCapacity(at: destination)
            if available < estimated + Self.freeSpaceMargin {
                phase = .failed(message: String(
                    localized: "Not enough disk space: about \(Self.formatBytes(estimated)) needed, \(Self.formatBytes(available)) available"
                ))
                return nil
            }
        } catch {
            NSLog(
                "[BatchFileExporter] Disk-space preflight failed: %@",
                error.localizedDescription
            )
            phase = .failed(message: Self.genericFailureMessage)
            return nil
        }

        let requestID = UUID()
        pendingIDs = recordingIDs
        pendingOptions = options
        pendingDestination = destination
        pendingRequestID = requestID
        phase = .confirming(pending: recordingIDs.count, estimatedBytes: estimated)
        return requestID
    }

    func dismissConfirmation() {
        if case .confirming = phase { phase = .idle }
    }

    func dismissResult() {
        switch phase {
        case .finished, .failed, .cancelled: phase = .idle
        case .idle, .preparing, .confirming, .running: break
        }
    }

    // MARK: - Run

    func confirmAndStart() async {
        guard let claim = claimConfirmedRun() else { return }
        await run(ids: claim.ids, options: claim.options, destination: claim.destination)
    }

    /// Context-menu entry: the user already picked the recordings AND the
    /// destination folder, so the extra confirmation dialog is skipped —
    /// preflight (disk space) still runs. Returns when the run completes.
    /// Only confirms the run THIS call claimed (token check) — never a
    /// pre-existing `.confirming` that belongs to someone else.
    func prepareAndRun(recordingIDs: [UUID], options: BatchExportOptions, destination: URL) async {
        guard let requestID = await prepare(
            recordingIDs: recordingIDs, options: options, destination: destination
        ) else { return } // busy 或 preflight 失败
        guard case .confirming = phase, pendingRequestID == requestID else { return }
        await confirmAndStart()
    }

    /// Synchronous UI entry point for the confirm button — the phase flip must
    /// happen before SwiftUI's alert dismissal calls dismissConfirmation()
    /// (same race as BulkExportCoordinator.beginConfirmedRun).
    func beginConfirmedRun() {
        guard let claim = claimConfirmedRun() else { return }
        Task { await run(ids: claim.ids, options: claim.options, destination: claim.destination) }
    }

    private func claimConfirmedRun() -> (ids: [UUID], options: BatchExportOptions, destination: URL)? {
        guard case .confirming = phase, dependencies != nil,
              let destination = pendingDestination else { return nil }
        cancelRequested = false
        let ids = pendingIDs
        pendingIDs = []
        pendingDestination = nil
        pendingRequestID = nil
        phase = .running(done: 0, total: ids.count)
        return (ids, pendingOptions, destination)
    }

    private func run(ids: [UUID], options: BatchExportOptions, destination: URL) async {
        guard let deps = dependencies else { return }
        guard let migrationLease = migrationGate.claimActivity() else {
            phase = .failed(message: String(
                localized: "Export is unavailable while the storage location is being changed."
            ))
            return
        }
        defer { migrationGate.releaseActivity(migrationLease) }
        var succeeded = 0
        var failures: [BatchExportFailure] = []
        let exportedAt = deps.now()
        let folders = await deps.fetchFolders() // 一次取全，逐条内存构建路径

        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            NSLog(
                "[BatchFileExporter] Destination creation failed: %@",
                error.localizedDescription
            )
            phase = .failed(message: Self.genericFailureMessage)
            return
        }

        for (index, id) in ids.enumerated() {
            if cancelRequested {
                phase = .cancelled(exported: succeeded, failures: failures)
                return
            }
            guard let detail = await deps.fetchDetail(id) else {
                failures.append(BatchExportFailure(
                    id: id, title: id.uuidString,
                    reason: ExportError.recordingNotFound.localizedMessage()
                ))
                phase = .running(done: index + 1, total: ids.count)
                continue
            }
            let folderPath = FolderPathBuilder.path(to: detail.folderID, in: folders)
            let audioURL = detail.audioFile.flatMap { deps.resolveAudio($0) }

            // 文件 IO 放后台线程，避免大音频复制卡主线程
            let itemErrors = await Task.detached(priority: .utility) {
                Self.exportOne(
                    detail: detail, audioURL: audioURL, options: options,
                    destination: destination,
                    folderPath: folderPath, exportedAt: exportedAt
                )
            }.value

            if itemErrors.isEmpty {
                succeeded += 1
            } else {
                failures.append(BatchExportFailure(
                    id: detail.id, title: detail.title,
                    reason: itemErrors.joined(separator: "; ")
                ))
            }
            phase = .running(done: index + 1, total: ids.count)
        }

        phase = cancelRequested
            ? .cancelled(exported: succeeded, failures: failures)
            : .finished(succeeded: succeeded, failures: failures)
    }

    /// Takes effect after the in-flight item finishes; completed items are kept.
    func cancel() {
        if case .running = phase { cancelRequested = true }
    }

    // MARK: - Per-recording export (background thread)

    /// Returns item-level error strings; empty means fully exported.
    /// Partial output for a failed item is deliberately kept on disk.
    private nonisolated static func exportOne(
        detail: RecordingDetailDTO,
        audioURL: URL?,
        options: BatchExportOptions,
        destination: URL,
        folderPath: [String],
        exportedAt: Date
    ) -> [String] {
        var errors: [String] = []
        let fm = FileManager.default

        let directory: URL
        do {
            directory = try uniqueDirectory(
                base: ExportContentRenderer.exportDirectoryName(for: detail),
                in: destination
            )
        } catch {
            NSLog(
                "[BatchFileExporter] Recording directory creation failed: %@",
                error.localizedDescription
            )
            return [genericFailureMessage]
        }

        func appendGenericFailure() {
            if !errors.contains(genericFailureMessage) {
                errors.append(genericFailureMessage)
            }
        }

        func write(_ content: String, to filename: String) {
            do {
                try Data(content.utf8).write(
                    to: directory.appendingPathComponent(filename), options: .atomic
                )
            } catch {
                NSLog(
                    "[BatchFileExporter] %@ write failed: %@",
                    filename,
                    error.localizedDescription
                )
                appendGenericFailure()
            }
        }

        if let transcript = detail.transcript {
            if options.transcriptTxt {
                write(ExportContentRenderer.transcriptText(transcript, mappings: detail.speakerMappings),
                      to: "transcript.txt")
            }
            if options.transcriptSRT {
                write(ExportContentRenderer.transcriptSRT(transcript, mappings: detail.speakerMappings),
                      to: "transcript.srt")
            }
            if options.transcriptMarkdown {
                write(ExportContentRenderer.transcriptMarkdown(transcript, detail: detail),
                      to: "transcript.md")
            }
        }
        if options.summaryMarkdown, let summary = detail.summary {
            write(ExportContentRenderer.summaryMarkdown(summary, detail: detail), to: "summary.md")
        }
        if options.audio, detail.audioFile != nil {
            if let audioURL, fm.fileExists(atPath: audioURL.path) {
                do {
                    try fm.copyItem(at: audioURL, to: directory.appendingPathComponent("audio.m4a"))
                } catch {
                    NSLog(
                        "[BatchFileExporter] Audio copy failed: %@",
                        error.localizedDescription
                    )
                    appendGenericFailure()
                }
            } else {
                NSLog(
                    "[BatchFileExporter] Audio file missing for recording %@",
                    detail.id.uuidString
                )
                errors.append(
                    LocalizedBundle.string(
                        "The audio file for this recording could not be found.",
                        locale: nil
                    )
                )
            }
        }
        do {
            let metadata = try ExportContentRenderer.metadataJSON(
                detail, folderPath: folderPath, exportedAt: exportedAt
            )
            try metadata.write(to: directory.appendingPathComponent("metadata.json"), options: .atomic)
        } catch {
            NSLog(
                "[BatchFileExporter] Metadata write failed: %@",
                error.localizedDescription
            )
            appendGenericFailure()
        }
        return errors
    }

    /// "Name", "Name -2", "Name -3", … within `parent`.
    private nonisolated static func uniqueDirectory(base: String, in parent: URL) throws -> URL {
        let fm = FileManager.default
        for attempt in 1...1000 {
            let name = attempt == 1 ? base : "\(base) -\(attempt)"
            let candidate = parent.appendingPathComponent(name, isDirectory: true)
            if !fm.fileExists(atPath: candidate.path) {
                try fm.createDirectory(at: candidate, withIntermediateDirectories: false)
                return candidate
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private nonisolated static var genericFailureMessage: String {
        ExportError.unexpected("").localizedMessage()
    }
}

// MARK: - Folder path

enum FolderPathBuilder {
    /// Path of folder names from root down to `folderID`; cycle-safe.
    static func path(to folderID: UUID?, in folders: [FolderDTO]) -> [String] {
        guard let folderID else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        var names: [String] = []
        var current = byID[folderID]
        var visited = Set<UUID>()
        while let folder = current, visited.insert(folder.id).inserted {
            names.append(folder.name)
            current = folder.parentFolderID.flatMap { byID[$0] }
        }
        return names.reversed()
    }
}
