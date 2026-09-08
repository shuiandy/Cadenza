import Foundation
import SwiftData

/// Persistent-history retention.
///
/// SwiftData records every save in the store's history tables and never
/// prunes them, and nothing in Cadenza reads that history. On a real library
/// it had grown to 272 MB of a 293 MB store: every boot-time probe, every
/// startup backup and every Time Machine pass paid for rows no one consumes.
extension RecordingsStore {
    /// Transactions older than this are deleted. Long enough to reconstruct a
    /// recent sync incident from history, short enough that the tables stay a
    /// few megabytes.
    nonisolated static let historyRetention: TimeInterval = 7 * 24 * 60 * 60

    struct HistoryPruneOutcome: Sendable, Equatable {
        var slicesDeleted: Int
        var oldestRemaining: Date?
    }

    enum HistoryPruneStep: Equatable, Sendable {
        /// One slice was deleted; call again for the next.
        case deleted
        /// Nothing older than the cutoff remains.
        case nothingToDo
        /// The delete failed or made no progress; stop.
        case failed
    }

    /// Deletes ONE time slice of history older than `cutoff` and returns. The
    /// caller loops with an `await` between calls: this actor has no suspension
    /// point inside a slice, so looping here would hold the store for the whole
    /// backlog and every list, detail and MCP call would queue behind it.
    func pruneHistorySlice(
        olderThan cutoff: Date,
        sliceLength: TimeInterval = 24 * 60 * 60
    ) -> HistoryPruneStep {
        guard let oldest = oldestHistoryTimestamp(), oldest < cutoff else { return .nothingToDo }
        let sliceEnd = min(oldest.addingTimeInterval(sliceLength), cutoff)
        let descriptor = HistoryDescriptor<DefaultHistoryTransaction>(
            predicate: #Predicate { $0.timestamp < sliceEnd }
        )
        do {
            try modelContext.deleteHistory(descriptor)
        } catch {
            NSLog("[RecordingsStore] history prune failed: %@", error.localizedDescription)
            return .failed
        }
        // Fail closed against a predicate that deletes nothing: without
        // progress a caller's loop would never end.
        if let remaining = oldestHistoryTimestamp(), remaining <= oldest {
            NSLog("[RecordingsStore] history prune made no progress; stopping")
            return .failed
        }
        return .deleted
    }

    /// All slices in one actor turn. Diagnostic and test use only; the app
    /// drives `pruneHistorySlice` from AppState with a yield between slices.
    func pruneHistory(
        olderThan cutoff: Date,
        sliceLength: TimeInterval = 24 * 60 * 60
    ) -> HistoryPruneOutcome {
        var slices = 0
        while pruneHistorySlice(olderThan: cutoff, sliceLength: sliceLength) == .deleted {
            slices += 1
        }
        return HistoryPruneOutcome(slicesDeleted: slices, oldestRemaining: oldestHistoryTimestamp())
    }

    func oldestHistoryTimestamp() -> Date? {
        var descriptor = HistoryDescriptor<DefaultHistoryTransaction>()
        descriptor.fetchLimit = 1
        descriptor.sortBy = [SortDescriptor(\.timestamp, order: .forward)]
        return (try? modelContext.fetchHistory(descriptor))?.first?.timestamp
    }

    /// Boot-path wrapper around `SQLiteStoreMaintenance`: bounded, logged,
    /// never throws. A compaction problem must not keep the store from opening.
    nonisolated static func reclaimFreePagesBeforeOpen(at storeURL: URL) {
        do {
            if let outcome = try SQLiteStoreMaintenance.reclaimFreePagesIfNeeded(at: storeURL) {
                NSLog(
                    "[RecordingsStore] reclaimed %.1f MB of free pages before open (%d free pages remain)",
                    Double(outcome.reclaimedBytes) / 1_048_576, outcome.freePagesAfter
                )
            }
        } catch {
            NSLog("[RecordingsStore] free-page reclaim skipped: %@", String(describing: error))
        }
    }

    /// Diagnostic and test aid. Materializes every retained transaction, so
    /// only call it on stores that are already pruned or small.
    func historyTransactionCount() -> Int {
        (try? modelContext.fetchHistory(HistoryDescriptor<DefaultHistoryTransaction>()))?.count ?? 0
    }
}
