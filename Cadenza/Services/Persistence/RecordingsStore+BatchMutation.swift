import Foundation
import SwiftData

extension RecordingsStore {
    enum BatchMutationFailure: Sendable, Equatable {
        case fetchFailed
        case targetFolderNotFound
        case persistenceFailed
        case operationInProgress
    }

    struct BatchMutationResult: Sendable, Equatable {
        let requestedCount: Int
        let matchedCount: Int
        let committedCount: Int
        let failure: BatchMutationFailure?

        var didCommit: Bool { failure == nil }

        static func committed(
            requestedCount: Int,
            matchedCount: Int,
            committedCount: Int
        ) -> Self {
            Self(
                requestedCount: requestedCount,
                matchedCount: matchedCount,
                committedCount: committedCount,
                failure: nil
            )
        }

        static func failed(
            requestedCount: Int,
            matchedCount: Int = 0,
            failure: BatchMutationFailure
        ) -> Self {
            Self(
                requestedCount: requestedCount,
                matchedCount: matchedCount,
                committedCount: 0,
                failure: failure
            )
        }
    }

    /// Moves a selection to Trash with one recording fetch and one batch save.
    /// Deliberately staged work is flushed before this transaction; a failed
    /// batch save therefore rolls back only this batch and cannot erase or
    /// later ghost-commit unrelated work.
    func trashRecordings(
        recordingIDs: Set<UUID>,
        reason _: String? = nil
    ) -> BatchMutationResult {
        let requestedCount = recordingIDs.count
        guard !recordingIDs.isEmpty else {
            return .committed(requestedCount: 0, matchedCount: 0, committedCount: 0)
        }

        let allRecordings: [Recording]
        do {
            allRecordings = try modelContext.fetch(FetchDescriptor<Recording>())
        } catch {
            NSLog("[RecordingsStore] batch trash fetch failed: %@", error.localizedDescription)
            return .failed(requestedCount: requestedCount, failure: .fetchFailed)
        }

        let matched = allRecordings.filter { recordingIDs.contains($0.id) }
        let changed = matched.filter { $0.trashedDate == nil || $0.folder != nil }
        guard !changed.isEmpty else {
            return .committed(
                requestedCount: requestedCount,
                matchedCount: matched.count,
                committedCount: 0
            )
        }

        guard performStandaloneMutation({
            let now = Date()
            for recording in changed {
                recording.trashedDate = now
                // Match the single-recording delete contract: a restored item
                // returns to the library root rather than a potentially stale
                // folder relationship.
                recording.folder = nil
                recording.updatedAt = now
            }
        }) else {
            return .failed(
                requestedCount: requestedCount,
                matchedCount: matched.count,
                failure: .persistenceFailed
            )
        }
        return .committed(
            requestedCount: requestedCount,
            matchedCount: matched.count,
            committedCount: changed.count
        )
    }

    /// Moves a selection to one folder with one recording fetch, one target
    /// folder lookup, and one batch save. Passing nil moves the rows to the
    /// root. Deliberately staged work is committed before this transaction.
    func moveRecordingsToFolder(
        recordingIDs: Set<UUID>,
        folderID: UUID?
    ) -> BatchMutationResult {
        let requestedCount = recordingIDs.count
        guard !recordingIDs.isEmpty else {
            return .committed(requestedCount: 0, matchedCount: 0, committedCount: 0)
        }

        let targetFolder: Folder?
        if let folderID {
            var descriptor = FetchDescriptor<Folder>(
                predicate: #Predicate { $0.id == folderID }
            )
            descriptor.fetchLimit = 1
            do {
                guard let folder = try modelContext.fetch(descriptor).first else {
                    return .failed(
                        requestedCount: requestedCount,
                        failure: .targetFolderNotFound
                    )
                }
                targetFolder = folder
            } catch {
                NSLog("[RecordingsStore] batch folder lookup failed: %@", error.localizedDescription)
                return .failed(requestedCount: requestedCount, failure: .fetchFailed)
            }
        } else {
            targetFolder = nil
        }

        let allRecordings: [Recording]
        do {
            allRecordings = try modelContext.fetch(FetchDescriptor<Recording>())
        } catch {
            NSLog("[RecordingsStore] batch move fetch failed: %@", error.localizedDescription)
            return .failed(requestedCount: requestedCount, failure: .fetchFailed)
        }

        let matched = allRecordings.filter {
            recordingIDs.contains($0.id) && $0.trashedDate == nil
        }
        let changed = matched.filter { $0.folder?.id != folderID }
        guard !changed.isEmpty else {
            return .committed(
                requestedCount: requestedCount,
                matchedCount: matched.count,
                committedCount: 0
            )
        }

        guard performStandaloneMutation({
            let now = Date()
            for recording in changed {
                recording.folder = targetFolder
                recording.updatedAt = now
            }
        }) else {
            return .failed(
                requestedCount: requestedCount,
                matchedCount: matched.count,
                failure: .persistenceFailed
            )
        }
        return .committed(
            requestedCount: requestedCount,
            matchedCount: matched.count,
            committedCount: changed.count
        )
    }
}
