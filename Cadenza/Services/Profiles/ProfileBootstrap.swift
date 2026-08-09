import Foundation

/// What the app boots against, decided before any ModelContainer opens.
struct ProfileBootContext: Equatable {
    enum Mode: Equatable {
        case profile(UUID)
        /// Pre-commit migration failure: legacy locations stay in use, the
        /// reason surfaces in Settings.
        case legacyFallback(reason: String)
        /// A committed registry exists but can neither be read nor
        /// recovered. Booting legacy would create a second authority over
        /// migrated data, so startup must stop visibly instead.
        case halted(reason: String)
        /// A valid pending transfer intercepted the boot: the process
        /// belongs to the dedicated transfer executor and never opens a
        /// normal ModelContainer or profile context (spec §6.4).
        case transfer(PendingTransfer)
    }

    let mode: Mode
    /// nil outside profile mode.
    let storeURL: URL?
    let chatHistoryDirectory: URL?
    let backupsDirectory: URL?
    /// Registry snapshot of the resolved profile the process runs as
    /// (after lock/missing fallback to Local). Set by the pipeline entry;
    /// nil outside profile mode and for the M1-only stage.
    var profile: Profile?

    init(
        mode: Mode,
        storeURL: URL?,
        chatHistoryDirectory: URL?,
        backupsDirectory: URL?,
        profile: Profile? = nil
    ) {
        self.mode = mode
        self.storeURL = storeURL
        self.chatHistoryDirectory = chatHistoryDirectory
        self.backupsDirectory = backupsDirectory
        self.profile = profile
    }

    static func legacy(reason: String) -> ProfileBootContext {
        ProfileBootContext(
            mode: .legacyFallback(reason: reason),
            storeURL: nil,
            chatHistoryDirectory: nil,
            backupsDirectory: nil
        )
    }

    static func halted(reason: String) -> ProfileBootContext {
        ProfileBootContext(
            mode: .halted(reason: reason),
            storeURL: nil,
            chatHistoryDirectory: nil,
            backupsDirectory: nil
        )
    }

    static func transfer(_ pending: PendingTransfer) -> ProfileBootContext {
        ProfileBootContext(
            mode: .transfer(pending),
            storeURL: nil,
            chatHistoryDirectory: nil,
            backupsDirectory: nil
        )
    }
}

/// Boot-time decision: which store to open, running or resuming the M1
/// migration as needed. The registry is the commit-point artifact — when it
/// exists, the profile store is the authority and the legacy path is never
/// used again; an unreadable registry is recovered only through a validated
/// journal and a verified target, never guessed around.
enum ProfileBootstrap {

