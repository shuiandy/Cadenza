import Foundation

/// Shares speaker profiles and voice samples with the account's other devices.
///
/// One pass pulls what other devices changed since the last cursor, applies
/// it, then pushes what this device changed. Profiles follow the server's
/// speaker identity switch; samples additionally need the server's voice
/// profile switch and this device's own voice memory consent. The server
/// seals both and never compares vectors: each device matches only samples of
/// its own embedding model.
@MainActor
final class SpeakerProfileSync {
    enum PassResult: Equatable, Sendable {
        case notDue
        /// The backend does not serve speaker sync yet (404); retried later.
        case unavailable
        case identityOff
        case completed
        /// Stopped because the session changed or the task was cancelled.
        case abandoned
        case failed
    }

    static let minimumInterval: TimeInterval = 5 * 60
    static let unavailableBackoff: TimeInterval = 6 * 60 * 60
    static let pageLimit = 200
    /// Bounds a pull against a server that keeps reporting more without
    /// advancing its cursor.
    static let maxPagesPerPass = 500

    private enum Failure: Error {
        case storeUnavailable
        case cursorStalled
    }

    private struct RemoteState {
        let identityGeneration: Int64
        let voiceEnabled: Bool
        let voiceGeneration: Int64
    }

    private let store: RecordingsStore
    private let transport: SpeakerProfileSyncTransport
    private let defaults: UserDefaults
    private let modelVersion: String
    private let now: () -> Date
    private var lastPassAt: [String: Date] = [:]
    private var unavailableUntil: Date?

    init(
        store: RecordingsStore,
        transport: SpeakerProfileSyncTransport,
        defaults: UserDefaults = .standard,
        modelVersion: String = SpeakerKitEmbeddingExtractor.currentModelVersion,
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.transport = transport
        self.defaults = defaults
        self.modelVersion = modelVersion
        self.now = now
    }

    /// Runs a pass unless one ran for this ledger within `minimumInterval`.
    /// `ledgerKey` scopes the state to one local profile store and account;
    /// `isCurrent` is checked after every suspension, and a pass that finds
    /// the session changed stops without writing anything further.
    func runPassIfDue(
        ledgerKey: String,
        isCurrent: @escaping @MainActor () -> Bool
    ) async -> PassResult {
        let start = now()
        if let unavailableUntil, start < unavailableUntil { return .unavailable }
        if let last = lastPassAt[ledgerKey], start.timeIntervalSince(last) < Self.minimumInterval {
            return .notDue
        }
        lastPassAt[ledgerKey] = start
        return await runPass(ledgerKey: ledgerKey, isCurrent: isCurrent)
    }

    func runPass(
        ledgerKey: String,
        isCurrent: @escaping @MainActor () -> Bool
    ) async -> PassResult {
        var ledger = loadLedger(ledgerKey)
        do {
            guard let state = try await pullAndApply(
                ledger: &ledger, ledgerKey: ledgerKey, isCurrent: isCurrent
            ) else {
                return .identityOff
            }
            try await push(state: state, ledger: &ledger, ledgerKey: ledgerKey, isCurrent: isCurrent)
            return .completed
        } catch {
            return classify(error)
        }
    }

    // MARK: - Pull

    /// Pulls until caught up, applying each page. Nil when identity is off.
    private func pullAndApply(
        ledger: inout SpeakerProfileSyncLedger,
        ledgerKey: String,
        isCurrent: @MainActor () -> Bool
    ) async throws -> RemoteState? {
        for _ in 0..<Self.maxPagesPerPass {
            let since = ledger.cursor
            let page = try await transport.pullSpeakerChanges(
                since: since, limit: Self.pageLimit, modelVersions: [modelVersion]
            )
            try ensureCurrent(isCurrent)
            guard page.identityEnabled else { return nil }

            if ledger.identityGeneration != page.identityGeneration
                || ledger.voiceGeneration != page.voiceGeneration {
                // First contact, or the server purged after a consent change:
                // nothing recorded here describes the server any more, so
                // everything is re-pulled and re-sent.
                let hadHistory = since != 0
                ledger = SpeakerProfileSyncLedger(
                    identityGeneration: page.identityGeneration,
                    voiceGeneration: page.voiceGeneration
                )
                saveLedger(ledger, key: ledgerKey)
                if hadHistory { continue }
            }

            try await apply(page, ledger: &ledger, isCurrent: isCurrent)
            ledger.cursor = max(ledger.cursor, page.cursor)
            saveLedger(ledger, key: ledgerKey)

            if !page.hasMore {
                return RemoteState(
                    identityGeneration: page.identityGeneration,
                    voiceEnabled: page.voiceEnabled,
                    voiceGeneration: page.voiceGeneration
                )
            }
            guard page.cursor > since else { throw Failure.cursorStalled }
        }
        throw Failure.cursorStalled
    }

