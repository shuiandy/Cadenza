import Foundation
import Testing
@testable import Cadenza

private let model = "test-model-v1"

private func profile(
    _ id: UUID = UUID(),
    name: String = "Ada Example",
    lastSeenAt: Int64? = nil
) -> SpeakerSyncProfile {
    SpeakerSyncProfile(
        profileID: id,
        displayName: name,
        aliases: [],
        notes: "",
        teamOrOrg: nil,
        createdAt: 1_789_000_000,
        lastSeenAt: lastSeenAt
    )
}

private func sample(
    profileID: UUID,
    recordingID: UUID = UUID(),
    label: String = "Speaker 1",
    modelVersion: String = model,
    quality: Float = 30
) -> SpeakerSyncSample {
    SpeakerSyncSample(
        key: SpeakerSyncSampleKey(recordingID: recordingID, rawLabel: label, modelVersion: modelVersion),
        profileID: profileID,
        embedding: SpeakerVoiceSample.serializeEmbedding([0.1, 0.2, 0.3, 0.4]),
        embeddingDimension: 4,
        sampleDuration: 42.5,
        nonOverlapRatio: 0.82,
        qualityScore: quality,
        createdAt: 1_789_000_100
    )
}

/// Round-trips a record through the server's JSON shape, the way a pulled
/// page reaches the planner.
private func change(of profile: SpeakerSyncProfile, seq: Int64 = 1) throws -> SpeakerSyncProfileChange {
    var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as! [String: Any]
    object["seq"] = seq
    object["deleted"] = false
    return try JSONDecoder().decode(
        SpeakerSyncProfileChange.self,
        from: JSONSerialization.data(withJSONObject: object)
    )
}

private func tombstone(profileID: UUID, seq: Int64 = 1) throws -> SpeakerSyncProfileChange {
    try JSONDecoder().decode(
        SpeakerSyncProfileChange.self,
        from: Data(#"{"profile_id":"\#(profileID.uuidString.lowercased())","seq":\#(seq),"deleted":true}"#.utf8)
    )
}

private func change(of sample: SpeakerSyncSample, seq: Int64 = 1) throws -> SpeakerSyncSampleChange {
    var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(sample)) as! [String: Any]
    object["seq"] = seq
    object["deleted"] = false
    return try JSONDecoder().decode(
        SpeakerSyncSampleChange.self,
        from: JSONSerialization.data(withJSONObject: object)
    )
}

private func tombstone(key: SpeakerSyncSampleKey, seq: Int64 = 1) throws -> SpeakerSyncSampleChange {
    let json = #"{"client_recording_id":"\#(key.recordingID.uuidString.lowercased())","raw_label":"\#(key.rawLabel)","model_version":"\#(key.modelVersion)","seq":\#(seq),"deleted":true}"#
    return try JSONDecoder().decode(SpeakerSyncSampleChange.self, from: Data(json.utf8))
}

@Suite("Speaker profile sync planner")
struct SpeakerProfileSyncPlannerTests {
    // MARK: Wire

    @Test
    func recordsSurviveTheWireWithIdenticalFingerprints() throws {
        let person = profile(lastSeenAt: 1_789_500_000)
        let voice = sample(profileID: person.profileID)

        #expect(try change(of: person).profile?.fingerprint == person.fingerprint)
        #expect(try change(of: voice).sample?.fingerprint == voice.fingerprint)
    }

