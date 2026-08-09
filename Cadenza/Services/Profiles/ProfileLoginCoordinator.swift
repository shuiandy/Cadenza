import Foundation

/// Orchestrates the login and binding protocol (spec §5.5) for the active
/// profile: authorize (memory-only token), decide by the registry's
/// account map — switch to the profile that already owns the account
/// (INV-2, also the unlock path), bind the current profile, or create a
/// fresh account profile — run the two-phase binding, offer the
/// historical-sync consent (INV-15), and relaunch into the target.
@Observable @MainActor
final class ProfileLoginCoordinator {
    enum Step: Equatable {
        case idle
        case authorizing
        /// The account is already bound to another profile; the only
        /// action is switching to it (INV-2).
        case accountAlreadyBound(profileID: UUID, profileName: String)
        /// The authorized account is the active profile's own bound
        /// account: nothing to bind or switch to. The pre-decision
        /// authorization is discarded and no registry or session
        /// artifact is written.
        case alreadyActiveAccount(profileName: String)
        /// Unbound authorization: bind the current profile or create a new
        /// account profile; the system Local may only create (§5.5).
        case chooseTarget(canBindCurrent: Bool, accountName: String)
        /// Binding committed; the historical-sync consent decides what
        /// pre-binding rows may ever sync (§6.6). Skippable — skip means
        /// undecided.
        case consent(profileID: UUID)
        /// Only for a profile this login created from the system Local:
        /// decide what happens to the Local data before entering the new
        /// profile. Cloud-upload consent and local data placement are
        /// separate decisions; the destructive move choice additionally
        /// requires its own confirmation.
        case transferChoice(profileID: UUID)
        case relaunching
        case failed(String)
    }

    enum TransferChoice: Equatable {
        case keepSeparate
        case copy
        case move
    }

    struct Dependencies {
        let auth: CadenzaAuthService
        let registry: ProfileRegistryProviding
        let secretStore: AuthSecretStore
        let sessionUserStore: (UUID) -> SessionUserStoring
        let marker: HistoricalConsentMarking
        let storeURL: (UUID) -> URL
        let storePresence: (URL) throws -> Bool
        let defaults: UserDefaults
        /// Runtime B2/rollback routes through the open container when the
        /// binding target is the active profile.
        let activeStore: ProfileBindingTransaction.ActiveStoreMarking
        let activeProfile: Profile
        let now: () -> Date
        let relaunch: @MainActor () -> Void
        /// Relaunch after a durable transfer intent was written. Distinct
        /// from `relaunch`: with pendingTransfer committed, a spawn
        /// failure may only halt this session — the normal path's
        /// rollback-and-resume would restart source services against a
        /// store the next boot will transfer.
        let transferRelaunch: @MainActor () -> Void
        /// Entered when a registry write cannot be classified — the app
        /// stops serving data until restart.
        let haltTransition: @MainActor (String) -> Void
        /// INV-13: non-nil (a localized reason) while recording,
        /// post-processing, or a storage migration is active — the final
        /// active-profile transition and relaunch must refuse. Binding
        /// itself may complete during active work.
        let transitionRefusal: @MainActor () -> String?
        /// Quiescence barrier ahead of the authority change; false
        /// refuses with services resumed and nothing committed.
        let prepareTransition: @MainActor () async -> Bool
        /// Resumes the old profile's services after a refused or
        /// not-committed transition.
        let resumeAfterRefusedTransition: @MainActor () -> Void
        /// Writes the durable transfer intent (preflight + classified
        /// registry save). Injected by the composition root; the
        /// coordinator never constructs live transfer dependencies.
        let beginTransfer: (ProfileTransfer.Request) throws -> PendingTransfer
    }

