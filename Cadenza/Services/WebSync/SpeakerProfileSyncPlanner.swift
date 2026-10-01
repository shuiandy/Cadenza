import Foundation

/// What this device last agreed with the server about, kept per local profile
/// store and account.
///
/// A fingerprint is recorded when a record is pushed or when a remote copy is
/// applied. A local record whose current fingerprint differs from the recorded
/// one has edits the server has not seen; a record the device applied from the
/// server matches its fingerprint and so is never echoed back.
struct SpeakerProfileSyncLedger: Codable, Sendable, Equatable {
    var cursor: Int64 = 0
    /// Nil until the first pull. A server-side purge bumps a generation, and a
    /// mismatch discards the whole ledger so everything is sent again.
    var identityGeneration: Int64?
    var voiceGeneration: Int64?
    var profiles: [UUID: String] = [:]
    var samples: [SpeakerSyncSampleKey: String] = [:]
}

/// The device's speaker data as the protocol sees it.
struct SpeakerSyncLocalSnapshot: Sendable, Equatable {
    var profiles: [UUID: SpeakerSyncProfile] = [:]
    /// Confirmed samples of one embedding model only. Empty when local voice
    /// memory consent is off.
    var samples: [SpeakerSyncSampleKey: SpeakerSyncSample] = [:]
    var samplesConsented = false
}

/// A remote write that lands only if the local record still has the
/// fingerprint the plan saw (nil: the record must still be absent). The store
/// checks this inside its actor, so a local edit made while the pass was
/// waiting on the network is never overwritten.
struct SpeakerSyncGuardedProfileWrite: Sendable, Equatable {
    let profile: SpeakerSyncProfile
    let expectedLocalFingerprint: String?
}

struct SpeakerSyncGuardedSampleWrite: Sendable, Equatable {
    let sample: SpeakerSyncSample
    let expectedLocalFingerprint: String?
}

struct SpeakerSyncGuardedSampleDeletion: Sendable, Equatable {
    let key: SpeakerSyncSampleKey
    let expectedLocalFingerprint: String
}

/// What the store actually did with an apply plan.
struct SpeakerSyncApplyOutcome: Sendable, Equatable {
    var appliedProfiles: [UUID: String] = [:]
    var appliedSamples: [SpeakerSyncSampleKey: String] = [:]
    /// Samples that are gone locally, whether deleted now or already absent.
    var removedSamples: Set<SpeakerSyncSampleKey> = []
}

enum SpeakerProfileSyncPlanner {
    struct ApplyPlan: Sendable, Equatable {
        var profileDeletions: [UUID] = []
        var profileWrites: [SpeakerSyncGuardedProfileWrite] = []
        var sampleWrites: [SpeakerSyncGuardedSampleWrite] = []
        var sampleDeletions: [SpeakerSyncGuardedSampleDeletion] = []
        /// Remote records identical to the local copy. Only the ledger changes.
        var matchingProfiles: [UUID: String] = [:]
        var matchingSamples: [SpeakerSyncSampleKey: String] = [:]
        /// Tombstones for records this device does not hold.
        var forgottenProfiles: [UUID] = []
        var forgottenSamples: [SpeakerSyncSampleKey] = []

        var hasStoreWork: Bool {
            !profileDeletions.isEmpty || !profileWrites.isEmpty
                || !sampleWrites.isEmpty || !sampleDeletions.isEmpty
        }
    }

    struct PushPlan: Sendable, Equatable {
        var profiles: [SpeakerSyncProfile] = []
        var samples: [SpeakerSyncSample] = []
        var deletedSamples: [SpeakerSyncSampleKey] = []
        /// Profiles the ledger knows but the store no longer holds, which
        /// happens after a local store is restored from an older backup. The
        /// Mac has no profile deletion surface, so absence is never read as a
        /// deletion; the caller re-pulls from the start to bring them back.
        var missingLocalProfiles: [UUID] = []

        var isEmpty: Bool {
            profiles.isEmpty && samples.isEmpty && deletedSamples.isEmpty
        }
    }

