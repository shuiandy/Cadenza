import Foundation
import os

/// UI-facing coordinator for "Export All Data": drives PortableArchiveWriter
/// on a background task and publishes progress on the main actor.
@Observable @MainActor
final class PortableArchiveExporter {
    /// Storage-migration exclusion for archive IO; tests inject an isolated
    /// gate.
    @ObservationIgnored var migrationGate: StorageMigrationGate = .shared

    enum Phase: Equatable {
        case idle
        case running(done: Int, total: Int)
        /// Post-copy hash pass — re-reads the whole archive, takes real time.
        case verifying(done: Int, total: Int)
        case finished(archivePath: String, recordings: Int, failures: Int)
        case failed(message: String)
        case cancelled
    }

    var phase: Phase = .idle
    @ObservationIgnored var makeSource: (@MainActor () -> PortableArchiveSource)?
    @ObservationIgnored var diskSpace: DiskSpaceProviding = FileManagerDiskSpaceProvider()
    /// Cross-thread cancel flag — the writer polls it from the background task.
    @ObservationIgnored private let cancelFlag = OSAllocatedUnfairLock(initialState: false)

    var isBusy: Bool {
        switch phase {
        case .running, .verifying: return true
        case .idle, .finished, .failed, .cancelled: return false
        }
    }

    func export(toParent parent: URL, includeVoiceEmbeddings: Bool) async {
        guard let migrationLease = migrationGate.claimActivity() else {
            phase = .failed(message: String(
                localized: "Export is unavailable while the storage location is being changed."
            ))
            return
        }
        defer { migrationGate.releaseActivity(migrationLease) }
        guard !isBusy, let makeSource else { return }
        cancelFlag.withLock { $0 = false }
        let source = makeSource()
        let flag = cancelFlag
        let diskSpace = diskSpace
        phase = .running(done: 0, total: 0)

        // 强捕获 self：@MainActor 类是 Sendable，run 期间持有即可；
        // weak 捕获是可变绑定，进不了 @Sendable 闭包。
        let progress: @Sendable (Int, Int) -> Void = { done, total in
            Task { @MainActor in
                self.updateProgress(done: done, total: total)
            }
        }
        let verifyProgress: @Sendable (Int, Int) -> Void = { done, total in
            Task { @MainActor in
                self.updateVerifyProgress(done: done, total: total)
            }
        }
        do {
            let result = try await Task.detached(priority: .utility) {
                try await PortableArchiveWriter.write(
                    toParent: parent,
                    source: source,
                    options: .init(includeVoiceEmbeddings: includeVoiceEmbeddings),
                    diskSpace: diskSpace,
                    isCancelled: { flag.withLock { $0 } },
                    onProgress: progress,
                    onVerifyProgress: verifyProgress
                )
            }.value
            phase = .finished(
                archivePath: result.archiveURL.path,
                recordings: result.recordingCount,
                failures: result.failureCount
            )
        } catch PortableArchiveError.cancelled {
            phase = .cancelled
        } catch {
            NSLog(
                "[PortableArchiveExporter] Archive export failed: %@",
                error.localizedDescription
            )
            phase = .failed(message: ExportError.unexpected("").localizedMessage())
        }
    }

    private func updateProgress(done: Int, total: Int) {
        if case .running = phase { phase = .running(done: done, total: total) }
    }

    private func updateVerifyProgress(done: Int, total: Int) {
        if isBusy { phase = .verifying(done: done, total: total) }
    }

    func cancel() {
        if isBusy { cancelFlag.withLock { $0 = true } }
    }

    func dismissResult() {
        switch phase {
        case .finished, .failed, .cancelled: phase = .idle
        case .idle, .running, .verifying: break
        }
    }
}