    private(set) var step: Step = .idle
    /// Transient refusal (INV-13) that keeps the current step retryable.
    private(set) var blockedReason: String?
    private let dependencies: Dependencies
    /// Complete identity the consent-step switch must find on the bound
    /// profile.
    private var expectedBinding:
        (userID: String, originKey: String, issuerOrigin: String, apiBaseURL: String)?
    /// Memory-only authorization result held between steps; never
    /// persisted before the binding transaction decides (§5.5).
    private var pendingAuthorization: CadenzaAuthService.AuthorizationResult?
    /// One-shot transfer eligibility captured from the committed binding
    /// document: only a profile this login created from the system Local,
    /// with its creation transaction taken from the committed row —
    /// never re-derived later.
    private var transferOffer: (profileID: UUID, creationTransactionID: UUID)?
    /// Consent chosen at the consent step, persisted together with the
    /// final transition so both writes share one quiescence window.
    private var stashedConsent: HistoricalSyncConsent?

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    /// Byte-exact proof that this process's boot profile still owns
    /// the registry's active slot with its frozen shape; the same
    /// predicate phase A proves through Request.sourceAuthority.
    private func sourceStillAuthoritative(in document: ProfileRegistryDocument) -> Bool {
        guard document.activeProfileID == dependencies.activeProfile.id,
              let source = document.profiles.first(where: {
                  $0.id == dependencies.activeProfile.id
              }),
              source.kind == dependencies.activeProfile.kind,
              !source.isLocked,
              AccountIdentity.boundTupleMatches(
                  source.boundAccount, dependencies.activeProfile.boundAccount
              ) else {
            return false
        }
        return true
    }

    var bindingDependencies: ProfileBindingTransaction.Dependencies {
        ProfileBindingTransaction.Dependencies(
            registry: dependencies.registry,
            secretStore: dependencies.secretStore,
            sessionUserStore: dependencies.sessionUserStore,
            marker: dependencies.marker,
            storeURL: dependencies.storeURL,
            storePresence: dependencies.storePresence,
            now: dependencies.now
        )
    }

    func begin() async {
        guard step == .idle || isFailure else { return }
        step = .authorizing
        do {
            let result = try await dependencies.auth.authorizeForBinding()
            pendingAuthorization = result
            let document = try dependencies.registry.load()
            // Stale-process guard: the registry's active profile must still
            // be the one this process is bound to.
            guard document.activeProfileID == dependencies.activeProfile.id else {
                throw ProfileBindingTransaction.BindingError.inconsistentState(
                    "active profile changed behind this process"
                )
            }
            let originKey = result.backend.origin.originKey
            if let existing = document.profiles.first(where: {
                $0.boundAccount?.originKey == originKey
                    && $0.boundAccount.map {
                        AccountIdentity.matches($0.userID, result.user.id)
                    } == true
            }) {
                // A bound profile that never materialized its store and
                // still carries its creation transaction is an
                // interrupted setup: the binding committed but the
                // consent and Local-data decisions were never finished.
                // Re-login resumes them from the registry's durable
                // facts instead of switching in — a plain switch would
                // materialize the empty store and consume the one-shot
                // transfer eligibility forever. The freshly minted token
                // is discarded like every pre-decision authorization;
                // the slot keeps the token the binding stored.
                if existing.id == dependencies.activeProfile.id {
                    // Same account as the active profile: presenting the
                    // switch-and-restart flow would promise a transition
                    // that cannot happen. The lookup key (origin, userID)
                    // alone is not identity — before claiming nothing
                    // changed, the registry row must byte-match the full
                    // tuple of this authorization and of the process's
                    // own bound account; any drift refuses instead.
                    guard let bound = existing.boundAccount,
                          let processBound = dependencies.activeProfile.boundAccount,
                          AccountIdentity.matches(bound.userID, result.user.id),
                          AccountIdentity.matches(
                              bound.originKey, result.backend.origin.originKey
                          ),
                          AccountIdentity.matches(
                              bound.issuerOrigin, result.backend.origin.normalized
                          ),
                          AccountIdentity.matches(
                              bound.apiBaseURL, result.backend.apiBaseURL.absoluteString
                          ),
                          AccountIdentity.matches(bound.userID, processBound.userID),
                          AccountIdentity.matches(bound.originKey, processBound.originKey),
                          AccountIdentity.matches(
                              bound.issuerOrigin, processBound.issuerOrigin
                          ),
                          AccountIdentity.matches(
                              bound.apiBaseURL, processBound.apiBaseURL
                          ) else {
                        throw ProfileBindingTransaction.BindingError.inconsistentState(
                            "active profile account does not match this sign-in"
                        )
                    }
                    discardAuthorization()
                    step = .alreadyActiveAccount(profileName: existing.name)
                } else if dependencies.activeProfile.kind == .system,
                   existing.id != dependencies.activeProfile.id,
                   !existing.storeMaterialized,
                   !existing.isLocked,
                   let creation = existing.createdByBindingTransactionID,
                   let bound = existing.boundAccount,
                   AccountIdentity.matches(bound.userID, result.user.id),
                   AccountIdentity.matches(
                       bound.originKey, result.backend.origin.originKey
                   ),
                   AccountIdentity.matches(
                       bound.issuerOrigin, result.backend.origin.normalized
                   ),
                   AccountIdentity.matches(
                       bound.apiBaseURL, result.backend.apiBaseURL.absoluteString
                   ) {
                    // The full frozen tuple is proven against this
                    // login's authorization before resuming — the lookup
                    // key alone (origin, userID) is not identity, and
                    // the later proofs must compare the registry against
                    // this login, never against itself.
                    expectedBinding = (
                        userID: result.user.id,
                        originKey: result.backend.origin.originKey,
                        issuerOrigin: result.backend.origin.normalized,
                        apiBaseURL: result.backend.apiBaseURL.absoluteString
                    )
                    transferOffer = (
                        profileID: existing.id, creationTransactionID: creation
                    )
                    discardAuthorization()
                    step = .consent(profileID: existing.id)
                } else {
                    step = .accountAlreadyBound(
                        profileID: existing.id, profileName: existing.name
                    )
                }
            } else {
                step = .chooseTarget(
                    canBindCurrent: dependencies.activeProfile.kind != .system
                        && dependencies.activeProfile.boundAccount == nil,
                    accountName: result.user.displayName.isEmpty
                        ? result.user.email : result.user.displayName
                )
            }
        } catch {
            pendingAuthorization = nil
            step = .failed(AuthError.classify(error).localizedMessage())
        }
    }

