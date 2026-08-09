import Foundation

/// Bulk "export everything that's missing" for Notion / Craft.
///
/// Dedup source of truth differs per destination:
/// - Notion: the backend's persisted Idempotency-Key ledger
///   (`GET integrations/notion/exported-ids`) — covers manual exports and
///   auto-export too, since they all go through the same export-page path.
/// - Craft: `CraftExportService.exportedRecordingIDs` (craftdocs:// is
///   write-only; a local ledger is the only option).
///
/// All dependencies are injected as closures (wired in AppState.init)
/// so the state machine is testable without network or SwiftData. Lives on
/// ExportService — AppState lifetime — so closing Settings doesn't stop a run.
@Observable @MainActor
final class BulkExportCoordinator {

    enum Destination: String, Sendable {
        case notion
        case craft
    }

    enum Phase: Equatable {
        case idle
        /// Fetching the exported ledger and diffing.
        case preparing(Destination)
        /// Diff done — waiting for the user to confirm the alert.
        case confirming(Destination, pending: Int)
        /// Nothing missing (transient result state).
        case upToDate(Destination)
        case running(Destination, done: Int, total: Int)
        case finished(Destination, succeeded: Int, failed: Int)
        case failed(Destination, message: String)
        case cancelled(Destination, exported: Int)
    }

    struct Dependencies {
        var listRecordings: @MainActor () async -> [RecordingDTO]
        var fetchDetail: @MainActor (UUID) async -> RecordingDetailDTO?
        var notionExportedIDs: @MainActor () async throws -> Set<UUID>
        var exportToNotion: @MainActor (RecordingDetailDTO) async throws -> Void
        var craftExportedIDs: @MainActor () -> Set<UUID>
        var exportToCraft: @MainActor (RecordingDetailDTO) async throws -> Void
        /// Pause between items. Craft needs ~0.4s between URL-scheme opens;
        /// tests inject .zero.
        var interItemDelay: @MainActor (Destination) -> Duration
    }

    var phase: Phase = .idle
    @ObservationIgnored var dependencies: Dependencies?

    @ObservationIgnored private var pendingIDs: [UUID] = []
    @ObservationIgnored private var cancelRequested = false

    /// True while a run (or its confirmation) is in flight — both rows'
    /// buttons disable on this, making the two destinations mutually exclusive.
    var isBusy: Bool {
        switch phase {
        case .preparing, .confirming, .running: return true
        case .idle, .upToDate, .finished, .failed, .cancelled: return false
        }
    }

    // MARK: - Prepare (fetch ledger + diff)

    func prepare(_ destination: Destination) async {
        guard !isBusy, let deps = dependencies else { return }
        phase = .preparing(destination)

        let exported: Set<UUID>
        switch destination {
        case .notion:
            do { exported = try await deps.notionExportedIDs() }
            catch {
                guard case .preparing(let d) = phase, d == destination else { return }
                phase = .failed(destination, message: Self.message(for: error))
                return
            }
        case .craft:
            exported = deps.craftExportedIDs()
        }

        let all = await deps.listRecordings()
        // A disconnect/cancel may have reset the phase while we awaited.
        guard case .preparing(let d) = phase, d == destination else { return }

        // Oldest-first list order is the export order (page creation order in
        // Notion then matches the meeting timeline). Recordings with neither
        // transcript nor summary have nothing to export.
        pendingIDs = all
            .filter { $0.hasTranscript || $0.hasSummary }
            .filter { !exported.contains($0.id) }
            .map(\.id)

        phase = pendingIDs.isEmpty
            ? .upToDate(destination)
            : .confirming(destination, pending: pendingIDs.count)
    }

    func dismissConfirmation() {
        if case .confirming = phase { phase = .idle }
    }

    /// Clears a transient result row (upToDate / finished / failed / cancelled).
    func dismissResult() {
        switch phase {
        case .upToDate, .finished, .failed, .cancelled: phase = .idle
        case .idle, .preparing, .confirming, .running: break
        }
    }

    // MARK: - Run

    func confirmAndStart() async {
        guard let claim = claimConfirmedRun() else { return }
        await run(destination: claim.destination, ids: claim.ids)
    }