    private func apply(
        _ page: SpeakerSyncPullResponse,
        ledger: inout SpeakerProfileSyncLedger,
        isCurrent: @MainActor () -> Bool
    ) async throws {
        guard !page.profiles.isEmpty || !page.samples.isEmpty else { return }
        guard let local = await store.speakerSyncSnapshot(modelVersion: modelVersion) else {
            throw Failure.storeUnavailable
        }
        try ensureCurrent(isCurrent)
        let plan = SpeakerProfileSyncPlanner.planApply(
            profiles: page.profiles,
            samples: page.samples,
            local: local,
            ledger: ledger,
            samplesAllowed: page.voiceEnabled && local.samplesConsented,
            modelVersion: modelVersion
        )
        var outcome = SpeakerSyncApplyOutcome()
        if plan.hasStoreWork {
            guard let applied = await store.applySpeakerSyncChanges(plan) else {
                throw Failure.storeUnavailable
            }
            outcome = applied
            NSLog(
                "[SpeakerSync] applied %d profile(s), %d profile deletion(s), %d sample(s), %d sample removal(s)",
                applied.appliedProfiles.count,
                plan.profileDeletions.count,
                applied.appliedSamples.count,
                applied.removedSamples.count
            )
        }
        try ensureCurrent(isCurrent)
        SpeakerProfileSyncPlanner.record(plan: plan, outcome: outcome, into: &ledger)
    }

    // MARK: - Push

    private func push(
        state: RemoteState,
        ledger: inout SpeakerProfileSyncLedger,
        ledgerKey: String,
        isCurrent: @MainActor () -> Bool
    ) async throws {
        guard let local = await store.speakerSyncSnapshot(modelVersion: modelVersion) else {
            throw Failure.storeUnavailable
        }
        try ensureCurrent(isCurrent)
        let samplesAllowed = state.voiceEnabled && local.samplesConsented
        let plan = SpeakerProfileSyncPlanner.planPush(
            local: local,
            ledger: ledger,
            samplesAllowed: samplesAllowed,
            modelVersion: modelVersion
        )

        if !plan.missingLocalProfiles.isEmpty {
            // Profiles the server has but this store lost (a restore from an
            // older backup): forget them and re-pull from the start next
            // pass, which brings them back instead of deleting them remotely.
            for id in plan.missingLocalProfiles {
                ledger.profiles.removeValue(forKey: id)
            }
            ledger.cursor = 0
            lastPassAt[ledgerKey] = nil
            saveLedger(ledger, key: ledgerKey)
            NSLog("[SpeakerSync] %d profile(s) missing locally; re-pulling", plan.missingLocalProfiles.count)
        }

        let requests = SpeakerProfileSyncPlanner.requests(
            for: plan,
            identityGeneration: state.identityGeneration,
            voiceGeneration: samplesAllowed ? state.voiceGeneration : nil
        )
        for request in requests {
            let response = try await transport.pushSpeakerChanges(request)
            try ensureCurrent(isCurrent)
            SpeakerProfileSyncPlanner.record(pushed: request, response: response, into: &ledger)
            saveLedger(ledger, key: ledgerKey)
        }
        if !requests.isEmpty {
            NSLog(
                "[SpeakerSync] pushed %d profile(s), %d sample(s), %d sample deletion(s)",
                plan.profiles.count, plan.samples.count, plan.deletedSamples.count
            )
        }
    }

    // MARK: - Support

    private func ensureCurrent(_ isCurrent: @MainActor () -> Bool) throws {
        guard isCurrent(), !Task.isCancelled else { throw CancellationError() }
    }

    private func classify(_ error: Error) -> PassResult {
        switch error {
        case is CancellationError:
            return .abandoned
        case CadenzaAPIError.backend(_, let status) where status == 404,
             AuthError.server(let status) where status == 404:
            unavailableUntil = now().addingTimeInterval(Self.unavailableBackoff)
            NSLog("[SpeakerSync] backend does not serve speaker sync yet")
            return .unavailable
        case CadenzaAPIError.backend(let envelope, let status):
            // consent_off / consent_stale mean a switch changed between the
            // pull and the push; the next pass pulls the new state.
            NSLog("[SpeakerSync] backend refused: %d %@", status, envelope.code)
            return .failed
        default:
            NSLog("[SpeakerSync] pass failed: %@", String(describing: error))
            return .failed
        }
    }

    private func loadLedger(_ key: String) -> SpeakerProfileSyncLedger {
        guard let data = defaults.data(forKey: key),
              let ledger = try? JSONDecoder().decode(SpeakerProfileSyncLedger.self, from: data) else {
            return SpeakerProfileSyncLedger()
        }
        return ledger
    }

    private func saveLedger(_ ledger: SpeakerProfileSyncLedger, key: String) {
        guard let data = try? JSONEncoder().encode(ledger) else { return }
        defaults.set(data, forKey: key)
    }
}