    /// Target-scoped unlock entry (§7 soft lock): authorization runs
    /// against the locked row's own frozen backend — never the active
    /// profile's bound backend or the configured new-login backend — and
    /// the result must name exactly that row's bound account before any
    /// artifact is written. A wrong account or a target that changed
    /// under the flow writes nothing and leaves the target locked.
    func beginUnlock(of targetProfileID: UUID) async {
        guard step == .idle || isFailure else { return }
        // A coordinator reused after a failed step must not retain an
        // older token in memory.
        pendingAuthorization = nil
        step = .authorizing
        do {
            let document = try dependencies.registry.load()
            guard document.activeProfileID == dependencies.activeProfile.id else {
                throw ProfileBindingTransaction.BindingError.inconsistentState(
                    "active profile changed behind this process"
                )
            }
            guard let target = document.profiles.first(where: { $0.id == targetProfileID }),
                  let bound = target.boundAccount else {
                throw ProfileBindingTransaction.BindingError.inconsistentState(
                    "unlock target is missing or unbound"
                )
            }
            // The dance targets this binding's exact frozen issuer and
            // base, validated fail-closed first.
            let origin = try IssuerOrigin(validating: bound.issuerOrigin)
            guard origin.originKey == bound.originKey,
                  let base = URL(string: bound.apiBaseURL),
                  origin.covers(requestURL: base) else {
                throw ProfileBindingTransaction.BindingError.inconsistentState(
                    "unlock target backend is invalid"
                )
            }
            let result = try await dependencies.auth.authorizeForBinding(
                backend: CadenzaBackendConfig.Resolved(origin: origin, apiBaseURL: base)
            )
            guard AccountIdentity.matches(result.user.id, bound.userID),
                  result.backend.origin.originKey == bound.originKey else {
                pendingAuthorization = nil
                step = .failed(AuthError.accountMismatch.localizedMessage())
                return
            }
            pendingAuthorization = result
            step = .accountAlreadyBound(profileID: target.id, profileName: target.name)
        } catch {
            pendingAuthorization = nil
            step = .failed(AuthError.classify(error).localizedMessage())
        }
    }

