import Foundation
import SwiftData

extension RecordingsStore {
    /// Every speaker profile, plus the confirmed voice samples of
    /// `modelVersion` while local voice memory consent is on. Nil when the
    /// store cannot be read, so a failed fetch is never mistaken for a store
    /// with no profiles.
    func speakerSyncSnapshot(modelVersion: String) -> SpeakerSyncLocalSnapshot? {
        var snapshot = SpeakerSyncLocalSnapshot()
        do {
            for profile in try modelContext.fetch(FetchDescriptor<SpeakerProfile>()) {
                snapshot.profiles[profile.id] = syncProfile(profile)
            }
        } catch {
            NSLog("[SpeakerSync] profile snapshot failed: %@", error.localizedDescription)
            return nil
        }

        snapshot.samplesConsented = isSpeakerMemoryEnabled()
        guard snapshot.samplesConsented else { return snapshot }
        let descriptor = FetchDescriptor<SpeakerVoiceSample>(
            predicate: #Predicate { $0.modelVersion == modelVersion && $0.profile != nil }
        )
        do {
            for model in try modelContext.fetch(descriptor) {
                guard let sample = syncSample(model, modelVersion: modelVersion) else { continue }
                if let existing = snapshot.samples[sample.key], existing.createdAt >= sample.createdAt {
                    continue
                }
                snapshot.samples[sample.key] = sample
            }
        } catch {
            NSLog("[SpeakerSync] sample snapshot failed: %@", error.localizedDescription)
            return nil
        }
        return snapshot
    }

    /// Applies one pulled page. Each write lands only if the local record
    /// still carries the fingerprint the plan was computed against, so an edit
    /// the user made while the pass waited on the network survives and is
    /// pushed instead. Returns nil when a save fails; the caller must not
    /// advance its cursor, and every step is safe to repeat.
    func applySpeakerSyncChanges(
        _ plan: SpeakerProfileSyncPlanner.ApplyPlan
    ) -> SpeakerSyncApplyOutcome? {
        var outcome = SpeakerSyncApplyOutcome()
        guard plan.hasStoreWork else { return outcome }
        // Commit unrelated queued work first so a rollback below can only
        // undo this batch.
        if modelContext.hasChanges, !save() { return nil }

        // Deletion goes through the same path as a local delete, which also
        // clears the person from every recording's mappings and suggestions.
        for id in plan.profileDeletions where speakerProfile(byID: id) != nil {
            guard deleteSpeakerProfile(id: id) else { return nil }
        }

        if !plan.profileWrites.isEmpty {
            guard applyProfileWrites(plan.profileWrites, into: &outcome) else {
                modelContext.rollback()
                detailCache.removeAll()
                return nil
            }
        }

        guard !plan.sampleWrites.isEmpty || !plan.sampleDeletions.isEmpty else { return outcome }
        // Voice samples follow local consent at write time, like every other
        // speaker-memory write; profiles above never needed it.
        guard isSpeakerMemoryEnabled() else { return outcome }
        let buckets = applySampleChanges(plan, into: &outcome)
        guard save() else {
            modelContext.rollback()
            detailCache.removeAll()
            return nil
        }
        // Same cap a local confirmation enforces, run after the inserts are
        // saved because its fetch does not see unsaved samples. Both devices
        // rank by quality then age, so holding the same samples they keep the
        // same five, and the ones dropped here are pushed as deletions next
        // pass.
        for bucket in buckets {
            enforceRetentionCap(
                profileID: bucket.profileID,
                modelVersion: bucket.modelVersion,
                embeddingDimension: bucket.dimension,
                maxSamples: 5
            )
        }
        return outcome
    }

    private struct RetentionBucket: Hashable {
        let profileID: UUID
        let modelVersion: String
        let dimension: Int
    }

    private func applyProfileWrites(
        _ writes: [SpeakerSyncGuardedProfileWrite],
        into outcome: inout SpeakerSyncApplyOutcome
    ) -> Bool {
        var renamedProfileIDs = Set<UUID>()
        for write in writes {
            let remote = write.profile
            let current = speakerProfile(byID: remote.profileID)
            guard current.map({ syncProfile($0).fingerprint }) == write.expectedLocalFingerprint else {
                continue
            }
            let target: SpeakerProfile
            if let current {
                if current.displayName != remote.displayName
                    || current.notes != remote.notes
                    || current.teamOrOrg != remote.teamOrOrg {
                    renamedProfileIDs.insert(remote.profileID)
                }
                target = current
            } else {
                target = SpeakerProfile(displayName: remote.displayName)
                target.id = remote.profileID
                modelContext.insert(target)
            }
            target.displayName = remote.displayName
            target.aliases = remote.aliases
            target.notes = remote.notes
            target.teamOrOrg = remote.teamOrOrg
            target.createdAt = Date(timeIntervalSince1970: TimeInterval(remote.createdAt))
            target.lastSeenAt = remote.lastSeenAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            outcome.appliedProfiles[remote.profileID] = remote.fingerprint
        }

        // A rename must reach every recording that shows the name, exactly as
        // a local rename does, so web sync re-sends their mappings.
        if !renamedProfileIDs.isEmpty {
            let recordings: [Recording]
            do {
                recordings = try modelContext.fetch(FetchDescriptor<Recording>())
            } catch {
                NSLog("[SpeakerSync] rename recording fetch failed: %@", error.localizedDescription)
                return false
            }
            for recording in recordings where
                (recording.speakerMappings ?? []).contains(where: { renamedProfileIDs.contains($0.profileID) })
                    || (recording.speakerSuggestions ?? []).contains(where: { renamedProfileIDs.contains($0.profileID) }) {
                touch(recording)
                invalidateDetailCache(recording.id)
            }
        }
        return save()
    }

