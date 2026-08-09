import Foundation

/// Mutual exclusion between storage-directory migration and the work that
/// assumes a stable root. Bidirectional: Settings claims the migration side
/// atomically and is refused while any activity lease is held; recording
/// start, stop finalization, and crash recovery hold activity leases and
/// are refused while a migration is claimed.
///
/// MainActor-confined — every participant (Settings flow, RecordingEngine
/// lifecycle, PostProcessingCoordinator recovery) already runs there, so
/// claim checks and state changes are a single atomic step.
@MainActor
final class StorageMigrationGate {
    static let shared = StorageMigrationGate()

    private(set) var isMigrationClaimed = false
    private var activityLeases: Set<UUID> = []
    /// Terminal blocked state: a root commit that could not be classified
    /// leaves the registry and the in-process root authority possibly
    /// split, so every root-dependent surface stays refused until the
    /// process restarts. Nothing clears this in-process.
    private(set) var isPoisonedUntilRestart = false

    /// Atomic claim for the migration side; fails while any activity lease
    /// is outstanding. Balance with `releaseMigration`.
    func claimMigration() -> Bool {
        guard !isPoisonedUntilRestart, !isMigrationClaimed, activityLeases.isEmpty else {
            return false
        }
        isMigrationClaimed = true
        return true
    }

    func releaseMigration() {
        // The poisoned state is terminal: the owning flow's unconditional
        // release must not reopen recording under a split authority.
        guard !isPoisonedUntilRestart else { return }
        isMigrationClaimed = false
    }

    /// Enters the terminal blocked state. Callable while the migration
    /// claim is held (the settings flow owns the claim when the
    /// indeterminate commit surfaces); the claim stays visibly held so
    /// recording, transitions, and further migrations all keep refusing.
    func markIndeterminate() {
        isPoisonedUntilRestart = true
        isMigrationClaimed = true
    }

    /// Lease for root-dependent work (recording from start through stop
    /// finalization, crash recovery). nil while a migration is claimed.
    /// Balance with `releaseActivity`.
    func claimActivity() -> UUID? {
        guard !isPoisonedUntilRestart, !isMigrationClaimed else { return nil }
        let lease = UUID()
        activityLeases.insert(lease)
        return lease
    }

    func releaseActivity(_ lease: UUID?) {
        guard let lease else { return }
        activityLeases.remove(lease)
    }

#if DEBUG
    /// Test-only reset of the terminal state so a poisoned-gate test
    /// cannot contaminate other suites.
    func resetPoisonForTesting() {
        isPoisonedUntilRestart = false
        isMigrationClaimed = false
        activityLeases.removeAll()
    }
#endif
}