    /// INV-2 yes-branch and the soft-lock unlock path: the token moves
    /// into the owning profile's slot, the profile unlocks, and the app
    /// relaunches into it. Identity is guaranteed by the (originKey,
    /// userID) lookup that selected the profile — re-proven against the
    /// fresh document below before any artifact write.
    func switchToExistingProfile() async {
        guard case .accountAlreadyBound(let profileID, _) = step,
              let authorization = pendingAuthorization else { return }
        if let reason = dependencies.transitionRefusal() {
            blockedReason = reason
            return
        }
        blockedReason = nil
        // Quiescence first: the fresh reproof, the target artifact
        // writes, and the classified active commit then run in one
        // synchronous span with no await in between, so drain-time drift
        // cannot separate the proof from the writes.
        guard await dependencies.prepareTransition() else {
            blockedReason = String(
                localized: "Cadenza couldn't pause background work — nothing changed. Try again."
            )
            return
        }
        // Post-drain classification: an unreadable registry, a lost
        // source slot, or a pending operation means the old authority is
        // unknown or taken over — resuming old services could fight the
        // new owner, so these halt. Only a readable document proving the
        // source still owned licenses the safe refusals below.
        let document: ProfileRegistryDocument
        do {
            document = try dependencies.registry.load()
        } catch {
            NSLog("[ProfileLogin] registry unreadable after drain: %@", String(describing: error))
            step = .failed(String(
                localized: "A profile change didn't finish. Quit and reopen Cadenza to continue."
            ))
            dependencies.haltTransition("registry unreadable after the drain: \(error)")
            return
        }
        guard sourceStillAuthoritative(in: document),
              document.pendingBinding == nil, document.pendingTransfer == nil else {
            step = .failed(String(
                localized: "A profile change didn't finish. Quit and reopen Cadenza to continue."
            ))
            dependencies.haltTransition("source authority lost during the transition")
            return
        }
        // Complete frozen tuple before any artifact write: a token
        // minted for one base must never fill a slot frozen to another,
        // even on the same origin. Source proven still owned, so this
        // refusal is safe — durable authority unchanged.
        guard let target = document.profiles.first(where: { $0.id == profileID }),
              let bound = target.boundAccount,
              AccountIdentity.matches(bound.userID, authorization.user.id),
              bound.originKey == authorization.backend.origin.originKey,
              bound.issuerOrigin == authorization.backend.origin.normalized,
              AccountIdentity.matches(
                  bound.apiBaseURL, authorization.backend.apiBaseURL.absoluteString
              ) else {
            dependencies.resumeAfterRefusedTransition()
            step = .failed(String(
                localized: "The profile switch was not saved — nothing changed."
            ))
            return
        }
        do {
            let account = SessionTokenKey.account(
                profileID: profileID, originKey: bound.originKey
            )
            try dependencies.secretStore.set(
                CadenzaAuthService.encodeTokenValue(authorization.token), for: account
            )
            try dependencies.sessionUserStore(profileID).save(
                authorization.user.sessionUserRecord()
            )
        } catch {
            // Partial artifacts stay inert in the target's own slot; the
            // durable authority is unchanged.
            dependencies.resumeAfterRefusedTransition()
            step = .failed(AuthError.classify(error).localizedMessage())
            return
        }
        let expectedBound = bound
        let outcome = ProfileSwitchCoordinator.commitActiveProfile(
            to: profileID,
            registry: dependencies.registry,
            precondition: { [self] fresh in
                // Post-drain re-proof of source authority and the
                // byte-exact target tuple.
                guard sourceStillAuthoritative(in: fresh) else {
                    return "source authority changed during the transition"
                }
                guard fresh.pendingBinding == nil, fresh.pendingTransfer == nil,
                      let profile = fresh.profiles.first(where: { $0.id == profileID }),
                      let freshBound = profile.boundAccount,
                      AccountIdentity.matches(freshBound.userID, expectedBound.userID),
                      AccountIdentity.matches(freshBound.originKey, expectedBound.originKey),
                      AccountIdentity.matches(
                          freshBound.issuerOrigin, expectedBound.issuerOrigin
                      ),
                      AccountIdentity.matches(
                          freshBound.apiBaseURL, expectedBound.apiBaseURL
                      ) else {
                    return "account profile changed during login"
                }
                return nil
            },
            mutate: { fresh in
                guard let index = fresh.profiles.firstIndex(where: { $0.id == profileID })
                else { return }
                fresh.profiles[index].isLocked = false
                fresh.profiles[index].sessionDisposition = .active
                fresh.profiles[index].lastActiveAt = dependencies.now()
            }
        )
        discardAuthorization()
        switch outcome {
        case .committed:
            step = .relaunching
            dependencies.relaunch()
        case .notCommitted(let detail):
            NSLog("[ProfileLogin] switch not committed: %@", detail)
            dependencies.resumeAfterRefusedTransition()
            step = .failed(String(
                localized: "The profile switch was not saved — nothing changed."
            ))
        case .indeterminate(let detail):
            NSLog("[ProfileLogin] switch indeterminate: %@", detail)
            step = .failed(String(
                localized: "A profile change didn't finish. Quit and reopen Cadenza to continue."
            ))
            dependencies.haltTransition(detail)
        }
    }

