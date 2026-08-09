import Foundation

@Observable @MainActor
final class WebSyncCoordinator {
    private let store: RecordingsStore
    private let api: WebSyncAPIClient
    private let fileReader: WebSyncFileReader
    private let defaults: UserDefaults
    private let isEnabled: Bool
    private let shouldPauseHistoricalAudio: @MainActor () -> Bool
    private var worker: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    /// Tracked store write for the active-user handoff; part of the drain
    /// contract like every other coordinator task.
    private var sessionStateTask: Task<Void, Never>?
    /// Tracked entitlement fetch, drained with every other coordinator task so
    /// a profile transition cannot leave one mutating the next profile's gate.
    private var entitlementsTask: Task<Void, Never>?
    private var activeUser: CadenzaAuthService.SignedInUser?
    /// Set by `stopAndWait` before cancellation: session changes may
    /// update cached state but must not spawn workers or store tasks
    /// while a profile transition is in flight; `resume` rehydrates.
    private(set) var isSuspended = false

    private(set) var isSyncing = false
    private(set) var lastError: String?
    /// Monotonic publication counter used to distinguish a successful manual
    /// retry from a pass that produced a fresh failure with identical prose.
    private var lastErrorRevision: UInt = 0
    /// Per-profile historical-sync consent (spec 6.6), injected so tests
    /// pin the tri-state explicitly; the default reads the active
    /// profile's scoped key from the injected defaults.
    private let historicalConsent: () -> HistoricalSyncConsent

    /// When the entitlement snapshot is fetched automatically.
    ///
    /// This governs fetching only. The gate always decides what may transfer,
    /// so pinning `never` suppresses network traffic without relaxing a single
    /// gate: an account with no authority still cannot start an audio
    /// transfer.
    enum EntitlementsRefreshPolicy: Sendable {
        /// Fetched once per session install and resume, and on explicit
        /// request.
        case onSessionBoundaries
        case never
    }

    /// Entitlement knowledge and local pauses for the bound account. Read-only
    /// to callers: the surface that presents it is not this task's to design.
    let entitlements = EntitlementsGate()
    private let auth: CadenzaAuthService
    private let entitlementsRefreshPolicy: EntitlementsRefreshPolicy

    init(
        store: RecordingsStore,
        auth: CadenzaAuthService,
        fileReader: WebSyncFileReader = WebSyncFileReader(),
        defaults: UserDefaults = .standard,
        startAutomatically: Bool = true,
        shouldPauseHistoricalAudio: @escaping @MainActor () -> Bool = { false },
        migrationGate: StorageMigrationGate = .shared,
        historicalConsent: (@MainActor () -> HistoricalSyncConsent)? = nil,
        entitlementsRefreshPolicy: EntitlementsRefreshPolicy = .onSessionBoundaries
    ) {
        self.entitlementsRefreshPolicy = entitlementsRefreshPolicy
        self.migrationGate = migrationGate
        self.historicalConsent = historicalConsent
            ?? { HistoricalSyncConsent.readActiveProfile(defaults: defaults) }
        self.store = store
        self.auth = auth
        self.api = WebSyncAPIClient(auth: auth)
        self.fileReader = fileReader
        self.defaults = defaults
        self.isEnabled = startAutomatically
        self.shouldPauseHistoricalAudio = shouldPauseHistoricalAudio
        auth.onSessionChanged = { [weak self] state, user in
            self?.sessionChanged(state: state, user: user)
        }
        if startAutomatically {
            sessionChanged(state: auth.sessionState, user: auth.currentUser)
        }
    }

    func sessionChanged(
        state: CadenzaAuthService.SessionState,
        user: CadenzaAuthService.SignedInUser?
    ) {
        guard isEnabled else { return }
        worker?.cancel()
        worker = nil
        recoveryTask?.cancel()
        recoveryTask = nil
        entitlementsTask?.cancel()
        entitlementsTask = nil
        // A signed-in user is only an active sync user when it is the account
        // this profile is frozen to. A session naming anyone else activates
        // nothing: no store column, no worker, no request.
        let candidate = state == .signedIn ? user : nil
        let authority = boundAuthority(for: candidate)
        // The gate follows the session on every boundary, including the
        // suspended one: a transition must not leave the previous account's
        // knowledge readable.
        entitlements.bind(to: authority)
        activeUser = authority == nil ? nil : candidate
        guard !isSuspended else { return }
        sessionStateTask?.cancel()
        guard let user = activeUser else {
            isSyncing = false
            sessionStateTask = Task { [store] in await store.setActiveWebSyncUserID(nil) }
            return
        }
        sessionStateTask = Task { [store] in await store.setActiveWebSyncUserID(user.id) }
        refreshEntitlements()
        recoverRolloutFailuresAndReconcile(userID: user.id)
    }

    func stop() {
        worker?.cancel()
        worker = nil
        recoveryTask?.cancel()
        recoveryTask = nil
        entitlementsTask?.cancel()
        entitlementsTask = nil
        isSyncing = false
    }

    /// Cancels and awaits every coordinator task within the bound: true
    /// means no upload or store handler can still be running. Suspends the
    /// coordinator first so a session change published during the
    /// transition cannot spawn a fresh store write behind the drain.
    func stopAndWait(timeout: Duration = .seconds(3)) async -> Bool {
        isSuspended = true
        let tasks = [worker, recoveryTask, sessionStateTask, entitlementsTask].compactMap { $0 }
        stop()
        sessionStateTask?.cancel()
        sessionStateTask = nil
        return await TaskDrain.awaitAll(tasks, timeout: timeout)
    }

    /// Explicit rehydration after a transition that provably did not
    /// commit: the old profile's services come back exactly once. The
    /// store's active-user column is republished unconditionally — the
    /// session may have ended while suspended, and leaving the stale ID
    /// in place would keep the old account's rows treated as active.
    func resume() {
        guard isSuspended else { return }
        isSuspended = false
        let user = activeUser
        sessionStateTask = Task { [store] in await store.setActiveWebSyncUserID(user?.id) }
        guard let user else {
            isSyncing = false
            return
        }
        refreshEntitlements()
        recoverRolloutFailuresAndReconcile(userID: user.id)
    }

    /// The authority the bound profile and the signed-in user together name.
    /// Nil while unbound or signed out, and nil when the session user is not
    /// the account the profile is bound to.
    private func boundAuthority(
        for user: CadenzaAuthService.SignedInUser?
    ) -> EntitlementsAuthority? {
        guard let user, let identity = auth.boundIdentity else { return nil }
        guard let authority = EntitlementsAuthority(
            profileID: identity.profileID, bound: identity.account
        ), authority.owns(userID: user.id) else {
            return nil
        }
        return authority
    }

    /// Fetches the entitlement snapshot once for the bound account.
    ///
    /// This runs when a session is installed, when the coordinator resumes, and
    /// on explicit request, never on the worker's timer: entitlements change
    /// when a purchase or a downgrade lands, not on a schedule. The result is
    /// applied only if the same authority is still bound when it returns.
    func refreshEntitlements() {
        guard isEnabled, !isSuspended, entitlementsRefreshPolicy == .onSessionBoundaries else { return }
        guard let authority = entitlements.authority else { return }
        entitlementsTask?.cancel()
        entitlementsTask = Task { [weak self] in
            guard let self else { return }
            let resolution = await api.fetchEntitlements(service: authority.service)
            guard !Task.isCancelled, isActiveUser(authority.bound.userID) else { return }
            let applied = entitlements.apply(resolution, for: authority)
            if !applied.reopened.isEmpty {
                await requeueEntitlementFailures(applied.reopened, userID: authority.bound.userID)
            }
            // New knowledge and a lifted refusal can each make work runnable,
            // even when the authoritative snapshot itself did not change.
            guard (applied.learned || !applied.reopened.isEmpty),
                  isActiveUser(authority.bound.userID),
                  !Task.isCancelled else {
                return
            }
            reconcile()
        }
    }

