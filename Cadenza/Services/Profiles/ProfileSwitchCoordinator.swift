import AppKit
import Foundation

/// Relaunch-based profile switching (spec §7): the switch writes the
/// target into the registry and restarts the process — the single-profile
/// assumption of every runtime component makes an in-process switch
/// structurally impossible, so a relaunch is the only transition.
///
/// Every active-profile write commits through a classification: a thrown
/// save re-reads the registry and proves committed (relaunch), proves the
/// old shape (retryable failure), or stays ambiguous — in which case the
/// process must stop serving data and require a restart, never continue
/// normal runtime under an unclassified authority.
@MainActor
enum ProfileSwitchCoordinator {
    enum Refusal: Equatable {
        case recordingActive
        case postProcessingActive
        case storageMigrationActive
        case operationInFlight
        case targetMissing
        case targetLocked
        case alreadyActive
    }

    /// INV-13 guards, evaluated against live process state and the fresh
    /// registry document. Nil means the switch may proceed.
    static func refusal(
        document: ProfileRegistryDocument,
        targetID: UUID,
        isRecording: Bool,
        isPostProcessing: Bool,
        isStorageMigrationActive: Bool
    ) -> Refusal? {
        if isRecording { return .recordingActive }
        if isPostProcessing { return .postProcessingActive }
        if isStorageMigrationActive { return .storageMigrationActive }
        if document.pendingBinding != nil || document.pendingTransfer != nil {
            return .operationInFlight
        }
        guard let target = document.profiles.first(where: { $0.id == targetID }) else {
            return .targetMissing
        }
        if target.isLocked { return .targetLocked }
        if document.activeProfileID == targetID { return .alreadyActive }
        return nil
    }

    enum CommitOutcome: Equatable {
        /// The registry durably names the target — relaunch immediately.
        case committed
        /// The registry provably still holds the old shape — retryable.
        case notCommitted(String)
        /// The write result cannot be classified; normal runtime must not
        /// continue.
        case indeterminate(String)
    }

    /// Classified active-profile commit: preconditions run against the
    /// fresh document, the mutation applies every field the transition
    /// carries, and the save commits the full intended shape. A thrown
    /// save is classified by exact document comparison — the target ID
    /// alone cannot distinguish outcomes when the target was already
    /// active (same-profile disposition or unlock transitions), so only
    /// the exact intended shape proves committed, only the exact old
    /// shape proves not-committed, and any third shape is indeterminate.
    static func commitActiveProfile(
        to targetID: UUID,
        registry: ProfileRegistryProviding,
        precondition: (ProfileRegistryDocument) -> String?,
        mutate: (inout ProfileRegistryDocument) -> Void
    ) -> CommitOutcome {
        let old: ProfileRegistryDocument
        do {
            old = try registry.load()
        } catch {
            // Authority unknown before any write: the process cannot even
            // prove the old shape, so this is never presented as merely
            // retryable.
            return .indeterminate("registry unreadable before commit: \(error)")
        }
        if let problem = precondition(old) {
            return .notCommitted(problem)
        }
        var intended = old
        mutate(&intended)
        intended.activeProfileID = targetID
        return classifiedSave(old: old, intended: intended, registry: registry)
    }

    /// Shared classification for every runtime registry write: the save
    /// can throw after the atomic replace already landed the intended
    /// document, so a thrown save re-reads and proves committed, proves
    /// the old shape (retryable), or stays indeterminate. Byte-level
    /// comparison through the deterministic registry encoder (sorted
    /// keys, epoch dates): synthesized String equality treats NFC and
    /// NFD spellings as equal, so a concurrent writer differing only by
    /// canonical representation could otherwise masquerade as the exact
    /// old or intended shape.
    nonisolated static func classifiedSave(
        old: ProfileRegistryDocument,
        intended: ProfileRegistryDocument,
        registry: ProfileRegistryProviding
    ) -> CommitOutcome {
        do {
            try registry.save(intended)
            return .committed
        } catch {
            guard let intendedBytes = encodedFingerprint(intended),
                  let oldBytes = encodedFingerprint(old) else {
                return .indeterminate("intended registry shape unencodable")
            }
            do {
                let reread = try registry.load()
                guard let rereadBytes = encodedFingerprint(reread) else {
                    return .indeterminate("reread registry shape unencodable")
                }
                if rereadBytes == intendedBytes {
                    return .committed
                }
                if rereadBytes == oldBytes {
                    return .notCommitted(String(describing: error))
                }
                return .indeterminate("registry in an unexpected shape after failed commit")
            } catch let rereadError {
                return .indeterminate(
                    "registry unreadable after failed commit: \(rereadError)"
                )
            }
        }
    }

    nonisolated private static func encodedFingerprint(_ document: ProfileRegistryDocument) -> Data? {
        try? ProfileRegistryCoding.makeEncoder().encode(document)
    }

    /// The user-facing switch: INV-13 guards as the precondition, the
    /// target stamped as most recently active.
    static func performSwitch(
        to targetID: UUID,
        registry: ProfileRegistryProviding,
        isRecording: Bool,
        isPostProcessing: Bool,
        isStorageMigrationActive: Bool,
        now: () -> Date = { Date() }
    ) -> CommitOutcome {
        let stamp = now()
        return commitActiveProfile(
            to: targetID,
            registry: registry,
            precondition: { document in
                if let refusal = refusal(
                    document: document,
                    targetID: targetID,
                    isRecording: isRecording,
                    isPostProcessing: isPostProcessing,
                    isStorageMigrationActive: isStorageMigrationActive
                ) {
                    return String(describing: refusal)
                }
                return nil
            },
            mutate: { document in
                if let index = document.profiles.firstIndex(where: { $0.id == targetID }) {
                    document.profiles[index].lastActiveAt = stamp
                }
            }
        )
    }

    /// Starts a fresh instance and terminates this one only once the new
    /// instance provably launched. On failure the current process stays
    /// alive and the caller decides between rolling the active ID back and
    /// entering the transition-halted state.
    static func relaunch(onFailure: @escaping @MainActor (String) -> Void) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL, configuration: configuration
        ) { application, error in
            DispatchQueue.main.async {
                if application != nil {
                    NSApp.terminate(nil)
                } else {
                    let detail = error.map { String(describing: $0) } ?? "no application handle"
                    NSLog("[ProfileSwitch] relaunch failed: %@", detail)
                    onFailure(detail)
                }
            }
        }
    }
}