    /// Binds the current (standard, unbound) profile through the two-phase
    /// transaction; B2 runs through the open container.
    func bindCurrentProfile() async {
        guard case .chooseTarget(let canBindCurrent, _) = step, canBindCurrent,
              let authorization = pendingAuthorization else { return }
        await bind(
            profileID: dependencies.activeProfile.id,
            authorization: authorization,
            activeStore: dependencies.activeStore
        )
    }

    /// Creates a fresh account profile and binds it: the profile row is
    /// created by phase A of the binding transaction itself, so a crash or
    /// failure at any point rolls the whole creation back with the
    /// transaction — no standalone inert-profile commit exists.
    func createAccountProfile() async {
        guard case .chooseTarget = step,
              let authorization = pendingAuthorization else { return }
        let profileID = UUID()
        let name = authorization.user.displayName.isEmpty
            ? authorization.user.email : authorization.user.displayName
        // Clean preferences: the mapping marker blocks any global copy,
        // written before the transaction commits (an orphan marker for a
        // discarded UUID is harmless, the reverse order leaks globals).
        dependencies.defaults.set(
            true,
            forKey: ProfileScopedDefaults.scopedKey(
                ProfileScopedDefaults.mappingMarkerKey, profileID: profileID
            )
        )
        await bind(
            profileID: profileID,
            authorization: authorization,
            activeStore: dependencies.activeStore,
            create: ProfileBindingTransaction.NewProfileTemplate(
                name: name,
                audioDirectory: .init(
                    bookmark: nil,
                    path: ProfileAudioRootWriter.appManagedDefaultPath(profileID: profileID),
                    kind: .appManaged
                )
            )
        )
    }

    private enum BindResult: Equatable {
        case bound
        case failed(indeterminate: Bool)
    }

    @discardableResult
    private func bind(
        profileID: UUID,
        authorization: CadenzaAuthService.AuthorizationResult,
        activeStore: ProfileBindingTransaction.ActiveStoreMarking,
        create: ProfileBindingTransaction.NewProfileTemplate? = nil
    ) async -> BindResult {
        do {
            let request = ProfileBindingTransaction.Request(
                profileID: profileID,
                userID: authorization.user.id,
                origin: authorization.backend.origin,
                apiBaseURL: authorization.backend.apiBaseURL.absoluteString,
                user: authorization.user.sessionUserRecord(),
                tokenRaw: try CadenzaAuthService.encodeTokenValue(authorization.token),
                create: create,
                sourceAuthority: .init(profile: dependencies.activeProfile)
            )
            let committed = try await ProfileBindingTransaction.run(
                request: request,
                dependencies: bindingDependencies,
                activeStore: activeStore
            )
            expectedBinding = (
                userID: authorization.user.id,
                originKey: authorization.backend.origin.originKey,
                issuerOrigin: authorization.backend.origin.normalized,
                apiBaseURL: authorization.backend.apiBaseURL.absoluteString
            )
            // Transfer eligibility comes from the committed document, at
            // the moment of commit: a created profile whose row carries
            // this binding's creation transaction, reached from the
            // system Local. Anything else never offers a transfer.
            transferOffer = nil
            if create != nil,
               dependencies.activeProfile.kind == .system,
               let row = committed.profiles.first(where: { $0.id == profileID }),
               let creation = row.createdByBindingTransactionID {
                transferOffer = (profileID: profileID, creationTransactionID: creation)
            }
            discardAuthorization()
            step = .consent(profileID: profileID)
            return .bound
        } catch {
            // Lost source authority halts like every other
            // lost-authority path; ordinary target and precondition
            // failures stay retryable refusals.
            if case ProfileBindingTransaction.BindingError.sourceAuthorityLost = error {
                step = .failed(String(
                    localized: "A profile change didn't finish. Quit and reopen Cadenza to continue."
                ))
                dependencies.haltTransition(String(describing: error))
                return .failed(indeterminate: true)
            }
            step = .failed(AuthError.classify(error).localizedMessage())
            if case ProfileBindingTransaction.BindingError.commitIndeterminate = error {
                dependencies.haltTransition(String(describing: error))
                return .failed(indeterminate: true)
            }
            return .failed(indeterminate: false)
        }
    }