    /// A pull captured verbatim from the Go backend after this client's push.
    /// The Go side re-encodes every number, so this proves the fingerprints
    /// survive that round trip and a pulled record is never mistaken for a
    /// local edit.
    @Test
    func goBackendResponseMatchesWhatWasPushed() throws {
        let json = #"{"identity_enabled":true,"identity_generation":0,"voice_enabled":true,"voice_generation":0,"profiles":[{"profile_id":"7c0e0d3e-2f7b-4a57-9d51-3c1f9c3e2a10","seq":1,"deleted":false,"updated_at":1790732199,"display_name":"Ada Example","aliases":["Ada"],"notes":"","team_or_org":null,"created_at":1789000000,"last_seen_at":null}],"samples":[{"client_recording_id":"0f7d5a52-8e0b-4f7e-9d0d-7b2f1a7e4c11","raw_label":"Speaker 2","model_version":"pyannote-wespeaker-voxceleb-v0.17","seq":2,"deleted":false,"profile_id":"7c0e0d3e-2f7b-4a57-9d51-3c1f9c3e2a10","embedding":"zczMPc3MTD6amZk+zczMPg==","embedding_dimension":4,"sample_duration":48.5,"non_overlap_ratio":0.82,"quality_score":39.8,"created_at":1789900000}],"cursor":2,"has_more":false}"#
        let profileID = UUID(uuidString: "7C0E0D3E-2F7B-4A57-9D51-3C1F9C3E2A10")!
        let pushedProfile = SpeakerSyncProfile(
            profileID: profileID, displayName: "Ada Example", aliases: ["Ada"], notes: "",
            teamOrOrg: nil, createdAt: 1_789_000_000, lastSeenAt: nil
        )
        let pushedSample = SpeakerSyncSample(
            key: SpeakerSyncSampleKey(
                recordingID: UUID(uuidString: "0F7D5A52-8E0B-4F7E-9D0D-7B2F1A7E4C11")!,
                rawLabel: "Speaker 2",
                modelVersion: "pyannote-wespeaker-voxceleb-v0.17"
            ),
            profileID: profileID,
            embedding: SpeakerVoiceSample.serializeEmbedding([0.1, 0.2, 0.3, 0.4]),
            embeddingDimension: 4,
            sampleDuration: 48.5,
            nonOverlapRatio: 0.82,
            qualityScore: 39.8,
            createdAt: 1_789_900_000
        )

        let page = try JSONDecoder().decode(SpeakerSyncPullResponse.self, from: Data(json.utf8))

        #expect(page.profiles.first?.profile?.fingerprint == pushedProfile.fingerprint)
        #expect(page.samples.first?.sample?.fingerprint == pushedSample.fingerprint)
    }

    @Test
    func sampleWhoseVectorDisagreesWithItsDimensionIsRejected() throws {
        var voice = sample(profileID: UUID())
        voice.embeddingDimension = 8

        #expect(try change(of: voice).sample == nil)
    }

    // MARK: Apply

    @Test
    func remoteProfileMissingLocallyIsCreated() throws {
        let remote = profile()

        let plan = SpeakerProfileSyncPlanner.planApply(
            profiles: [try change(of: remote)], samples: [],
            local: .init(), ledger: .init(), samplesAllowed: true, modelVersion: model
        )

        #expect(plan.profileWrites == [.init(profile: remote, expectedLocalFingerprint: nil)])
    }

    @Test
    func localEditNotYetPushedWinsOverRemoteEdit() throws {
        let id = UUID()
        let pushed = profile(id, name: "Ada")
        let editedHere = profile(id, name: "Ada Lovelace")
        let editedThere = profile(id, name: "A. Example")
        var ledger = SpeakerProfileSyncLedger()
        ledger.profiles[id] = pushed.fingerprint

        let plan = SpeakerProfileSyncPlanner.planApply(
            profiles: [try change(of: editedThere)], samples: [],
            local: .init(profiles: [id: editedHere]), ledger: ledger,
            samplesAllowed: true, modelVersion: model
        )

        #expect(plan.profileWrites.isEmpty)
        #expect(plan.matchingProfiles.isEmpty)
    }

    @Test
    func remoteEditReplacesAnUnchangedLocalCopy() throws {
        let id = UUID()
        let pushed = profile(id, name: "Ada")
        let editedThere = profile(id, name: "Ada Lovelace")
        var ledger = SpeakerProfileSyncLedger()
        ledger.profiles[id] = pushed.fingerprint

        let plan = SpeakerProfileSyncPlanner.planApply(
            profiles: [try change(of: editedThere)], samples: [],
            local: .init(profiles: [id: pushed]), ledger: ledger,
            samplesAllowed: true, modelVersion: model
        )

        #expect(plan.profileWrites == [.init(profile: editedThere, expectedLocalFingerprint: pushed.fingerprint)])
    }

    @Test
    func identicalRemoteCopyOnlyUpdatesTheLedger() throws {
        let person = profile()

        let plan = SpeakerProfileSyncPlanner.planApply(
            profiles: [try change(of: person)], samples: [],
            local: .init(profiles: [person.profileID: person]), ledger: .init(),
            samplesAllowed: true, modelVersion: model
        )

        #expect(!plan.hasStoreWork)
        #expect(plan.matchingProfiles == [person.profileID: person.fingerprint])
    }