    /// Live entry, called exactly once from app startup before the model
    /// container is created. Structurally unreachable from test runs: the
    /// caller branches on `AppState.isRunningTests` first, and this
    /// precondition backstops that.
    @MainActor
    static func runLive() -> ProfileBootContext {
        // The environment decides which data plane exists at all; the live
        // path derivation flows through it, and an ephemeral environment
        // (every test run) makes this entry unreachable.
        let environment = ProfileEnvironment.current()
        guard case .live = environment else {
            preconditionFailure("ProfileBootstrap.runLive must never run in the TestHost")
        }
        let paths = environment.paths
        let fileOperations = LiveFileOperations()
        let registry = DiskProfileRegistry(
            registryURL: paths.registryURL, fileOperations: fileOperations
        )
        let dependencies = M1StorageMigration.Dependencies(
            paths: paths,
            registry: registry,
            fileOperations: fileOperations,
            backupDriver: LiveSQLiteBackupDriver(),
            audioRoot: { StorageLocationManager.recordingsDirectory },
            audioDirectoryState: { operativeAudioDirectoryState() },
            scopedDefaults: ProfileScopedDefaults.standard(),
            now: { Date() }
        )
        let session = SessionMigrationDependencies(
            registry: registry,
            secretStore: KeychainAuthSecretStore(),
            sessionUserStore: { id in
                FileSessionUserStore(
                    url: paths.sessionUserURL(id), fileOperations: fileOperations
                )
            },
            marker: SwiftDataHistoricalConsentMarker(),
            storeURL: { paths.storeURL($0) },
            storePresence: ProfileBindingTransaction.classifiedStorePresence(
                fileOperations: fileOperations
            ),
            profileDirectoryPresence: { id in
                do {
                    _ = try fileOperations.attributesOfItem(at: paths.profileDirectory(id))
                    return true
                } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                    return false
                }
            },
            defaults: .standard,
            backend: CadenzaBackendConfig.official(),
            newLocalAudioDirectory: { id in
                Profile.AudioDirectory(
                    bookmark: nil,
                    path: ProfileAudioRootWriter.appManagedDefaultPath(profileID: id),
                    kind: .appManaged
                )
            },
            now: { Date() }
        )
        return runPipeline(dependencies: dependencies, session: session)
    }

    /// Full boot pipeline: the M1 storage stage, then — in profile mode —
    /// binding recovery, M2, M3, and the final active-profile resolution
    /// with its pre-container gate. Session stages never run in legacy
    /// fallback (no registry) and any unclassifiable state halts.
    @MainActor
    static func runPipeline(
        dependencies: M1StorageMigration.Dependencies,
        session: SessionMigrationDependencies,
        transferInspector: (any TransferStoreInspecting)? = nil
    ) -> ProfileBootContext {
        let inspector = transferInspector
            ?? LiveTransferStoreInspector(fileOperations: dependencies.fileOperations)
        let transferDependencies = ProfileTransfer.Dependencies(
            registry: session.registry,
            storeURL: session.storeURL,
            inspector: inspector,
            fileOperations: dependencies.fileOperations,
            now: session.now
        )
        let stage = run(dependencies: dependencies, postLoadAuthorityGate: { document in
            // The phase-authority seal precedes every session-stage
            // effect, including transfer interception: a pending
            // transfer itself proves later authority, so the seal must
            // be durably committed before the process may enter any
            // session-authority mode. A write not proven committed
            // halts — a single-release build never runs an unsealed
            // session-authority runtime; the registry stays in its M1
            // shape and the next launch retries.
            let seal = PhaseAuthoritySealStore(
                paths: dependencies.paths,
                fileOperations: dependencies.fileOperations
            )
            switch seal.ensureSealed(now: session.now()) {
            case .committed:
                break
            case .notCommitted(let detail):
                return .finish(.halted(
                    reason: "phase authority seal not durable: \(detail)"
                ))
            case .unknown(let detail):
                return .finish(.halted(
                    reason: "phase authority seal unprobeable: \(detail)"
                ))
            }
            ProfileTransferExecutor.sweepPriorProcessScratch(
                document: document,
                paths: dependencies.paths,
                fileOperations: dependencies.fileOperations,
                scratchTracker: .shared
            )
            return interceptPendingTransfer(
                document: document, dependencies: transferDependencies
            )
        })
        guard case .profile = stage.mode else { return stage }

        let registry = dependencies.registry
        let initial: ProfileRegistryDocument
        do {
            initial = try registry.load()
        } catch {
            return .halted(reason: "registry unreadable before session stages")
        }

        switch ProfileBindingTransaction.recover(
            document: initial, dependencies: session.bindingDependencies
        ) {
        case .halted(let reason):
            return .halted(reason: "binding recovery: \(reason)")
        case .noPending, .completed, .rolledBack:
            break
        }

        switch M2SessionMigration.run(session: session) {
        case .halted(let reason):
            return .halted(reason: "session migration: \(reason)")
        case .nothingToDo, .completed:
            break
        }

        switch M3LocalMigration.run(session: session) {
        case .halted(let reason):
            return .halted(reason: "local establishment: \(reason)")
        case .alreadyEstablished, .promoted, .created:
            break
        }

        var document: ProfileRegistryDocument
        do {
            document = try registry.load()
        } catch {
            return .halted(reason: "registry unreadable after session stages")
        }

        let resolved: Profile
        switch ActiveProfileResolution.resolve(document: document) {
        case .active(let profile):
            resolved = profile
        case .fallbackToLocal(let local, let reason):
            // INV-1: a locked active profile boots as Local. Persist the
            // switch so the materialization boundary and every later
            // consumer agree on the active identity.
            NSLog("[ProfileBootstrap] falling back to Local: %@", reason)
            document.activeProfileID = local.id
            do {
                try registry.save(document)
            } catch {
                return .halted(reason: "fallback to Local could not be recorded")
            }
            resolved = local
        case .unresolvable(let reason):
            return .halted(reason: reason)
        }

        if let haltReason = bootTargetProblem(profile: resolved, dependencies: dependencies) {
            return .halted(reason: haltReason)
        }
        var context = profileContext(for: resolved.id, dependencies: dependencies)
        context.profile = resolved
        return context
    }

    /// Capture of the legacy audio-root state for the M1 migration only:
    /// the global defaults keys are read once here to seed the registry's
    /// `audioDirectory`, which is the sole post-commit authority
    /// (registry-present boots never read these globals). The directory
    /// kind is deliberately `userSelected` for any inherited root: the
    /// app cannot prove exclusive management of a directory that predates
    /// the registry — the default location lives in the user's Documents
    /// folder and receives user files (that is why orphan recovery
    /// exists) — and `userSelected` grants no destructive rights.
    /// `appManaged` is set only for roots the app itself creates
    /// (per-profile defaults, reset targets).
    static func operativeAudioDirectoryState() -> Profile.AudioDirectory {
        let defaults = UserDefaults.standard
        // The global bookmark and its `userSelected` kind describe the real
        // library's directory. A relocated data plane (DEBUG only) must not
        // inherit either, or the profile it commits would carry the user's
        // recordings root into an instance meant to be isolated.
        if DebugDataRoot.isActive {
            return Profile.AudioDirectory(
                bookmark: nil,
                path: StorageLocationManager.recordingsDirectory.path,
                kind: .appManaged
            )
        }
        let bookmark = defaults.data(forKey: "recordingsDirectoryBookmark")
        return Profile.AudioDirectory(
            bookmark: bookmark,
            path: StorageLocationManager.recordingsDirectory.path,
            kind: .userSelected
        )
    }

    /// Outcome of the post-load authority gate, evaluated on the first
    /// trusted load of a registry-present boot (the pipeline runs the
    /// phase-authority seal and the transfer interception through it).
    enum PostLoadGateOutcome {
        /// Continue the normal boot with this document (a refused
        /// transfer has already cleared its pending record).
        case proceed(ProfileRegistryDocument)
        /// The boot resolved to a terminal context: transfer mode or a
        /// halt. No normal boot step may run.
        case finish(ProfileBootContext)
    }

    static func run(
        dependencies: M1StorageMigration.Dependencies,
        postLoadAuthorityGate: ((ProfileRegistryDocument) -> PostLoadGateOutcome)? = nil
    ) -> ProfileBootContext {
        let registry = dependencies.registry

        // Registry presence is classified: only a definite not-found may
        // start a migration — an unprobeable registry might be a committed
        // one and must go through the unreadable-registry recovery.
        switch registry.presence() {
        case .present:
            do {
                var document = try registry.load()
                // Transfer interception precedes every other boot step:
                // retire convergence, committed-state reconciliation, the
                // store gate, and the profile context (with its directory
                // preparation) all belong to a normal profile boot, and a
                // pending transfer must reach its dedicated mode without
                // any of them. Deferring retire convergence here is safe:
                // it only touches legacy source files, is idempotent, and
                // converges on the next normal boot.
                if let terminal = applyPostLoadGate(postLoadAuthorityGate, to: &document) {
                    return terminal
                }
                // A journal short of done under a committed registry means
                // retire is pending (possibly the journal write itself was
                // the casualty) — converge it without touching the target.
                M1StorageMigration(dependencies: dependencies)
                    .resumeRetireAfterCommit(activeProfileID: document.activeProfileID)
                reconcileCommittedState(document: document, dependencies: dependencies)
                // The store must prove itself BEFORE any container opens:
                // SwiftData silently creates an empty database at a
                // missing path, which would present migrated data as gone.
                if let haltReason = bootTargetProblem(
                    document: document, dependencies: dependencies
                ) {
                    return .halted(reason: haltReason)
                }
                return profileContext(for: document.activeProfileID, dependencies: dependencies)
            } catch {
                return recoverFromUnreadableRegistry(dependencies: dependencies)
            }
        case .unprobeable(let detail):
            NSLog("[ProfileBootstrap] registry presence unprobeable: %@", detail)
            return recoverFromUnreadableRegistry(dependencies: dependencies)
        case .absent:
            break
        }

        let migration = M1StorageMigration(dependencies: dependencies)
        switch migration.run() {
        case .completed(let id), .freshInstall(let id), .committedPendingRetire(let id):
            // The migration just wrote the registry; the same authority
            // gate and pre-container gate apply on this first trusted
            // load — the initial session-stage mutations are only
            // reachable behind a durable seal on every path.
            do {
                var document = try registry.load()
                if let terminal = applyPostLoadGate(postLoadAuthorityGate, to: &document) {
                    return terminal
                }
                if let haltReason = bootTargetProblem(
                    document: document, dependencies: dependencies
                ) {
                    return .halted(reason: haltReason)
                }
            } catch {
                return .halted(reason: "registry unreadable after commit")
            }
            return profileContext(for: id, dependencies: dependencies)
        case .failedPreCommit(let reason):
            NSLog("[ProfileBootstrap] migration failed pre-commit: %@", reason)
            return .legacy(reason: reason)
        case .halted(let reason):
            return .halted(reason: reason)
        }
    }

    // MARK: - Pieces

    private static func profileContext(
        for profileID: UUID, dependencies: M1StorageMigration.Dependencies
    ) -> ProfileBootContext {
        let paths = dependencies.paths
        // Auxiliary directories degrade explicitly: a directory that cannot
        // be created is reported as nil, and the startup wiring disables
        // the subsystem (in-memory chat, skipped backup) — profile mode
        // never touches the legacy locations.
        func prepared(_ directory: URL) -> URL? {
            do {
                try dependencies.fileOperations.createDirectory(at: directory)
                return directory
            } catch {
                NSLog(
                    "[ProfileBootstrap] directory creation failed for %@: %@",
                    directory.lastPathComponent, String(describing: error)
                )
                return nil
            }
        }
        return ProfileBootContext(
            mode: .profile(profileID),
            storeURL: paths.storeURL(profileID),
            chatHistoryDirectory: prepared(paths.chatHistoryDirectory(profileID)),
            backupsDirectory: prepared(paths.backupsDirectory(profileID))
        )
    }

    /// Registry present but unusable. Its existence marks a committed
    /// migration, so a legacy boot is never an option. Recovery requires a
    /// readable journal whose record reached the commit point AND a target
    /// that passes full validation; the registry is then re-established
    /// from that record. Anything less halts the boot visibly.
    private static func recoverFromUnreadableRegistry(
        dependencies: M1StorageMigration.Dependencies
    ) -> ProfileBootContext {
        // Phase-authority seal gate first: sealed or unclassifiable
        // session authority must never be rebuilt from the M1 journal —
        // including the promoted-Local shape, which leaves no directory
        // residue the scan below could see — regardless of what the
        // journal records.
        let seal = PhaseAuthoritySealStore(
            paths: dependencies.paths, fileOperations: dependencies.fileOperations
        )
        switch seal.classify() {
        case .sealed:
            return .halted(reason: "registry unreadable; phase 2 authority sealed")
        case .unknown(let detail):
            return .halted(reason: "registry unreadable; authority seal unprobeable: \(detail)")
        case .absent:
            break
        }
        let journalStore = MigrationJournalStore(
            paths: dependencies.paths, fileOperations: dependencies.fileOperations
        )
        let journal: MigrationJournalDocument?
        do {
            journal = try journalStore.load()
        } catch {
            return .halted(reason: "registry unreadable; journal unreadable")
        }
        guard let record = journal?.m1,
              record.state == .registryCommitted || record.state == .done else {
            return .halted(reason: "registry unreadable; no committed journal record")
        }
        // Later-authority residue gate: the journal can only rebuild the
        // single-profile M1 shape. Any evidence that a later authority
        // existed — profile directories beyond the journal's own, a
        // session-user artifact, or an unprobeable Profiles tree — means
        // the unreadable registry recorded more than M1 ever wrote, and
        // a rebuild would destroy it. Unknown probes halt too.
        switch laterAuthorityResidue(
            journalProfileID: record.profileID, dependencies: dependencies
        ) {
        case .none:
            break
        case .present(let detail):
            return .halted(reason: "registry unreadable; later authority residue: \(detail)")
        case .unprobeable(let detail):
            return .halted(reason: "registry unreadable; residue unprobeable: \(detail)")
        }
        // A target that never reached `done` should still be the untouched
        // migration product — bind it by exact digest. One that has served
        // as the live store since evolves legitimately and is validated
        // for integrity.
        let migration = M1StorageMigration(dependencies: dependencies)
        guard migration.validateCommittedTarget(
            record: record, requireExactDigest: record.state != .done
        ) else {
            return .halted(reason: "registry unreadable; target failed validation")
        }
        do {
            try migration.recommitRegistry(profileID: record.profileID)
        } catch {
            return .halted(reason: "registry unreadable; re-establishment failed")
        }
        NSLog(
            "[ProfileBootstrap] registry re-established from journal for %@",
            record.profileID.uuidString
        )
        return profileContext(for: record.profileID, dependencies: dependencies)
    }

    enum ResidueProbe: Equatable {
        case none
        case present(String)
        case unprobeable(String)
    }

    /// Classified probe for authority the M1 journal cannot describe.
    static func laterAuthorityResidue(
        journalProfileID: UUID,
        dependencies: M1StorageMigration.Dependencies
    ) -> ResidueProbe {
        let paths = dependencies.paths
        let operations = dependencies.fileOperations
        let entries: [URL]
        do {
            entries = try operations.contentsOfDirectory(at: paths.profilesDirectory)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .none
        } catch {
            return .unprobeable("profiles directory: \(error)")
        }
        for entry in entries {
            guard let id = UUID(uuidString: entry.lastPathComponent) else {
                return .present("foreign entry \(entry.lastPathComponent)")
            }
            guard id == journalProfileID else {
                return .present("profile directory beyond the journal: \(id.uuidString)")
            }
            do {
                _ = try operations.attributesOfItem(at: paths.sessionUserURL(id))
                return .present("session artifact for \(id.uuidString)")
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                continue
            } catch {
                return .unprobeable("session artifact probe: \(error)")
            }
        }
        return .none
    }

    /// Pre-container gate for a committed profile: nil when the boot may
    /// proceed, otherwise the halt reason. The one-time materialization
    /// boundary lives in the registry itself — only the active profile's
    /// explicit `storeMaterialized == false` permits a missing store to
    /// materialize; in every other state (including a wholly deleted
    /// profile directory) the store must be a readable database, because
    /// SwiftData would otherwise create an empty one silently.
    static func bootTargetProblem(
        document: ProfileRegistryDocument,
        dependencies: M1StorageMigration.Dependencies
    ) -> String? {
        guard let profile = document.profiles.first(where: {
            $0.id == document.activeProfileID
        }) else {
            return "active profile missing from registry"
        }
        return bootTargetProblem(profile: profile, dependencies: dependencies)
    }

    /// Same gate for an explicitly resolved profile (the pipeline may boot
    /// a fallback profile that is not the recorded active one yet).
    static func bootTargetProblem(
        profile: Profile,
        dependencies: M1StorageMigration.Dependencies
    ) -> String? {
        let storeURL = dependencies.paths.storeURL(profile.id)
        if !profile.storeMaterialized {
            // First materialization pending: an absent store is the
            // expected state, and a present one (crash between container
            // creation and the flag write) must already be readable.
            do {
                _ = try dependencies.fileOperations.attributesOfItem(at: storeURL)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                return nil
            } catch {
                return "store probe failed before materialization: \(String(describing: error))"
            }
        }
        do {
            try requireRegularFile(at: storeURL, fileOperations: dependencies.fileOperations)
            _ = try SQLiteLogicalDigest.digest(of: storeURL)
            return nil
        } catch {
            return "profile store unavailable: \(String(describing: error))"
        }
    }

    private static func applyPostLoadGate(
        _ gate: ((ProfileRegistryDocument) -> PostLoadGateOutcome)?,
        to document: inout ProfileRegistryDocument
    ) -> ProfileBootContext? {
        guard let gate else { return nil }
        switch gate(document) {
        case .finish(let context):
            return context
        case .proceed(let updated):
            document = updated
            return nil
        }
    }

    /// Routes a registry-present boot with a pending transfer: a valid
    /// record enters the dedicated transfer mode, a deterministic
    /// refusal clears the record (consuming the target's one-shot
    /// eligibility) and continues the normal boot, and anything
    /// unclassifiable halts.
    static func interceptPendingTransfer(
        document: ProfileRegistryDocument,
        dependencies: ProfileTransfer.Dependencies
    ) -> PostLoadGateOutcome {
        guard document.pendingTransfer != nil else { return .proceed(document) }
        switch ProfileTransfer.classifyAtBoot(
            document: document, dependencies: dependencies
        ) {
        case .run(let pending):
            return .finish(.transfer(pending))
        case .refusedAndCleared(let cleared, let reason):
            NSLog("[ProfileBootstrap] transfer refused at boot: %@", reason)
            return .proceed(cleared)
        case .halted(let reason):
            return .finish(.halted(reason: "transfer boot: \(reason)"))
        }
    }

    /// Flips the ACTIVE profile's materialization flag to true, atomically,
    /// right after its container was first created and before anything may
    /// write user data. The profile must be the registry's active one — a
    /// foreign or stale identifier throws with the registry unchanged. A
    /// failed save must halt the caller — proceeding would leave a
    /// writable store whose loss could later be mistaken for a pending
    /// first materialization.
    static func recordStoreMaterialized(
        profileID: UUID, dependencies: M1StorageMigration.Dependencies
    ) throws {
        try recordStoreMaterialized(profileID: profileID, registry: dependencies.registry)
    }

    /// Live wrapper for the startup wiring.
    @MainActor
    static func recordStoreMaterializedLive(profileID: UUID) throws {
        let paths = ProfilePaths.live()
        try recordStoreMaterialized(
            profileID: profileID,
            registry: DiskProfileRegistry(
                registryURL: paths.registryURL, fileOperations: LiveFileOperations()
            )
        )
    }

    private static func recordStoreMaterialized(
        profileID: UUID, registry: any ProfileRegistryProviding
    ) throws {
        let document = try registry.load()
        guard document.activeProfileID == profileID,
              let index = document.profiles.firstIndex(where: { $0.id == profileID }) else {
            throw ProfileRegistryError.invariantViolated(
                "materialization is bound to the active profile"
            )
        }
        guard !document.profiles[index].storeMaterialized else { return }
        var intended = document
        intended.profiles[index].storeMaterialized = true
        // Materialization consumes the creation provenance in the same
        // atomic write: a profile that has held a writable store must
        // never present as freshly created again (transfer eligibility
        // is one-shot, spec §6.4). Transfer interception runs before any
        // boot can reach this point.
        intended.profiles[index].createdByBindingTransactionID = nil
        switch ProfileSwitchCoordinator.classifiedSave(
            old: document, intended: intended, registry: registry
        ) {
        case .committed:
            return
        case .notCommitted(let detail):
            throw ProfileRegistryError.invariantViolated(
                "materialization not recorded: \(detail)"
            )
        case .indeterminate(let detail):
            throw ProfileRegistryError.invariantViolated(
                "materialization record indeterminate: \(detail)"
            )
        }
    }

    /// Post-commit reconciliation on every boot: the scoped-defaults
    /// mapping is re-applied when its completion marker is missing (the
    /// copy is idempotent), closing any crash window around the commit.
    /// The audio directory is NOT mirrored from UserDefaults — the
    /// registry's per-profile record is the root authority; root changes
    /// write it through `StorageLocationManager`'s installed recorder.
    static func reconcileCommittedState(
        document: ProfileRegistryDocument,
        dependencies: M1StorageMigration.Dependencies
    ) {
        let scoped = dependencies.scopedDefaults
        if !scoped.mappingComplete(for: document.activeProfileID) {
            scoped.copyGlobalValues(to: document.activeProfileID)
        }
    }
}