    /// Records the consent decision for the bound profile, switches the
    /// registry's active profile to it, and relaunches. Skipping leaves
    /// the consent undecided — nothing historical syncs (INV-15). The
    /// switch requires exactly the profile the binding committed — bound
    /// to the expected identity, unlocked, no operation in flight; any
    /// drift is a hard failure (a persisted consent alone is not
    /// success).
    func finishWithConsent(_ consent: HistoricalSyncConsent?) async {
        guard case .consent(let profileID) = step,
              let expected = expectedBinding else { return }
        if let offer = transferOffer, offer.profileID == profileID {
            // Local-data placement is its own decision: stash the consent
            // and decide the transition after the transfer choice, so
            // both writes share one quiescence window.
            stashedConsent = consent
            blockedReason = nil
            step = .transferChoice(profileID: profileID)
            return
        }
        guard await preparedProvenTransition(
            profileID: profileID, expected: expected
        ) else { return }
        writeConsent(consent, profileID: profileID)
        commitAndRelaunch(profileID: profileID, expected: expected)
    }

    /// The Local-data decision for a profile this login created from the
    /// system Local. Keep-separate is the plain switch; copy and move
    /// write the durable transfer intent and relaunch into transfer
    /// mode — the active profile stays the Local source until the
    /// executor's own commit switches it.
    func finishTransferChoice(_ choice: TransferChoice) async {
        guard case .transferChoice(let profileID) = step,
              let expected = expectedBinding,
              let offer = transferOffer, offer.profileID == profileID else { return }
        guard await preparedProvenTransition(
            profileID: profileID, expected: expected
        ) else { return }
        switch choice {
        case .keepSeparate:
            writeConsent(stashedConsent, profileID: profileID)
            commitAndRelaunch(profileID: profileID, expected: expected)
        case .copy, .move:
            do {
                _ = try dependencies.beginTransfer(ProfileTransfer.Request(
                    sourceProfileID: dependencies.activeProfile.id,
                    targetProfileID: profileID,
                    mode: choice == .move ? .move : .copy,
                    creationTransactionID: offer.creationTransactionID
                ))
                // Consent persists only after the durable intent exists:
                // a refused start leaves the registry and the consent
                // both unchanged, keeping the refusal message literal.
                writeConsent(stashedConsent, profileID: profileID)
                step = .relaunching
                dependencies.transferRelaunch()
            } catch ProfileTransfer.TransferError.commitIndeterminate(let detail) {
                NSLog("[ProfileLogin] transfer begin indeterminate: %@", detail)
                step = .failed(String(
                    localized: "A profile change didn't finish. Quit and reopen Cadenza to continue."
                ))
                dependencies.haltTransition(detail)
            } catch {
                // Preflight refusals and provably-uncommitted saves leave
                // the registry unchanged: services resume and the choice
                // stays open.
                NSLog("[ProfileLogin] transfer begin refused: %@", String(describing: error))
                dependencies.resumeAfterRefusedTransition()
                blockedReason = String(
                    localized: "The transfer couldn't start — nothing changed. Try again."
                )
            }
        }
    }