    @Test
    func profileTombstoneWinsEvenOverLocalEdits() throws {
        let person = profile()

        let plan = SpeakerProfileSyncPlanner.planApply(
            profiles: [try tombstone(profileID: person.profileID)], samples: [],
            local: .init(profiles: [person.profileID: person]), ledger: .init(),
            samplesAllowed: true, modelVersion: model
        )

        #expect(plan.profileDeletions == [person.profileID])
    }

    @Test
    func samplesOfAnotherModelOrWithoutConsentAreIgnored() throws {
        let person = profile()
        let foreign = sample(profileID: person.profileID, modelVersion: "onnx-windows-v1")
        let own = sample(profileID: person.profileID)
        let local = SpeakerSyncLocalSnapshot(profiles: [person.profileID: person])

        let mixed = SpeakerProfileSyncPlanner.planApply(
            profiles: [], samples: [try change(of: foreign), try change(of: own)],
            local: local, ledger: .init(), samplesAllowed: true, modelVersion: model
        )
        let withoutConsent = SpeakerProfileSyncPlanner.planApply(
            profiles: [], samples: [try change(of: own)],
            local: local, ledger: .init(), samplesAllowed: false, modelVersion: model
        )

        #expect(mixed.sampleWrites.map(\.sample) == [own])
        #expect(!withoutConsent.hasStoreWork)
    }

    @Test
    func sampleNeedsItsProfileLocallyOrInTheSamePage() throws {
        let known = profile()
        let arriving = profile()
        let unknownID = UUID()
        let forKnown = sample(profileID: known.profileID)
        let forArriving = sample(profileID: arriving.profileID)
        let orphan = sample(profileID: unknownID)

        let plan = SpeakerProfileSyncPlanner.planApply(
            profiles: [try change(of: arriving)],
            samples: [try change(of: forKnown), try change(of: forArriving), try change(of: orphan)],
            local: .init(profiles: [known.profileID: known]), ledger: .init(),
            samplesAllowed: true, modelVersion: model
        )

        #expect(Set(plan.sampleWrites.map(\.sample.key)) == [forKnown.key, forArriving.key])
    }

    @Test
    func sampleTombstoneRemovesOnlyAnUnchangedLocalSample() throws {
        let person = profile()
        let pushed = sample(profileID: person.profileID)
        var reanalyzed = pushed
        reanalyzed.qualityScore = 55
        var ledger = SpeakerProfileSyncLedger()
        ledger.samples[pushed.key] = pushed.fingerprint

        let unchanged = SpeakerProfileSyncPlanner.planApply(
            profiles: [], samples: [try tombstone(key: pushed.key)],
            local: .init(profiles: [person.profileID: person], samples: [pushed.key: pushed]),
            ledger: ledger, samplesAllowed: true, modelVersion: model
        )
        let changed = SpeakerProfileSyncPlanner.planApply(
            profiles: [], samples: [try tombstone(key: pushed.key)],
            local: .init(profiles: [person.profileID: person], samples: [pushed.key: reanalyzed]),
            ledger: ledger, samplesAllowed: true, modelVersion: model
        )

        #expect(unchanged.sampleDeletions == [.init(key: pushed.key, expectedLocalFingerprint: pushed.fingerprint)])
        #expect(changed.sampleDeletions.isEmpty)
    }

    @Test
    func skippedWritesKeepTheirOldLedgerEntry() throws {
        let id = UUID()
        let pushed = profile(id, name: "Ada")
        let remote = profile(id, name: "Ada Lovelace")
        var ledger = SpeakerProfileSyncLedger()
        ledger.profiles[id] = pushed.fingerprint
        let plan = SpeakerProfileSyncPlanner.planApply(
            profiles: [try change(of: remote)], samples: [],
            local: .init(profiles: [id: pushed]), ledger: ledger,
            samplesAllowed: true, modelVersion: model
        )

        SpeakerProfileSyncPlanner.record(plan: plan, outcome: .init(), into: &ledger)

        #expect(ledger.profiles[id] == pushed.fingerprint)
    }

    // MARK: Push