    static let maxProfilesPerRequest = 200
    static let maxSamplesPerRequest = 200
    static let maxSampleDeletionsPerRequest = 500

    /// Decides what one pulled page changes locally.
    ///
    /// Rules: a tombstone wins over local edits for profiles, because the user
    /// deleted that person somewhere; a live remote record replaces the local
    /// copy only when the local copy has no unpushed edits. Samples of another
    /// embedding model, or arriving while samples are not allowed, are ignored.
    static func planApply(
        profiles: [SpeakerSyncProfileChange],
        samples: [SpeakerSyncSampleChange],
        local: SpeakerSyncLocalSnapshot,
        ledger: SpeakerProfileSyncLedger,
        samplesAllowed: Bool,
        modelVersion: String
    ) -> ApplyPlan {
        var plan = ApplyPlan()
        var deletedProfileIDs = Set<UUID>()
        var writtenProfileIDs = Set<UUID>()

        for change in profiles {
            let id = change.profileID
            if change.deleted {
                deletedProfileIDs.insert(id)
                if local.profiles[id] != nil {
                    plan.profileDeletions.append(id)
                } else {
                    plan.forgottenProfiles.append(id)
                }
                continue
            }
            guard let remote = change.profile else { continue }
            let remoteFingerprint = remote.fingerprint
            guard let current = local.profiles[id] else {
                plan.profileWrites.append(.init(profile: remote, expectedLocalFingerprint: nil))
                writtenProfileIDs.insert(id)
                continue
            }
            let localFingerprint = current.fingerprint
            if localFingerprint == remoteFingerprint {
                plan.matchingProfiles[id] = remoteFingerprint
            } else if ledger.profiles[id] == localFingerprint {
                plan.profileWrites.append(.init(profile: remote, expectedLocalFingerprint: localFingerprint))
                writtenProfileIDs.insert(id)
            }
        }

        guard samplesAllowed else { return plan }
        for change in samples where change.key.modelVersion == modelVersion {
            let key = change.key
            let current = local.samples[key]
            if change.deleted {
                guard let current else {
                    plan.forgottenSamples.append(key)
                    continue
                }
                let localFingerprint = current.fingerprint
                if ledger.samples[key] == localFingerprint {
                    plan.sampleDeletions.append(.init(key: key, expectedLocalFingerprint: localFingerprint))
                }
                continue
            }
            guard let remote = change.sample else { continue }
            let profileAvailable = !deletedProfileIDs.contains(remote.profileID)
                && (local.profiles[remote.profileID] != nil || writtenProfileIDs.contains(remote.profileID))
            guard profileAvailable else { continue }
            let remoteFingerprint = remote.fingerprint
            guard let current else {
                plan.sampleWrites.append(.init(sample: remote, expectedLocalFingerprint: nil))
                continue
            }
            let localFingerprint = current.fingerprint
            if localFingerprint == remoteFingerprint {
                plan.matchingSamples[key] = remoteFingerprint
            } else if ledger.samples[key] == localFingerprint {
                plan.sampleWrites.append(.init(sample: remote, expectedLocalFingerprint: localFingerprint))
            }
        }
        return plan
    }

    /// Folds an applied page into the ledger. Records the store skipped keep
    /// their old fingerprint, so their local edits are pushed next.
    static func record(
        plan: ApplyPlan,
        outcome: SpeakerSyncApplyOutcome,
        into ledger: inout SpeakerProfileSyncLedger
    ) {
        for id in plan.profileDeletions + plan.forgottenProfiles {
            ledger.profiles.removeValue(forKey: id)
        }
        for (id, fingerprint) in plan.matchingProfiles.merging(outcome.appliedProfiles, uniquingKeysWith: { $1 }) {
            ledger.profiles[id] = fingerprint
        }
        for key in plan.forgottenSamples {
            ledger.samples.removeValue(forKey: key)
        }
        for key in outcome.removedSamples {
            ledger.samples.removeValue(forKey: key)
        }
        for (key, fingerprint) in plan.matchingSamples.merging(outcome.appliedSamples, uniquingKeysWith: { $1 }) {
            ledger.samples[key] = fingerprint
        }
    }