    /// Shared drain-then-prove preamble for every final login
    /// transition: refusal and quiescence gates, then the post-drain
    /// classification over a fresh document. Returns false with all
    /// failure side effects (blockedReason, failed step, halt, resume)
    /// already applied.
    private func preparedProvenTransition(
        profileID: UUID,
        expected: (userID: String, originKey: String, issuerOrigin: String, apiBaseURL: String)
    ) async -> Bool {
        if let reason = dependencies.transitionRefusal() {
            blockedReason = reason
            return false
        }
        blockedReason = nil
        guard await dependencies.prepareTransition() else {
            blockedReason = String(
                localized: "Cadenza couldn't pause background work — nothing changed. Try again."
            )
            return false
        }
        // Post-drain classification mirroring the switch path: unknown
        // or lost source authority halts; a readable document proving
        // the source still owned makes a target mismatch a safe refusal
        // before the consent write.
        let fresh: ProfileRegistryDocument
        do {
            fresh = try dependencies.registry.load()
        } catch {
            NSLog("[ProfileLogin] registry unreadable after drain: %@", String(describing: error))
            step = .failed(String(
                localized: "A profile change didn't finish. Quit and reopen Cadenza to continue."
            ))
            dependencies.haltTransition("registry unreadable after the drain: \(error)")
            return false
        }
        guard fresh.activeProfileID == dependencies.activeProfile.id,
              fresh.pendingBinding == nil, fresh.pendingTransfer == nil else {
            step = .failed(String(
                localized: "A profile change didn't finish. Quit and reopen Cadenza to continue."
            ))
            dependencies.haltTransition("source authority lost during the transition")
            return false
        }
        let targetStillExpected: Bool = {
            guard let profile = fresh.profiles.first(where: { $0.id == profileID }),
                  !profile.isLocked,
                  let bound = profile.boundAccount else { return false }
            return AccountIdentity.matches(bound.userID, expected.userID)
                && AccountIdentity.matches(bound.originKey, expected.originKey)
                && AccountIdentity.matches(bound.issuerOrigin, expected.issuerOrigin)
                && AccountIdentity.matches(bound.apiBaseURL, expected.apiBaseURL)
        }()
        guard targetStillExpected else {
            dependencies.resumeAfterRefusedTransition()
            step = .failed(String(
                localized: "The profile switch was not saved — nothing changed."
            ))
            return false
        }
        return true
    }

    private func writeConsent(_ consent: HistoricalSyncConsent?, profileID: UUID) {
        guard let consent else { return }
        let scope = ProfileDefaultsScope(
            defaults: dependencies.defaults, profileID: profileID
        )
        consent.write(to: scope)
    }

    private func commitAndRelaunch(
        profileID: UUID,
        expected: (userID: String, originKey: String, issuerOrigin: String, apiBaseURL: String)
    ) {
        let outcome = ProfileSwitchCoordinator.commitActiveProfile(
            to: profileID,
            registry: dependencies.registry,
            precondition: { [self] document in
                // The source slot must not have been taken over during
                // quiescence: for bind-current the target equals the
                // source; for create it differs, but in both cases the
                // fresh active ID must still be this process's profile.
                guard document.activeProfileID == dependencies.activeProfile.id else {
                    return "source authority changed during the transition"
                }
                guard document.pendingBinding == nil, document.pendingTransfer == nil,
                      let profile = document.profiles.first(where: { $0.id == profileID }),
                      !profile.isLocked,
                      let bound = profile.boundAccount,
                      AccountIdentity.matches(bound.userID, expected.userID),
                      AccountIdentity.matches(bound.originKey, expected.originKey),
                      AccountIdentity.matches(bound.issuerOrigin, expected.issuerOrigin),
                      AccountIdentity.matches(bound.apiBaseURL, expected.apiBaseURL) else {
                    return "bound profile changed before the switch"
                }
                return nil
            },
            mutate: { document in
                guard let index = document.profiles.firstIndex(where: { $0.id == profileID })
                else { return }
                document.profiles[index].lastActiveAt = dependencies.now()
            }
        )
        switch outcome {
        case .committed:
            step = .relaunching
            dependencies.relaunch()
        case .notCommitted(let detail):
            NSLog("[ProfileLogin] consent switch not committed: %@", detail)
            dependencies.resumeAfterRefusedTransition()
            step = .failed(String(
                localized: "The profile switch was not saved — nothing changed."
            ))
        case .indeterminate(let detail):
            NSLog("[ProfileLogin] consent switch indeterminate: %@", detail)
            step = .failed(String(
                localized: "A profile change didn't finish. Quit and reopen Cadenza to continue."
            ))
            dependencies.haltTransition(detail)
        }
    }


    func reset() {
        blockedReason = nil
        discardAuthorization()
        step = .idle
    }

    private var isFailure: Bool {
        if case .failed = step { return true }
        return false
    }

    private func discardAuthorization() {
        pendingAuthorization = nil
    }
}