    /// Clears the parked retry schedule of rows a lifted refusal had stopped.
    ///
    /// Only the diagnostics that capability wrote are requeued, so reopening
    /// text does not revive a row still refused for audio, and neither touches
    /// a row parked for an unrelated reason.
    private func requeueEntitlementFailures(
        _ reopened: EntitlementsGate.Reopened, userID: String
    ) async {
        var codes: Set<String> = []
        if reopened.structured { codes.insert(Self.rejectionDiagnostic(.textQuotaExceeded)) }
        if reopened.audio {
            codes.insert(Self.rejectionDiagnostic(.audioUploadNotEntitled))
            codes.insert(Self.rejectionDiagnostic(.storageQuotaExceeded))
        }
        guard !codes.isEmpty else { return }
        do {
            let count = try await store.requeueWebSyncEntitlementFailures(userID: userID, codes: codes)
            if count > 0 {
                NSLog("[WebSync] requeued %d rows after an entitlement reopened", count)
            }
        } catch {
            NSLog("[WebSync] failed to requeue after an entitlement reopened: %@",
                  error.localizedDescription)
        }
    }

    /// Persists the profile's historical-sync consent and re-runs the
    /// reconciliation so newly-allowed rows enter the queue immediately.
    func updateHistoricalConsent(_ consent: HistoricalSyncConsent) {
        HistoricalSyncConsent.writeActiveProfile(consent, defaults: defaults)
        reconcile()
    }

    func audioUploadEnabled(userID: String) -> Bool {
        // Absent reads false: audio upload is default-off (spec 6.6) and
        // no login, migration, or consent path may switch it on for the
        // user — only this explicit toggle. Historical rows additionally
        // require the with-audio consent.
        guard let key = audioPreferenceKey(userID) else { return false }
        migrateLegacyAudioPreferenceIfNeeded(userID: userID, destinationKey: key)
        return defaults.object(forKey: key) as? Bool ?? false
    }

    func setAudioUploadEnabled(_ enabled: Bool) {
        guard let user = activeUser, let key = audioPreferenceKey(user.id) else { return }
        defaults.set(enabled, forKey: key)
        reconcile()
    }

    func recordingDidComplete(_ recordingID: UUID) {
        reconcile(priorityRecordingID: recordingID)
    }

    func recordingDidChange(_ recordingID: UUID) {
        reconcile(priorityRecordingID: recordingID)
    }

#if DEBUG
    /// Installs an entitlement resolution for the bound account without a
    /// fetch, so a test whose subject is transfer behavior can supply the
    /// authority the gate requires. It goes through the same apply path
    /// production uses, so no gate is relaxed.
    func installEntitlementsForTesting(_ resolution: EntitlementsResolution) {
        guard let authority = entitlements.authority else { return }
        // Publish the test knowledge through the production apply path, then
        // schedule a fresh reconciliation for the resulting gate state.
        worker?.cancel()
        worker = nil
        entitlements.apply(resolution, for: authority)
        reconcile()
    }

    /// Awaits exactly one reconcile pass for `user` — the deterministic
    /// drain tests use to prove a pass ran (and, for gated states,
    /// produced no traffic) without timing sleeps. Installs the active
    /// user for its own span the way the session pipeline would.
    func runOnePassForTesting(
        user: CadenzaAuthService.SignedInUser,
        entitlementResolution: EntitlementsResolution? = nil,
        userInitiatedRetry: Bool = false
    ) async {
        let previous = activeUser
        let authority = boundAuthority(for: user)
        entitlements.bind(to: authority)
        if let authority, let entitlementResolution {
            entitlements.apply(entitlementResolution, for: authority)
        }
        activeUser = authority == nil ? nil : user
        defer { activeUser = previous }
        guard activeUser != nil else { return }
        await store.setActiveWebSyncUserID(user.id)
        await run(
            userID: user.id,
            priorityRecordingID: nil,
            userInitiatedRetry: userInitiatedRetry
        )
    }
#endif

    func reconcile(priorityRecordingID: UUID? = nil) {
        scheduleReconcile(
            priorityRecordingID: priorityRecordingID,
            userInitiatedRetry: false
        )
    }

    /// Runs one explicit retry pass before returning to the normal cadence.
    /// The pass may bypass retry deadlines, but never a still-active
    /// entitlement refusal. A failed or deferred pass keeps `lastError`
    /// visible so the button cannot report success without durable evidence.
    func retryNow() {
        scheduleReconcile(priorityRecordingID: nil, userInitiatedRetry: true)
    }