    /// Decides what this device must send. Sample deletions are limited to the
    /// device's own embedding model: after a model upgrade the ledger still
    /// holds the old model's keys, and other devices on that model need them.
    static func planPush(
        local: SpeakerSyncLocalSnapshot,
        ledger: SpeakerProfileSyncLedger,
        samplesAllowed: Bool,
        modelVersion: String
    ) -> PushPlan {
        var plan = PushPlan()
        plan.profiles = local.profiles.values
            .filter { ledger.profiles[$0.profileID] != $0.fingerprint }
            .sorted { $0.profileID.uuidString < $1.profileID.uuidString }
        plan.missingLocalProfiles = ledger.profiles.keys
            .filter { local.profiles[$0] == nil }
            .sorted { $0.uuidString < $1.uuidString }

        guard samplesAllowed else { return plan }
        plan.samples = local.samples.values
            .filter { ledger.samples[$0.key] != $0.fingerprint }
            .sorted(by: sampleOrder)
        plan.deletedSamples = ledger.samples.keys
            .filter { $0.modelVersion == modelVersion && local.samples[$0] == nil }
            .sorted(by: keyOrder)
        return plan
    }

    /// Splits a push into requests within the server's limits. Profile
    /// requests go first, so every sample finds its profile already stored.
    static func requests(
        for plan: PushPlan,
        identityGeneration: Int64,
        voiceGeneration: Int64?
    ) -> [SpeakerSyncPushRequest] {
        var requests: [SpeakerSyncPushRequest] = []
        for chunk in plan.profiles.chunked(into: maxProfilesPerRequest) {
            requests.append(SpeakerSyncPushRequest(
                identityGeneration: identityGeneration,
                voiceGeneration: nil,
                profiles: chunk,
                deletedProfileIDs: [],
                samples: [],
                deletedSamples: []
            ))
        }
        guard let voiceGeneration else { return requests }
        let sampleChunks = plan.samples.chunked(into: maxSamplesPerRequest)
        let deletionChunks = plan.deletedSamples.chunked(into: maxSampleDeletionsPerRequest)
        for index in 0..<max(sampleChunks.count, deletionChunks.count) {
            requests.append(SpeakerSyncPushRequest(
                identityGeneration: identityGeneration,
                voiceGeneration: voiceGeneration,
                profiles: [],
                deletedProfileIDs: [],
                samples: index < sampleChunks.count ? sampleChunks[index] : [],
                deletedSamples: index < deletionChunks.count ? deletionChunks[index] : []
            ))
        }
        return requests
    }

    /// Folds an accepted push into the ledger. Skipped records keep their old
    /// fingerprint and are offered again on the next pass.
    static func record(
        pushed request: SpeakerSyncPushRequest,
        response: SpeakerSyncPushResponse,
        into ledger: inout SpeakerProfileSyncLedger
    ) {
        let skippedProfiles = Set(response.skippedProfileIDs)
        let skippedSamples = Set(response.skippedSamples)
        for profile in request.profiles where !skippedProfiles.contains(profile.profileID) {
            ledger.profiles[profile.profileID] = profile.fingerprint
        }
        for sample in request.samples where !skippedSamples.contains(sample.key) {
            ledger.samples[sample.key] = sample.fingerprint
        }
        for key in request.deletedSamples {
            ledger.samples.removeValue(forKey: key)
        }
    }

    private static func keyOrder(_ lhs: SpeakerSyncSampleKey, _ rhs: SpeakerSyncSampleKey) -> Bool {
        (lhs.recordingID.uuidString, lhs.rawLabel, lhs.modelVersion)
            < (rhs.recordingID.uuidString, rhs.rawLabel, rhs.modelVersion)
    }

    private static func sampleOrder(_ lhs: SpeakerSyncSample, _ rhs: SpeakerSyncSample) -> Bool {
        keyOrder(lhs.key, rhs.key)
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