    /// Synchronous UI entry point for the alert's confirm button. The phase
    /// flip (.confirming → .running) MUST happen synchronously in the button
    /// action: SwiftUI dismisses the alert (set(false) → dismissConfirmation())
    /// in the same MainActor turn, BEFORE any Task body runs — a deferred flip
    /// would let dismissConfirmation see .confirming and reset to .idle,
    /// silently killing the run.
    func beginConfirmedRun() {
        guard let claim = claimConfirmedRun() else { return }
        Task { await run(destination: claim.destination, ids: claim.ids) }
    }

    /// Claims the confirmed run: snapshots pending ids and flips to .running.
    private func claimConfirmedRun() -> (destination: Destination, ids: [UUID])? {
        guard case .confirming(let destination, _) = phase, dependencies != nil else { return nil }
        cancelRequested = false
        let ids = pendingIDs
        pendingIDs = []
        phase = .running(destination, done: 0, total: ids.count)
        return (destination, ids)
    }

    private func run(destination: Destination, ids: [UUID]) async {
        guard let deps = dependencies else { return }
        var succeeded = 0
        var failed = 0

        for (index, id) in ids.enumerated() {
            if cancelRequested {
                phase = .cancelled(destination, exported: succeeded)
                return
            }
            do {
                guard let detail = await deps.fetchDetail(id) else {
                    // Deleted between diff and export — count as failed, move on.
                    failed += 1
                    phase = .running(destination, done: index + 1, total: ids.count)
                    continue
                }
                switch destination {
                case .notion: try await deps.exportToNotion(detail)
                case .craft: try await deps.exportToCraft(detail)
                }
                succeeded += 1
            } catch {
                if Self.isAuthFailure(error) {
                    // The bearer is dead — every remaining item would fail
                    // identically. Abort instead of burning the whole queue.
                    phase = .failed(destination, message: Self.message(for: error))
                    return
                }
                failed += 1
            }
            phase = .running(destination, done: index + 1, total: ids.count)

            let delay = deps.interItemDelay(destination)
            if delay > .zero, index < ids.count - 1 {
                // Run cancellation flows through cancelRequested, not Task
                // cancellation — a cancelled sleep just skips the pace delay.
                try? await Task.sleep(for: delay)
            }
        }
        // A cancel that lands during the LAST in-flight item arrives too late
        // for the top-of-loop check — still honor it as the end state.
        phase = cancelRequested
            ? .cancelled(destination, exported: succeeded)
            : .finished(destination, succeeded: succeeded, failed: failed)
    }

    /// User-initiated cancel from the running row. Takes effect after the
    /// in-flight item finishes (its export is already committed remotely).
    func cancel() {
        if case .running = phase { cancelRequested = true }
    }

    /// Disconnect path: abort whatever this destination has in flight,
    /// including a pending confirmation or prepare.
    func cancelActiveRun(for destination: Destination) {
        switch phase {
        case .running(let d, _, _) where d == destination:
            cancelRequested = true
        case .confirming(let d, _) where d == destination,
             .preparing(let d) where d == destination:
            phase = .idle
        default:
            break
        }
    }

    private static func isAuthFailure(_ error: Error) -> Bool {
        switch error {
        case CadenzaAPIError.notSignedIn, CadenzaAPIError.unauthorized:
            return true
        case AuthError.integrationReauthRequired:
            return true
        default:
            return false
        }
    }

    // MARK: - Errors

    static func message(for error: Error) -> String {
        // A 404 from the proxy means the backend predates the exported-ids
        // endpoint — CadenzaAPIError can't know that semantic, so map it here.
        // Shape depends on the 404 body: decodable error envelope →
        // CadenzaAPIError.backend, anything else → AuthError.server.
        switch error {
        case CadenzaAPIError.backend(_, 404),
             AuthError.server(status: 404):
            return String(localized: "Bulk export needs a newer Cadenza backend (exported-ids endpoint missing).")
        default:
            // CadenzaAPIError / AuthError both carry rich localized
            // errorDescriptions — don't re-map them here and drift.
            return error.localizedDescription
        }
    }
}