    private func scheduleReconcile(
        priorityRecordingID: UUID?,
        userInitiatedRetry: Bool
    ) {
        guard isEnabled, !isSuspended else { return }
        guard let user = activeUser else { return }
        worker?.cancel()
        worker = Task { [weak self] in
            var priority = priorityRecordingID
            var isUserRetryPass = userInitiatedRetry
            while let self, self.isActiveUser(user.id), !Task.isCancelled {
                await self.run(
                    userID: user.id,
                    priorityRecordingID: priority,
                    userInitiatedRetry: isUserRetryPass
                )
                priority = nil
                isUserRetryPass = false
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    return
                }
            }
        }
    }

    private func recoverRolloutFailuresAndReconcile(userID: String) {
        guard let serverRecoveryKey = serverFailureRecoveryKey(userID) else { return }
        recoveryTask?.cancel()
        recoveryTask = Task { [weak self] in
            guard let self else { return }
            do {
                var count = try await store.requeueInitialWebSyncNotFoundFailures(userID: userID)
                if !defaults.bool(forKey: serverRecoveryKey) {
                    count += try await store.requeueInitialWebSyncServerFailures(userID: userID)
                    defaults.set(true, forKey: serverRecoveryKey)
                }
                guard isActiveUser(userID), !Task.isCancelled else { return }
                if count > 0 {
                    NSLog("[WebSync] requeued %d rollout failures for active account", count)
                }
            } catch {
                NSLog("[WebSync] failed to requeue rollout failures: %@", error.localizedDescription)
            }
            guard isActiveUser(userID), !Task.isCancelled else { return }
            reconcile()
        }
    }

    private func run(
        userID: String,
        priorityRecordingID: UUID?,
        userInitiatedRetry: Bool = false
    ) async {
        isSyncing = true
        defer { isSyncing = false }
        let errorRevisionBeforePass = lastErrorRevision
        let discoveredCandidates: [WebSyncCandidate]
        let syncRecords: [WebSyncRecordDTO]
        do {
            discoveredCandidates = try await store.fetchWebSyncCandidates(includeTrashed: true)
            syncRecords = try await store.fetchWebSyncRecords(userID: userID)
        } catch {
            let code = Self.diagnosticCode(for: error)
            publishError(error)
            NSLog("[WebSync] discovery failed: %@", code)
            return
        }
        var candidates = discoveredCandidates
        // Historical rows (stamped at binding, 6.6) enter the queue only
        // under an affirmative consent; undecided keeps them fully local.
        let consent = historicalConsent()
        if !consent.allowsHistoricalSync {
            candidates.removeAll { $0.awaitingHistoricalConsentBindingID != nil }
        }
        if let priorityRecordingID,
           let index = candidates.firstIndex(where: { $0.recordingID == priorityRecordingID }) {
            candidates.insert(candidates.remove(at: index), at: 0)
        }

        let now = Date()
        var syncRecordsByRecordingID: [UUID: WebSyncRecordDTO] = [:]
        for record in syncRecords {
            syncRecordsByRecordingID[record.recordingID] = record
        }
        let readyWork = syncRecords
            .filter { $0.nextAttemptAt == nil || $0.nextAttemptAt! <= now }
            .sorted { ($0.lastAttemptAt ?? .distantPast) < ($1.lastAttemptAt ?? .distantPast) }
        let audioEnabled = audioUploadEnabled(userID: userID)
        let structuredSyncAllowed = entitlements.allowsStructuredSync(for: userID)
        let mayOpenNewAudioSession = entitlements.allowsAudioTransfer(for: userID)
        let userRetryTargets = userInitiatedRetry
            ? Self.userRetryTargets(
                records: syncRecords,
                structuredSyncAllowed: structuredSyncAllowed,
                audioSyncAllowed: mayOpenNewAudioSession
            )
            : [:]
        let reconciledPreference = reconciledAudioPreferenceKey(userID).flatMap {
            defaults.object(forKey: $0) as? Bool
        }
        let reconciledConsent = reconciledHistoricalConsentKey(userID).flatMap {
            defaults.string(forKey: $0)
        }
        let forcePayloadRefresh = reconciledPreference != audioEnabled
            || reconciledConsent != consent.rawValue
        let audioProbeCandidateIDs = Self.audioProbeCandidateIDs(
            candidates: candidates,
            recordsByRecordingID: syncRecordsByRecordingID,
            globalAudioEnabled: audioEnabled,
            historicalConsent: consent,
            structuredSyncAllowed: structuredSyncAllowed,
            forcePayloadRefresh: forcePayloadRefresh,
            now: now
        )
        let deletionWork = userInitiatedRetry
            ? syncRecords.filter {
                $0.isDeletionTombstone
                    && (userRetryTargets[$0.recordingID] == .deletion
                        || $0.nextAttemptAt == nil
                        || $0.nextAttemptAt! <= now)
            }
            : readyWork.filter(\.isDeletionTombstone)
        for tombstone in deletionWork {
            guard isActiveUser(userID), !Task.isCancelled else { return }
            do {
                try await api.delete(clientRecordingID: tombstone.recordingID)
                try ensureActive(userID: userID)
                var mutation = WebSyncMutation(userID: userID, recordingID: tombstone.recordingID)
                mutation.structuredState = WebStructuredSyncState.synced.rawValue
                mutation.audioState = WebAudioSyncState.localOnly.rawValue
                mutation.attemptCount = 0
                mutation.syncedAt = Date()
                mutation.isDeletionTombstone = false
                _ = try await store.upsertWebSyncRecord(mutation)
            } catch {
                _ = await recordFailure(error, userID: userID, recordingID: tombstone.recordingID)
            }
        }

        // A policy marker is an acknowledgement that every affected remote
        // payload was accepted. An unavailable structured gate cannot provide
        // that acknowledgement, even if independent durable audio work can
        // still finish in this pass.
        var forcedRefreshSucceeded = !(forcePayloadRefresh && !structuredSyncAllowed)
        for candidate in candidates {
            guard isActiveUser(userID), !Task.isCancelled else { return }
            let record = syncRecordsByRecordingID[candidate.recordingID]
            let bypassRetryBackoff = userRetryTargets[candidate.recordingID] != nil
            let candidateAudioEnabled = Self.audioUploadEnabled(
                for: candidate,
                globalAudioEnabled: audioEnabled,
                historicalConsent: consent
            )
            if !Self.shouldProcessCandidate(
                candidate,
                record: record,
                audioUploadEnabled: candidateAudioEnabled,
                structuredSyncAllowed: structuredSyncAllowed,
                mayOpenNewAudioSession: mayOpenNewAudioSession,
                forcePayloadRefresh: forcePayloadRefresh,
                bypassRetryBackoff: bypassRetryBackoff,
                now: now
            ) {
                if audioProbeCandidateIDs.contains(candidate.recordingID) {
                    let changed = await audioProbeRequiresFullSync(
                        candidate: candidate,
                        record: record,
                        userID: userID,
                        now: now
                    )
                    if !changed { continue }
                } else {
                    continue
                }
            }
            let succeeded = await sync(
                recordingID: candidate.recordingID,
                userID: userID,
                policyRefreshRequired: forcePayloadRefresh,
                bypassRetryBackoff: bypassRetryBackoff
            )
            if forcePayloadRefresh, !succeeded {
                forcedRefreshSucceeded = false
            }
        }
        guard isActiveUser(userID), !Task.isCancelled else { return }
        if !forcePayloadRefresh || forcedRefreshSucceeded {
            if let key = reconciledAudioPreferenceKey(userID) {
                defaults.set(audioEnabled, forKey: key)
            }
            if let key = reconciledHistoricalConsentKey(userID) {
                defaults.set(consent.rawValue, forKey: key)
            }
        }
        await clearErrorIfPassResolved(
            userRetryTargets: userRetryTargets,
            userID: userID,
            errorRevisionBeforePass: errorRevisionBeforePass
        )
    }

    private enum UserRetryLane: Sendable {
        case deletion
        case structured
        case audio
    }

    /// Selects only durable failed work owned by this account. Entitlement
    /// diagnostics fail closed until the in-memory authority says that exact
    /// capability has reopened; transient and other permanent failures may be
    /// retried once when the user explicitly asks.
    private nonisolated static func userRetryTargets(
        records: [WebSyncRecordDTO],
        structuredSyncAllowed: Bool,
        audioSyncAllowed: Bool
    ) -> [UUID: UserRetryLane] {
        var targets: [UUID: UserRetryLane] = [:]
        for record in records {
            let lane: UserRetryLane
            if record.isDeletionTombstone {
                lane = .deletion
            } else if record.retryDomain == WebSyncRetryDomain.audio.rawValue,
                      record.audioState == WebAudioSyncState.failed.rawValue {
                lane = .audio
            } else if record.structuredState == WebStructuredSyncState.failed.rawValue {
                lane = .structured
            } else {
                continue
            }

            switch record.lastErrorCode {
            case rejectionDiagnostic(.textQuotaExceeded):
                guard structuredSyncAllowed else { continue }
            case rejectionDiagnostic(.audioUploadNotEntitled),
                 rejectionDiagnostic(.storageQuotaExceeded):
                guard audioSyncAllowed else { continue }
            case let code? where code.hasPrefix("entitlement:"):
                // Unknown future entitlement diagnostics are decisions, not
                // transient failures. A newer client/contract must explicitly
                // define their reopen semantics before retrying them.
                continue
            default:
                break
            }
            targets[record.recordingID] = lane
        }
        return targets
    }

    /// Clears a visible failure only after a complete pass produced no new
    /// error and durable state contains no outstanding failed work. This also
    /// lets a successful discovery-only retry clear a prior discovery error,
    /// while a backoff-deferred row keeps the failure visible.
    private func clearErrorIfPassResolved(
        userRetryTargets: [UUID: UserRetryLane],
        userID: String,
        errorRevisionBeforePass: UInt
    ) async {
        let refreshed: [WebSyncRecordDTO]
        do {
            refreshed = try await store.fetchWebSyncRecords(userID: userID)
        } catch {
            publishError(error)
            return
        }
        guard lastErrorRevision == errorRevisionBeforePass else { return }
        let recordsByID = Dictionary(uniqueKeysWithValues: refreshed.map {
            ($0.recordingID, $0)
        })
        let allUserRetryTargetsResolved = userRetryTargets.allSatisfy { recordingID, lane in
            guard let record = recordsByID[recordingID] else { return true }
            switch lane {
            case .deletion:
                return !record.isDeletionTombstone
            case .structured:
                return record.structuredState != WebStructuredSyncState.failed.rawValue
                    && record.attemptCount == 0
            case .audio:
                return record.audioState != WebAudioSyncState.failed.rawValue
                    && record.attemptCount == 0
            }
        }
        guard allUserRetryTargetsResolved else { return }
        let hasOutstandingFailure = refreshed.contains { record in
            record.structuredState == WebStructuredSyncState.failed.rawValue
                || record.audioState == WebAudioSyncState.failed.rawValue
                || (record.isDeletionTombstone && record.nextAttemptAt != nil)
        }
        guard !hasOutstandingFailure else { return }
        lastError = nil
    }

    private func publishError(_ error: Error) {
        lastError = error.localizedDescription
        lastErrorRevision &+= 1
    }

    nonisolated static func audioUploadEnabled(
        for candidate: WebSyncCandidate,
        globalAudioEnabled: Bool,
        historicalConsent: HistoricalSyncConsent
    ) -> Bool {
        globalAudioEnabled
            && (candidate.awaitingHistoricalConsentBindingID == nil
                || historicalConsent.allowsHistoricalAudio)
    }

    nonisolated static func shouldProcessCandidate(
        _ candidate: WebSyncCandidate,
        record: WebSyncRecordDTO?,
        audioUploadEnabled: Bool,
        structuredSyncAllowed: Bool = true,
        mayOpenNewAudioSession: Bool = true,
        forcePayloadRefresh: Bool,
        bypassRetryBackoff: Bool = false,
        now: Date
    ) -> Bool {
        let hasDurableAudioSession = audioUploadEnabled && record?.uploadSessionID != nil
        let durableSessionOwnsStructuredBackoff = hasDurableAudioSession
            && record?.retryDomain != WebSyncRetryDomain.audio.rawValue
        let canBypassStructuredBackoffForAudio = durableSessionOwnsStructuredBackoff
            || (audioUploadEnabled
                && mayOpenNewAudioSession
                && record?.audioState != WebAudioSyncState.synced.rawValue
                && record?.lastErrorCode == rejectionDiagnostic(.textQuotaExceeded))
        if !forcePayloadRefresh,
           !bypassRetryBackoff,
           let record,
           record.retryDomain == WebSyncRetryDomain.audio.rawValue,
           let nextAttemptAt = record.nextAttemptAt,
           nextAttemptAt > now,
           record.structuredState == WebStructuredSyncState.synced.rawValue,
           record.structuredSourceRevision == candidate.contentRevision {
            return false
        }
        if !forcePayloadRefresh,
           !bypassRetryBackoff,
           let record,
           let nextAttemptAt = record.nextAttemptAt,
           nextAttemptAt > now,
           let attemptedRevision = record.structuredAttemptRevision,
           attemptedRevision == candidate.contentRevision,
           !canBypassStructuredBackoffForAudio {
            return false
        }
        if !structuredSyncAllowed {
            guard let record,
                  !record.isDeletionTombstone,
                  record.remoteRecordingID != nil,
                  candidate.trashedDate == nil,
                  audioUploadEnabled else {
                return false
            }
            if record.uploadSessionID != nil { return true }
            if record.audioState == WebAudioSyncState.synced.rawValue { return false }
            if record.audioState == WebAudioSyncState.unavailable.rawValue { return false }
            return mayOpenNewAudioSession
        }
        guard !forcePayloadRefresh,
              let record,
              !record.isDeletionTombstone,
              record.structuredState == WebStructuredSyncState.synced.rawValue,
              record.remoteRecordingID != nil,
              let sourceRevision = record.structuredSourceRevision,
              sourceRevision == candidate.contentRevision else {
            return true
        }
        if candidate.trashedDate != nil {
            return false
        }
        if audioUploadEnabled {
            if record.audioState == WebAudioSyncState.synced.rawValue {
                return false
            }
            if record.audioState == WebAudioSyncState.unavailable.rawValue { return false }
            // An already-open session may finish after a downgrade. Work
            // needing a brand-new session stays cold until positive authority
            // arrives, avoiding a full payload rebuild every minute while the
            // entitlement endpoint is unavailable or has refused audio.
            if record.uploadSessionID != nil {
                return true
            }
            return mayOpenNewAudioSession
        }
        return false
    }

    nonisolated static let syncedAudioProbeInterval: TimeInterval = 15 * 60
    nonisolated static let syncedAudioProbeBudgetPerPass = 8

    nonisolated static func audioProbeCandidateIDs(
        candidates: [WebSyncCandidate],
        recordsByRecordingID: [UUID: WebSyncRecordDTO],
        globalAudioEnabled: Bool,
        historicalConsent: HistoricalSyncConsent,
        structuredSyncAllowed: Bool = true,
        forcePayloadRefresh: Bool,
        now: Date,
        budget: Int = syncedAudioProbeBudgetPerPass
    ) -> Set<UUID> {
        guard budget > 0 else { return [] }
        let due = candidates.filter { candidate in
            shouldProbeSyncedAudio(
                candidate,
                record: recordsByRecordingID[candidate.recordingID],
                audioUploadEnabled: audioUploadEnabled(
                    for: candidate,
                    globalAudioEnabled: globalAudioEnabled,
                    historicalConsent: historicalConsent
                ),
                structuredSyncAllowed: structuredSyncAllowed,
                forcePayloadRefresh: forcePayloadRefresh,
                now: now
            )
        }
        let oldestFirst = due.sorted { lhs, rhs in
            let left = recordsByRecordingID[lhs.recordingID]?.lastAttemptAt ?? .distantPast
            let right = recordsByRecordingID[rhs.recordingID]?.lastAttemptAt ?? .distantPast
            if left != right { return left < right }
            return lhs.recordingID.uuidString < rhs.recordingID.uuidString
        }
        return Set(oldestFirst.prefix(budget).map(\.recordingID))
    }

    nonisolated static func shouldProbeSyncedAudio(
        _ candidate: WebSyncCandidate,
        record: WebSyncRecordDTO?,
        audioUploadEnabled: Bool,
        structuredSyncAllowed: Bool = true,
        forcePayloadRefresh: Bool,
        now: Date,
        interval: TimeInterval = syncedAudioProbeInterval
    ) -> Bool {
        guard !forcePayloadRefresh,
              audioUploadEnabled,
              candidate.trashedDate == nil,
              candidate.hasAudioReference,
              let record,
              !record.isDeletionTombstone,
              record.remoteRecordingID != nil,
              record.structuredState == WebStructuredSyncState.synced.rawValue,
              (record.structuredSourceRevision == candidate.contentRevision
                || !structuredSyncAllowed),
              [WebAudioSyncState.synced.rawValue, WebAudioSyncState.unavailable.rawValue]
                .contains(record.audioState) else {
            return false
        }
        if !structuredSyncAllowed,
           record.audioProbeRevision != candidate.contentRevision {
            return true
        }
        guard let lastAttemptAt = record.lastAttemptAt else { return true }
        return now.timeIntervalSince(lastAttemptAt) >= interval
    }

    private func audioProbeRequiresFullSync(
        candidate: WebSyncCandidate,
        record: WebSyncRecordDTO?,
        userID: String,
        now: Date
    ) async -> Bool {
        guard let record else { return false }
        do {
            guard let url = try await store.fetchWebSyncAudioProbeURL(
                recordingID: candidate.recordingID
            ) else {
                try await store.markWebSyncAudioProbe(
                    userID: userID,
                    recordingID: candidate.recordingID,
                    contentRevision: candidate.contentRevision,
                    at: now
                )
                return false
            }
            let fingerprint = try await fileReader.fingerprint(url: url)
            try ensureActive(userID: userID)
            guard record.audioState == WebAudioSyncState.synced.rawValue,
                  fingerprint.value == record.audioFingerprint else {
                // Persist the detected replacement before entering the full
                // path. This keeps the work visible even if structured sync is
                // currently paused and only the independent audio gate is open.
                var mutation = WebSyncMutation(
                    userID: userID, recordingID: candidate.recordingID
                )
                mutation.audioState = WebAudioSyncState.pending.rawValue
                mutation.audioFingerprint = fingerprint.value
                mutation.audioProbeRevision = candidate.contentRevision
                mutation.clearUploadSessionID = true
                mutation.nextAttemptAt = record.nextAttemptAt
                _ = try await store.upsertWebSyncRecord(mutation)
                return true
            }
            try await store.markWebSyncAudioProbe(
                userID: userID,
                recordingID: candidate.recordingID,
                contentRevision: candidate.contentRevision,
                at: now
            )
            return false
        } catch is CancellationError {
            return false
        } catch {
            // Missing or replaced files need the normal durable failure path;
            // a probe persistence failure simply retries on the next pass.
            if error is WebSyncPersistenceError {
                NSLog("[WebSync] audio probe state failed: %@", error.localizedDescription)
                return false
            }
            if record.audioState == WebAudioSyncState.unavailable.rawValue {
                do {
                    try await store.markWebSyncAudioProbe(
                        userID: userID,
                        recordingID: candidate.recordingID,
                        contentRevision: candidate.contentRevision,
                        at: now
                    )
                } catch {
                    NSLog("[WebSync] audio probe state failed: %@", error.localizedDescription)
                }
                return false
            }
            return true
        }
    }

    /// Storage-migration exclusion for upload IO; tests inject an isolated
    /// gate through the initializer.
    private let migrationGate: StorageMigrationGate

    private func sync(
        recordingID: UUID,
        userID: String,
        policyRefreshRequired: Bool,
        bypassRetryBackoff: Bool
    ) async -> Bool {
        // The lease covers reference resolution itself: the snapshot is
        // re-fetched inside the lease, so a migration that completed after
        // the worker listed its work cannot leave this item uploading from
        // the old root. A refusal leaves the record pending for a later
        // pass.
        guard let migrationLease = migrationGate.claimActivity() else {
            NSLog("[WebSync] sync deferred: storage migration in progress")
            return false
        }
        defer { migrationGate.releaseActivity(migrationLease) }
        let snapshot: WebSyncSnapshot
        do {
            guard let fetched = try await store.fetchWebSyncSnapshot(recordingID: recordingID) else {
                return true
            }
            snapshot = fetched
        } catch {
            publishError(error)
            NSLog("[WebSync] snapshot fetch failed: %@", Self.diagnosticCode(for: error))
            return false
        }
        let consent = historicalConsent()
        let isHistorical = snapshot.awaitingHistoricalConsentBindingID != nil
        if isHistorical, !consent.allowsHistoricalSync { return true }
        let audioURL = snapshot.audioFileURL
        // Two different permissions. The user's toggle and consent decide
        // whether this client transfers audio at all. Entitlement decides only
        // whether a new upload may be opened: an upload already in flight is
        // answered from its own durable session, so a plan change cannot strand
        // it, while a new one needs positive authority and fails closed without.
        let audioPermitted = audioUploadEnabled(userID: userID)
            && (!isHistorical || consent.allowsHistoricalAudio)
        let mayOpenNewAudioSession = entitlements.allowsAudioTransfer(for: userID)
        let audioSource: WebSyncAudioSourceState
        if !audioPermitted {
            audioSource = .localOnly
        } else if let audioURL, FileManager.default.isReadableFile(atPath: audioURL.path) {
            audioSource = .eligible
        } else {
            audioSource = .unavailable
        }

        var attemptedHash: String?
        var attemptedRevision: Date?
        var isInitialStructuredUpsert = false
        var structuredUpsertPendingAcknowledgement = false
        var policyPayloadAcknowledged = !policyRefreshRequired
        var failureDomain = WebSyncRetryDomain.structured
        do {
            let existing = await store.fetchWebSyncRecord(userID: userID, recordingID: snapshot.detail.id)
            let audioRetryDeferred = !bypassRetryBackoff
                && existing?.retryDomain == WebSyncRetryDomain.audio.rawValue
                && (existing?.nextAttemptAt ?? .distantPast) > Date()
            let structuredAllowed = entitlements.allowsStructuredSync(for: userID)
            if !structuredAllowed {
                // Structured policy changes cannot be acknowledged while the
                // server gate is closed. Independent audio work may still use
                // an existing remote row (especially a durable upload session),
                // without materializing or encoding the transcript payload.
                if snapshot.trashedDate == nil,
                   audioPermitted,
                   !audioRetryDeferred,
                   let audioURL,
                   let remoteID = existing?.remoteRecordingID,
                   (existing?.uploadSessionID != nil
                    || (existing?.audioState != WebAudioSyncState.synced.rawValue
                        && mayOpenNewAudioSession)) {
                    failureDomain = .audio
                    try await syncAudio(
                        url: audioURL,
                        duration: snapshot.detail.duration,
                        userID: userID,
                        recordingID: snapshot.detail.id,
                        remoteID: remoteID,
                        mayOpenNewSession: mayOpenNewAudioSession
                    )
                }
                return !policyRefreshRequired
            }
            let payloadBuildTask = Task.detached(priority: .utility) {
                try WebSyncPayloadBuilder.build(snapshot: snapshot, audioSourceState: audioSource)
            }
            let built = try await withTaskCancellationHandler {
                try await payloadBuildTask.value
            } onCancel: {
                payloadBuildTask.cancel()
            }
            try ensureActive(userID: userID)
            attemptedHash = built.contentHash
            var structuredRetryDeferred = false
            if !bypassRetryBackoff,
               let nextAttemptAt = existing?.nextAttemptAt,
               nextAttemptAt > Date(),
               existing?.structuredHash == built.contentHash {
                // A local edit can advance the exact source revision without
                // changing anything represented by the payload. Persist that
                // revision before honoring the existing backoff, otherwise the
                // lightweight scheduler will rebuild this same payload every
                // minute until the retry window expires.
                var mutation = WebSyncMutation(
                    userID: userID, recordingID: snapshot.detail.id
                )
                if existing?.structuredState == WebStructuredSyncState.synced.rawValue {
                    mutation.structuredSourceRevision = snapshot.contentRevision
                }
                mutation.structuredAttemptRevision = snapshot.contentRevision
                mutation.nextAttemptAt = existing?.nextAttemptAt
                _ = try await store.upsertWebSyncRecord(mutation)
                structuredRetryDeferred = true
                let mayContinueIndependentAudio = audioPermitted
                    && !audioRetryDeferred
                    && existing?.remoteRecordingID != nil
                    && ((existing?.uploadSessionID != nil
                         && existing?.retryDomain != WebSyncRetryDomain.audio.rawValue)
                        || (mayOpenNewAudioSession
                            && existing?.lastErrorCode
                                == Self.rejectionDiagnostic(.textQuotaExceeded)))
                if !mayContinueIndependentAudio { return true }
            }
            var remoteID = existing?.remoteRecordingID
            let structuredWorkPending = !structuredRetryDeferred
                && (existing?.structuredHash != built.contentHash
                    || existing?.structuredState != WebStructuredSyncState.synced.rawValue)
            if structuredAllowed && structuredWorkPending {
                isInitialStructuredUpsert = remoteID == nil
                structuredUpsertPendingAcknowledgement = true
                attemptedRevision = snapshot.contentRevision
                let response = try await api.upsert(
                    clientRecordingID: snapshot.detail.id,
                    payloadData: built.encodedData
                )
                isInitialStructuredUpsert = false
                try ensureActive(userID: userID)
                remoteID = response.recordingID
                var mutation = WebSyncMutation(userID: userID, recordingID: snapshot.detail.id)
                mutation.remoteRecordingID = response.recordingID
                mutation.structuredState = WebStructuredSyncState.synced.rawValue
                mutation.structuredHash = built.contentHash
                mutation.structuredSourceRevision = snapshot.contentRevision
                mutation.structuredAttemptRevision = snapshot.contentRevision
                if audioRetryDeferred {
                    // A structured edit and its successful PUT do not
                    // acknowledge a failed audio status/part/commit request.
                    // Keep that independent lane's retry budget and deadline.
                    mutation.attemptCount = existing?.attemptCount
                    mutation.nextAttemptAt = existing?.nextAttemptAt
                    mutation.retryDomain = WebSyncRetryDomain.audio.rawValue
                } else {
                    mutation.attemptCount = 0
                }
                mutation.syncedAt = Date()
                mutation.isDeletionTombstone = false
                _ = try await store.upsertWebSyncRecord(mutation)
                structuredUpsertPendingAcknowledgement = false
                policyPayloadAcknowledged = true
            } else if !structuredRetryDeferred,
                      !structuredWorkPending,
                      existing?.structuredSourceRevision != snapshot.contentRevision {
                // Existing rows from before source-revision tracking can
                // already have the exact same content hash. Backfill the
                // captured revision locally so they do not rebuild forever;
                // no network request is needed because the payload is equal.
                var mutation = WebSyncMutation(userID: userID, recordingID: snapshot.detail.id)
                mutation.structuredSourceRevision = snapshot.contentRevision
                mutation.structuredAttemptRevision = snapshot.contentRevision
                _ = try await store.upsertWebSyncRecord(mutation)
            }
            if existing?.structuredState == WebStructuredSyncState.synced.rawValue,
               existing?.structuredHash == built.contentHash {
                // The server already accepted this exact policy payload. A
                // later audio-transfer failure must not force perpetual policy
                // reconciliation, while a refused structured replacement must.
                policyPayloadAcknowledged = true
            }

            guard snapshot.trashedDate == nil else { return true }
            guard audioPermitted, let audioURL, let remoteID else {
                if existing?.audioState == WebAudioSyncState.synced.rawValue {
                    return true
                }
                var mutation = WebSyncMutation(userID: userID, recordingID: snapshot.detail.id)
                mutation.audioState = audioPermitted
                    ? WebAudioSyncState.unavailable.rawValue
                    : WebAudioSyncState.localOnly.rawValue
                _ = try await store.upsertWebSyncRecord(mutation)
                return true
            }
            guard !shouldPauseHistoricalAudio() else { return true }
            guard !audioRetryDeferred else { return true }
            failureDomain = .audio
            try await syncAudio(
                url: audioURL,
                duration: snapshot.detail.duration,
                userID: userID,
                recordingID: snapshot.detail.id,
                remoteID: remoteID,
                mayOpenNewSession: mayOpenNewAudioSession
            )
            return true
        } catch {
            let failurePersisted = await recordFailure(
                error,
                userID: userID,
                recordingID: snapshot.detail.id,
                attemptedHash: attemptedHash,
                attemptedRevision: attemptedRevision,
                didAttemptStructuredUpsert: structuredUpsertPendingAcknowledgement,
                isInitialStructuredUpsert: isInitialStructuredUpsert,
                retryDomain: failureDomain
            )
            return failurePersisted && policyPayloadAcknowledged
        }
    }

    private func syncAudio(
        url: URL,
        duration: TimeInterval,
        userID: String,
        recordingID: UUID,
        remoteID: String,
        mayOpenNewSession: Bool
    ) async throws {
        let fingerprint = try await fileReader.fingerprint(url: url)
        try ensureActive(userID: userID)
        guard fingerprint.size > 0 else { throw WebSyncFileError.invalidRange }
        var existing = await store.fetchWebSyncRecord(userID: userID, recordingID: recordingID)
        if existing?.audioState == WebAudioSyncState.synced.rawValue,
           existing?.audioFingerprint == fingerprint.value {
            return
        }
        if existing?.audioFingerprint != fingerprint.value,
           (existing?.audioState == WebAudioSyncState.synced.rawValue
            || existing?.uploadSessionID != nil) {
            // The remote still has the previous file, but the current local
            // file is unsent work. Move it out of `synced` before any
            // entitlement or network exit so a later authoritative reopen can
            // select and upload the replacement.
            var mutation = WebSyncMutation(userID: userID, recordingID: recordingID)
            mutation.audioState = WebAudioSyncState.pending.rawValue
            mutation.audioFingerprint = fingerprint.value
            mutation.clearUploadSessionID = true
            mutation.nextAttemptAt = existing?.nextAttemptAt
            existing = try await store.upsertWebSyncRecord(mutation)
        }

        let chunkSize = Int64(5 * 1_024 * 1_024)
        let protocolChunkSize = max(Int64(256 * 1_024), min(chunkSize, fingerprint.size))
        var sessionID: String
        var received = Set<Int>()
        var actualChunkSize = protocolChunkSize
        var savedStatus: WebSyncAudioSessionStatus?
        var checkedSavedSession = false
        if existing?.audioFingerprint == fingerprint.value,
           let savedSessionID = existing?.uploadSessionID {
            checkedSavedSession = true
            do {
                savedStatus = try await api.getAudioSession(id: savedSessionID)
            } catch CadenzaAPIError.backend(_, 404) {
                savedStatus = nil
            }
            try ensureActive(userID: userID)
        }
        if let status = savedStatus,
           status.state == "committed",
           status.recordingID == remoteID,
           status.totalSize == fingerprint.size {
            var mutation = WebSyncMutation(userID: userID, recordingID: recordingID)
            mutation.audioState = WebAudioSyncState.synced.rawValue
            mutation.audioFingerprint = fingerprint.value
            mutation.clearUploadSessionID = true
            mutation.attemptCount = 0
            if existing?.structuredState == WebStructuredSyncState.failed.rawValue {
                mutation.nextAttemptAt = existing?.nextAttemptAt
            }
            mutation.syncedAt = Date()
            _ = try await store.upsertWebSyncRecord(mutation)
            return
        }
        let resumableStatus = savedStatus.flatMap { status -> WebSyncAudioSessionStatus? in
            guard status.recordingID == remoteID,
                  status.totalSize == fingerprint.size,
                  status.chunkSize > 0,
                  ["initiated", "uploading", "commit_pending"].contains(status.state) else {
                return nil
            }
            return status
        }
        if let status = resumableStatus {
            sessionID = status.sessionID
            received = status.partsReceived
            actualChunkSize = status.chunkSize
        } else {
            if checkedSavedSession {
                // A 404, terminal state, or identity/size mismatch proves this
                // durable session cannot be resumed. Clear it before applying
                // current entitlement so the scheduler does not GET the same
                // dead session every minute.
                var mutation = WebSyncMutation(userID: userID, recordingID: recordingID)
                mutation.audioState = WebAudioSyncState.pending.rawValue
                mutation.audioFingerprint = fingerprint.value
                mutation.clearUploadSessionID = true
                mutation.nextAttemptAt = existing?.nextAttemptAt
                existing = try await store.upsertWebSyncRecord(mutation)
            }
            // Nothing durable left to resume. Opening a replacement is a new
            // upload, which current entitlement has to permit.
            guard mayOpenNewSession else { return }
            let request = WebSyncAudioSessionRequest(
                idempotencyKey: "\(userID):\(recordingID.uuidString.lowercased()):audio:\(fingerprint.value)",
                totalSize: fingerprint.size,
                chunkSize: protocolChunkSize,
                codec: "aac",
                container: url.pathExtension.isEmpty ? "m4a" : url.pathExtension.lowercased(),
                sourceFingerprint: fingerprint.value
            )
            let session = try await api.createAudioSession(remoteRecordingID: remoteID, request: request)
            try ensureActive(userID: userID)
            sessionID = session.sessionID
            var mutation = WebSyncMutation(userID: userID, recordingID: recordingID)
            mutation.audioState = WebAudioSyncState.uploading.rawValue
            mutation.audioFingerprint = fingerprint.value
            mutation.uploadSessionID = sessionID
            if existing?.structuredState == WebStructuredSyncState.failed.rawValue {
                mutation.nextAttemptAt = existing?.nextAttemptAt
            }
            _ = try await store.upsertWebSyncRecord(mutation)
        }

        let count = Int((fingerprint.size + actualChunkSize - 1) / actualChunkSize)
        var manifestParts: [WebSyncAudioManifest.Part] = []
        for number in 1...max(count, 1) {
            try Task.checkCancellation()
            if shouldPauseHistoricalAudio() { return }
            try await fileReader.validateFingerprint(fingerprint, url: url)
            let offset = Int64(number - 1) * actualChunkSize
            let length = Int(min(actualChunkSize, max(fingerprint.size - offset, 0)))
            guard length > 0 else { continue }
            let chunk = try await fileReader.readChunk(url: url, offset: UInt64(offset), length: length)
            try ensureActive(userID: userID)
            if !received.contains(number) {
                try await api.putAudioPart(sessionID: sessionID, number: number, chunk: chunk)
                try ensureActive(userID: userID)
                if shouldPauseHistoricalAudio() { return }
            }
            manifestParts.append(.init(n: number, sizePlaintext: Int64(length), sha256Plaintext: chunk.sha256))
        }
        try await fileReader.validateFingerprint(fingerprint, url: url)
        if shouldPauseHistoricalAudio() { return }
        _ = try await api.commitAudio(
            sessionID: sessionID,
            manifest: .init(
                codec: "aac",
                container: url.pathExtension.isEmpty ? "m4a" : url.pathExtension.lowercased(),
                durationMs: Int64((duration * 1_000).rounded()),
                chunks: manifestParts
            )
        )
        try ensureActive(userID: userID)
        var mutation = WebSyncMutation(userID: userID, recordingID: recordingID)
        mutation.audioState = WebAudioSyncState.synced.rawValue
        mutation.audioFingerprint = fingerprint.value
        mutation.clearUploadSessionID = true
        mutation.attemptCount = 0
        if existing?.structuredState == WebStructuredSyncState.failed.rawValue {
            mutation.nextAttemptAt = existing?.nextAttemptAt
        }
        mutation.syncedAt = Date()
        _ = try await store.upsertWebSyncRecord(mutation)
    }

    @discardableResult
    private func recordFailure(
        _ error: Error,
        userID: String,
        recordingID: UUID,
        attemptedHash: String? = nil,
        attemptedRevision: Date? = nil,
        didAttemptStructuredUpsert: Bool = false,
        isInitialStructuredUpsert: Bool = false,
        retryDomain: WebSyncRetryDomain = .structured
    ) async -> Bool {
        guard !(error is CancellationError) else { return false }
        let prior = await store.fetchWebSyncRecord(userID: userID, recordingID: recordingID)
        let attempt = (prior?.attemptCount ?? 0) + 1
        // A stated entitlement rejection is classified by its stable code
        // before any status-based policy sees it: the same code can arrive with
        // more than one status, and a status alone never means a rejection.
        if let rejection = Self.entitlementRejection(for: error) {
            return await recordEntitlementRejection(
                rejection,
                userID: userID,
                recordingID: recordingID,
                attempt: attempt,
                prior: prior,
                attemptedHash: attemptedHash,
                attemptedRevision: attemptedRevision,
                didAttemptStructuredUpsert: didAttemptStructuredUpsert
            )
        }
        let nextAttemptAt: Date
        switch error {
        case CadenzaAPIError.unauthorized, CadenzaAPIError.notSignedIn:
            nextAttemptAt = Date()
        case CadenzaAPIError.backend(_, let status):
            switch WebSyncRetryPolicy.disposition(
                statusCode: status,
                attempt: attempt - 1,
                isInitialStructuredUpsert: isInitialStructuredUpsert
            ) {
            case .pauseForAuthentication:
                nextAttemptAt = Date()
            case .retry(let seconds):
                nextAttemptAt = Date().addingTimeInterval(seconds)
            case .permanent:
                nextAttemptAt = prior?.structuredState == WebStructuredSyncState.synced.rawValue
                    ? Date().addingTimeInterval(43_200)
                    : .distantFuture
            }
        case AuthError.server(let status):
            switch WebSyncRetryPolicy.disposition(
                statusCode: status,
                attempt: attempt - 1,
                isInitialStructuredUpsert: isInitialStructuredUpsert
            ) {
            case .pauseForAuthentication:
                nextAttemptAt = Date()
            case .retry(let seconds):
                nextAttemptAt = Date().addingTimeInterval(seconds)
            case .permanent:
                nextAttemptAt = prior?.structuredState == WebStructuredSyncState.synced.rawValue
                    ? Date().addingTimeInterval(43_200)
                    : .distantFuture
            }
        default:
            let delay = [60.0, 300, 1_800, 7_200, 43_200][min(attempt - 1, 4)]
            nextAttemptAt = Date().addingTimeInterval(delay)
        }
        var mutation = WebSyncMutation(userID: userID, recordingID: recordingID)
        if didAttemptStructuredUpsert {
            mutation.structuredState = WebStructuredSyncState.failed.rawValue
            mutation.structuredHash = attemptedHash
            mutation.structuredAttemptRevision = attemptedRevision
        } else if prior?.structuredState != WebStructuredSyncState.synced.rawValue {
            mutation.structuredState = WebStructuredSyncState.failed.rawValue
            mutation.structuredHash = attemptedHash
        }
        mutation.audioState = WebAudioSyncState.failed.rawValue
        mutation.attemptCount = attempt
        mutation.nextAttemptAt = nextAttemptAt
        mutation.retryDomain = retryDomain.rawValue
        let errorCode = Self.diagnosticCode(for: error)
        mutation.lastErrorCode = errorCode
        do {
            _ = try await store.upsertWebSyncRecord(mutation)
        } catch {
            NSLog(
                "[WebSync] failed to persist retry state for %@: %@",
                recordingID.uuidString,
                error.localizedDescription
            )
            return false
        }
        publishError(error)
        NSLog("[WebSync] recording %@ failed: %@", recordingID.uuidString, errorCode)
        return true
    }

    /// The stable entitlement rejection an error carries, if any. Only the
    /// codes this contract defines qualify: an unrecognized one is left to the
    /// existing retry behavior rather than turned into a pause.
    private nonisolated static func entitlementRejection(
        for error: Error
    ) -> EntitlementRejection? {
        guard case CadenzaAPIError.backend(let envelope, _) = error else { return nil }
        let code = envelope.code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return nil }
        switch EntitlementRejection(code: code) {
        case .unknown:
            return nil
        case let rejection:
            return rejection
        }
    }

    /// Records a stated entitlement rejection.
    ///
    /// The refusal is a decision, not a transient failure, so the row leaves
    /// the retry loop entirely rather than backing off into it. What was
    /// already synced is left exactly as it is: a rejected new attempt says
    /// nothing about work the server already accepted.
    @discardableResult
    private func recordEntitlementRejection(
        _ rejection: EntitlementRejection,
        userID: String,
        recordingID: UUID,
        attempt: Int,
        prior: WebSyncRecordDTO?,
        attemptedHash: String?,
        attemptedRevision: Date?,
        didAttemptStructuredUpsert: Bool
    ) async -> Bool {
        if let authority = entitlements.authority, authority.owns(userID: userID) {
            entitlements.note(rejection, for: authority)
        }
        var mutation = WebSyncMutation(userID: userID, recordingID: recordingID)
        switch rejection {
        case .textQuotaExceeded:
            mutation.retryDomain = WebSyncRetryDomain.structured.rawValue
            if prior?.structuredState == WebStructuredSyncState.synced.rawValue {
                // A refused replacement cannot undo the last accepted remote
                // payload. Only park the exact attempted revision; source/hash
                // continue to describe the version the server actually has.
                mutation.structuredAttemptRevision = attemptedRevision
            } else if didAttemptStructuredUpsert
                        || prior?.structuredState != WebStructuredSyncState.synced.rawValue {
                mutation.structuredState = WebStructuredSyncState.failed.rawValue
                mutation.structuredHash = attemptedHash
                mutation.structuredAttemptRevision = attemptedRevision
            }
        case .audioUploadNotEntitled, .storageQuotaExceeded:
            mutation.retryDomain = WebSyncRetryDomain.audio.rawValue
            // Structured sync is unaffected by an audio refusal, so its state
            // is not touched here.
            if prior?.audioState != WebAudioSyncState.synced.rawValue {
                mutation.audioState = WebAudioSyncState.failed.rawValue
            }
        case .unknown:
            return false
        }
        mutation.attemptCount = attempt
        mutation.nextAttemptAt = .distantFuture
        let code = Self.rejectionDiagnostic(rejection)
        mutation.lastErrorCode = code
        do {
            _ = try await store.upsertWebSyncRecord(mutation)
        } catch {
            NSLog(
                "[WebSync] failed to persist entitlement rejection for %@: %@",
                recordingID.uuidString,
                error.localizedDescription
            )
            return false
        }
        NSLog("[WebSync] recording %@ refused: %@", recordingID.uuidString, code)
        return true
    }

    private nonisolated static func rejectionDiagnostic(_ rejection: EntitlementRejection) -> String {
        switch rejection {
        case .textQuotaExceeded: return "entitlement:text_quota_exceeded"
        case .audioUploadNotEntitled: return "entitlement:audio_upload_not_entitled"
        case .storageQuotaExceeded: return "entitlement:storage_quota_exceeded"
        case .unknown(let code): return "entitlement:\(sanitizedCode(code))"
        }
    }

    nonisolated static func diagnosticCode(for error: Error) -> String {
        switch error {
        case CadenzaAPIError.notSignedIn:
            return "auth:not_signed_in"
        case CadenzaAPIError.unauthorized:
            return "auth:unauthorized"
        case CadenzaAPIError.backend(let envelope, let status):
            return "backend(status:\(status),code:\(sanitizedCode(envelope.code)))"
        case AuthError.server(let status):
            return "server(status:\(status))"
        case WebSyncFileError.missing:
            return "file:missing"
        case WebSyncFileError.invalidRange:
            return "file:invalid_range"
        case WebSyncFileError.changed:
            return "file:changed"
        case WebSyncPersistenceError.saveFailed:
            return "persistence:save_failed"
        case WebSyncPersistenceError.fetchFailed:
            return "persistence:fetch_failed"
        case let urlError as URLError:
            return "network(code:\(urlError.errorCode))"
        case is DecodingError:
            return "decoding"
        default:
            return "other:\(sanitizedCode(String(describing: type(of: error))))"
        }
    }

    private nonisolated static func sanitizedCode(_ value: String) -> String {
        let sanitized = value.replacingOccurrences(
            of: #"[^A-Za-z0-9_.-]"#,
            with: "_",
            options: .regularExpression
        )
        let bounded = String(sanitized.prefix(64))
        return bounded.isEmpty ? "unknown" : bounded
    }

    private var currentUserID: String? { activeUser?.id }

    /// Ownership guard for every task captured under a user ID: exact
    /// UTF-8 bytes, so a session switched to a canonically equivalent
    /// but byte-distinct account never adopts the old account's work.
    func isActiveUser(_ userID: String) -> Bool {
        guard let current = currentUserID else { return false }
        return AccountIdentity.matches(current, userID)
    }

    private func ensureActive(userID: String) throws {
        guard isActiveUser(userID), !Task.isCancelled else { throw CancellationError() }
    }

    /// A Web Sync preference belongs to the complete frozen account scope,
    /// not merely to a server-issued user ID. Different issuers may legally
    /// issue the same opaque ID, and a profile switch must never carry an
    /// audio-upload grant or reconciliation marker across that boundary.
    nonisolated static func accountScopedPreferenceKey(
        base: String,
        profileID: UUID,
        originKey: String,
        userID: String
    ) -> String {
        "\(base).v2.\(profileID.uuidString.lowercased())."
            + "\(AccountIdentity.keyComponent(originKey))."
            + AccountIdentity.keyComponent(userID)
    }

    private func accountScopedPreferenceKey(base: String, userID: String) -> String? {
        guard let identity = auth.boundIdentity,
              AccountIdentity.matches(identity.account.userID, userID) else {
            return nil
        }
        return Self.accountScopedPreferenceKey(
            base: base,
            profileID: identity.profileID,
            originKey: identity.account.originKey,
            userID: userID
        )
    }

    /// Claims an ambiguous pre-v2 user-ID-only preference for exactly one
    /// frozen account. The owner marker is written first, making a crash
    /// resumable; the legacy key is removed only after the scoped value is
    /// durable, so another issuer with the same user ID cannot inherit it.
    private func migrateLegacyAudioPreferenceIfNeeded(
        userID: String, destinationKey: String
    ) {
        guard defaults.object(forKey: destinationKey) == nil else { return }
        let component = AccountIdentity.keyComponent(userID)
        let legacyKey = "webSync.uploadAudio.v1.\(component)"
        guard let legacyValue = defaults.object(forKey: legacyKey) as? Bool else { return }
        let ownerKey = "webSync.uploadAudio.v2MigrationOwner.\(component)"
        if let owner = defaults.string(forKey: ownerKey) {
            guard owner.utf8.elementsEqual(destinationKey.utf8) else { return }
        } else {
            defaults.set(destinationKey, forKey: ownerKey)
        }
        defaults.set(legacyValue, forKey: destinationKey)
        defaults.removeObject(forKey: legacyKey)
    }

    private func audioPreferenceKey(_ userID: String) -> String? {
        accountScopedPreferenceKey(base: "webSync.uploadAudio", userID: userID)
    }
    private func reconciledAudioPreferenceKey(_ userID: String) -> String? {
        accountScopedPreferenceKey(base: "webSync.reconciledUploadAudio", userID: userID)
    }
    private func reconciledHistoricalConsentKey(_ userID: String) -> String? {
        accountScopedPreferenceKey(base: "webSync.reconciledHistoricalConsent", userID: userID)
    }
    private func serverFailureRecoveryKey(_ userID: String) -> String? {
        accountScopedPreferenceKey(base: "webSync.initialServerRecovery", userID: userID)
    }
}