    @Test
    func pushSendsOnlyWhatChangedSinceTheLedger() {
        let unchanged = profile(name: "Unchanged")
        let edited = profile(name: "Edited")
        var ledger = SpeakerProfileSyncLedger()
        ledger.profiles[unchanged.profileID] = unchanged.fingerprint
        ledger.profiles[edited.profileID] = profile(edited.profileID, name: "Before").fingerprint

        let plan = SpeakerProfileSyncPlanner.planPush(
            local: .init(profiles: [unchanged.profileID: unchanged, edited.profileID: edited]),
            ledger: ledger, samplesAllowed: true, modelVersion: model
        )

        #expect(plan.profiles == [edited])
    }

    @Test
    func pushDeletesOnlyThisModelsSamplesAndNeverProfiles() {
        let person = profile()
        let gone = sample(profileID: person.profileID)
        let olderModel = sample(profileID: person.profileID, modelVersion: "test-model-v0")
        let lostProfile = UUID()
        var ledger = SpeakerProfileSyncLedger()
        ledger.profiles[person.profileID] = person.fingerprint
        ledger.profiles[lostProfile] = "stale"
        ledger.samples[gone.key] = gone.fingerprint
        ledger.samples[olderModel.key] = olderModel.fingerprint

        let plan = SpeakerProfileSyncPlanner.planPush(
            local: .init(profiles: [person.profileID: person], samplesConsented: true),
            ledger: ledger, samplesAllowed: true, modelVersion: model
        )

        #expect(plan.deletedSamples == [gone.key])
        #expect(plan.missingLocalProfiles == [lostProfile])
        #expect(plan.profiles.isEmpty)
    }

    @Test
    func samplesStayLocalWhenNotAllowed() {
        let person = profile()
        let voice = sample(profileID: person.profileID)

        let plan = SpeakerProfileSyncPlanner.planPush(
            local: .init(profiles: [person.profileID: person], samples: [voice.key: voice], samplesConsented: true),
            ledger: .init(), samplesAllowed: false, modelVersion: model
        )
        let requests = SpeakerProfileSyncPlanner.requests(for: plan, identityGeneration: 1, voiceGeneration: nil)

        #expect(plan.samples.isEmpty)
        #expect(requests.count == 1)
        #expect(requests[0].samples.isEmpty && requests[0].voiceGeneration == nil)
    }

    @Test
    func profileRequestsPrecedeSampleRequestsWithinServerLimits() {
        let profiles = (0..<250).map { _ in profile() }
        let samples = (0..<201).map { _ in sample(profileID: profiles[0].profileID) }
        let plan = SpeakerProfileSyncPlanner.PushPlan(profiles: profiles, samples: samples)

        let requests = SpeakerProfileSyncPlanner.requests(for: plan, identityGeneration: 3, voiceGeneration: 2)

        #expect(requests.map(\.profiles.count) == [200, 50, 0, 0])
        #expect(requests.map(\.samples.count) == [0, 0, 200, 1])
        #expect(requests.map(\.voiceGeneration) == [nil, nil, 2, 2])
        #expect(requests.allSatisfy { $0.identityGeneration == 3 })
    }

    @Test
    func acceptedPushRecordsEverythingExceptWhatTheServerSkipped() {
        let kept = profile()
        let refused = profile()
        let request = SpeakerSyncPushRequest(
            identityGeneration: 1, voiceGeneration: nil,
            profiles: [kept, refused], deletedProfileIDs: [], samples: [], deletedSamples: []
        )
        let response = SpeakerSyncPushResponse(
            appliedProfiles: 1, appliedSamples: 0,
            skippedProfileIDs: [refused.profileID], skippedSamples: []
        )
        var ledger = SpeakerProfileSyncLedger()

        SpeakerProfileSyncPlanner.record(pushed: request, response: response, into: &ledger)

        #expect(ledger.profiles == [kept.profileID: kept.fingerprint])
    }

    @Test
    func ledgerSurvivesPersistence() throws {
        let person = profile()
        let voice = sample(profileID: person.profileID)
        var ledger = SpeakerProfileSyncLedger(cursor: 12, identityGeneration: 2, voiceGeneration: 1)
        ledger.profiles[person.profileID] = person.fingerprint
        ledger.samples[voice.key] = voice.fingerprint

        let decoded = try JSONDecoder().decode(
            SpeakerProfileSyncLedger.self, from: JSONEncoder().encode(ledger)
        )

        #expect(decoded == ledger)
    }
}