    /// Stages sample writes and deletions; returns the retention buckets the
    /// writes touched.
    private func applySampleChanges(
        _ plan: SpeakerProfileSyncPlanner.ApplyPlan,
        into outcome: inout SpeakerSyncApplyOutcome
    ) -> Set<RetentionBucket> {
        var buckets = Set<RetentionBucket>()

        for deletion in plan.sampleDeletions {
            let key = deletion.key
            let existing = fetchVoiceSample(recordingID: key.recordingID, rawLabel: key.rawLabel)
            guard let existing,
                  let current = syncSample(existing, modelVersion: key.modelVersion) else {
                outcome.removedSamples.insert(key)
                continue
            }
            guard current.fingerprint == deletion.expectedLocalFingerprint else { continue }
            modelContext.delete(existing)
            outcome.removedSamples.insert(key)
        }

        for write in plan.sampleWrites {
            let sample = write.sample
            let key = sample.key
            let existing = fetchVoiceSample(recordingID: key.recordingID, rawLabel: key.rawLabel)
            let currentFingerprint = existing.flatMap { syncSample($0, modelVersion: key.modelVersion)?.fingerprint }
            guard currentFingerprint == write.expectedLocalFingerprint,
                  let profile = speakerProfile(byID: sample.profileID) else { continue }
            if let existing {
                modelContext.delete(existing)
            }
            let model = SpeakerVoiceSample(
                recordingID: key.recordingID,
                rawLabel: key.rawLabel,
                profile: profile,
                embeddingData: sample.embedding,
                embeddingDimension: sample.embeddingDimension,
                sampleDuration: sample.sampleDuration,
                nonOverlapRatio: sample.nonOverlapRatio,
                qualityScore: sample.qualityScore,
                modelVersion: key.modelVersion
            )
            model.createdAt = Date(timeIntervalSince1970: TimeInterval(sample.createdAt))
            modelContext.insert(model)
            outcome.appliedSamples[key] = sample.fingerprint
            buckets.insert(RetentionBucket(
                profileID: sample.profileID,
                modelVersion: key.modelVersion,
                dimension: sample.embeddingDimension
            ))
        }
        return buckets
    }

    private func syncProfile(_ profile: SpeakerProfile) -> SpeakerSyncProfile {
        SpeakerSyncProfile(
            profileID: profile.id,
            displayName: profile.displayName,
            aliases: profile.aliases,
            notes: profile.notes,
            teamOrOrg: profile.teamOrOrg,
            createdAt: SpeakerSyncFingerprint.unixSeconds(profile.createdAt),
            lastSeenAt: profile.lastSeenAt.map(SpeakerSyncFingerprint.unixSeconds)
        )
    }

    /// Nil unless the sample is confirmed, belongs to `modelVersion`, and has a
    /// vector matching its declared dimension: only those are shared.
    private func syncSample(_ sample: SpeakerVoiceSample, modelVersion: String) -> SpeakerSyncSample? {
        guard sample.modelVersion == modelVersion,
              let profileID = sample.profile?.id,
              sample.embeddingDimension > 0,
              sample.embeddingData.count == sample.embeddingDimension * MemoryLayout<Float>.size else {
            return nil
        }
        return SpeakerSyncSample(
            key: SpeakerSyncSampleKey(
                recordingID: sample.recordingID,
                rawLabel: sample.rawLabel,
                modelVersion: sample.modelVersion
            ),
            profileID: profileID,
            embedding: sample.embeddingData,
            embeddingDimension: sample.embeddingDimension,
            sampleDuration: sample.sampleDuration,
            nonOverlapRatio: sample.nonOverlapRatio,
            qualityScore: sample.qualityScore,
            createdAt: SpeakerSyncFingerprint.unixSeconds(sample.createdAt)
        )
    }
}
