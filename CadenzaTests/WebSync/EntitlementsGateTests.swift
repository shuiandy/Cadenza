import Foundation
import Testing
@testable import Cadenza

@Suite("Entitlements gate")
struct EntitlementsGateTests {
    private static let official = CadenzaBackendConfig.official().origin.normalized

    private static func bound(
        userID: String = "user-1",
        issuer: String = official,
        originKey: String? = nil,
        apiBaseURL: String = "https://cadenzapp.com/api/v1"
    ) -> Profile.BoundAccount {
        let resolvedKey = originKey ?? ((try? IssuerOrigin(validating: issuer))?.originKey ?? "broken")
        return Profile.BoundAccount(
            userID: userID,
            originKey: resolvedKey,
            issuerOrigin: issuer,
            apiBaseURL: apiBaseURL,
            displayEmail: "a@b.com",
            displayName: "Andy",
            boundAt: Date(timeIntervalSince1970: 1_785_628_800)
        )
    }

    private static func authority(
        profileID: UUID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000001")!,
        account: Profile.BoundAccount = bound()
    ) -> EntitlementsAuthority {
        guard let authority = EntitlementsAuthority(profileID: profileID, bound: account) else {
            fatalError("bound account must yield an authority")
        }
        return authority
    }

    private static func contract(
        audioUpload: Bool = true,
        textQuota: Int64? = 100,
        textUsed: Int64 = 1,
        storageQuota: Int64? = 1_000,
        usedBytes: Int64 = 1,
        reserved: Int64 = 0
    ) -> EntitlementsContract {
        var body: [String: Any] = [
            "contract_version": 1,
            "plan": "free",
            "subscription_status": "active",
            "text_sync_used": textUsed,
            "text_sync_unit": "recordings",
            "text_sync_period": "none",
            "audio_upload": audioUpload,
            "used_bytes": usedBytes,
            "storage_reserved_bytes": reserved,
        ]
        body["text_sync_quota"] = textQuota as Any? ?? NSNull()
        body["storage_quota_bytes"] = storageQuota as Any? ?? NSNull()
        let data = try! JSONSerialization.data(withJSONObject: body)
        guard case .entitled(let contract) = EntitlementsResolution.classify(
            status: 200, body: data, service: .official
        ) else {
            fatalError("fixture must decode")
        }
        return contract
    }

    // MARK: - Self-host proof

    @Test func officialIssuerNeverReadsAMissingEndpointAsAGrant() {
        let authority = Self.authority()
        #expect(authority.service == .official)
        let resolution = EntitlementsResolution.classify(
            status: 404, body: Data(), service: authority.service
        )
        #expect(resolution == .unavailable(status: 404))
    }

    @Test func frozenSelfHostBindingReadsAMissingEndpointAsOpen() {
        let authority = Self.authority(
            account: Self.bound(issuer: "https://sync.example.test:8443", apiBaseURL: "https://sync.example.test:8443/api/v1")
        )
        #expect(authority.service == .selfHost)
        let resolution = EntitlementsResolution.classify(
            status: 404, body: Data(), service: authority.service
        )
        #expect(resolution == .selfHostOpen)
    }

    @Test func aBindingThatNoLongerValidatesProvesNoSelfHostIdentity() {
        // A corrupt frozen binding is not evidence of anything; it must not
        // become the shape that turns a missing endpoint into a grant.
        for account in [
            Self.bound(issuer: "not a url", originKey: "whatever"),
            Self.bound(issuer: "https://sync.example.test:8443", originKey: "mismatched-key"),
        ] {
            let authority = Self.authority(account: account)
            #expect(authority.service == .official)
        }
    }

    @Test func aConfiguredBaseURLAloneIsNotSelfHostProof() {
        // The issuer is the official one; only the base URL differs. Identity
        // comes from the frozen issuer, so this is still the official service.
        let authority = Self.authority(
            account: Self.bound(apiBaseURL: "https://cadenzapp.com/api/v2")
        )
        #expect(authority.service == .official)
    }

    // MARK: - Authority scoping

    @Test @MainActor func knowledgeNeverCrossesAccounts() {
        let gate = EntitlementsGate()
        let first = Self.authority(account: Self.bound(userID: "user-1"))
        gate.bind(to: first)
        gate.apply(.entitled(Self.contract(audioUpload: false)), for: first)
        #expect(gate.allowsAudioTransfer(for: "user-1") == false)

        let second = Self.authority(account: Self.bound(userID: "user-2"))
        gate.bind(to: second)
        #expect(gate.knowledge == nil)
        // Nothing to inherit, and nothing proven: audio needs evidence.
        #expect(gate.allowsAudioTransfer(for: "user-2") == false)
        // Structured sync continues; only a stated refusal stops it.
        #expect(gate.allowsStructuredSync(for: "user-2") == true)
    }

    @Test @MainActor func byteDistinctIdentitiesAreDifferentAccounts() {
        let gate = EntitlementsGate()
        // Canonically equivalent, byte-distinct spellings of one name.
        let composed = Self.authority(account: Self.bound(userID: "cafe\u{0301}"))
        let precomposed = Self.authority(account: Self.bound(userID: "caf\u{00E9}"))
        gate.bind(to: composed)
        gate.apply(.entitled(Self.contract(audioUpload: false)), for: composed)
        #expect(gate.allowsAudioTransfer(for: "cafe\u{0301}") == false)

        gate.bind(to: precomposed)
        #expect(gate.knowledge == nil)
        #expect(gate.allowsAudioTransfer(for: "caf\u{00E9}") == false)
    }

    @Test @MainActor func aResolutionForAnAccountNoLongerBoundIsDiscarded() {
        let gate = EntitlementsGate()
        let stale = Self.authority(account: Self.bound(userID: "user-1"))
        let current = Self.authority(account: Self.bound(userID: "user-2"))
        gate.bind(to: current)
        gate.apply(.entitled(Self.contract(audioUpload: false)), for: stale)
        #expect(gate.knowledge == nil)
        #expect(gate.allowsAudioTransfer(for: "user-2") == false)
    }

    @Test @MainActor func rebindingToTheSameAuthorityKeepsWhatItLearned() {
        let gate = EntitlementsGate()
        let authority = Self.authority()
        gate.bind(to: authority)
        gate.apply(.entitled(Self.contract(audioUpload: false)), for: authority)
        gate.bind(to: Self.authority())
        #expect(gate.knowledge == .contract(Self.contract(audioUpload: false)))
    }

    @Test @MainActor func signingOutDropsEverythingTheAccountKnew() {
        let gate = EntitlementsGate()
        let authority = Self.authority()
        gate.bind(to: authority)
        gate.apply(.entitled(Self.contract(audioUpload: false)), for: authority)
        gate.note(.textQuotaExceeded, for: authority)

        gate.bind(to: nil)
        #expect(gate.knowledge == nil)
        #expect(gate.pause == .none)
    }

    // MARK: - Authority replacement

    @Test @MainActor func onlyAuthoritativeShapesReplaceWhatIsKnown() {
        let gate = EntitlementsGate()
        let authority = Self.authority()
        gate.bind(to: authority)
        let known = Self.contract(audioUpload: false)
        gate.apply(.entitled(known), for: authority)

        for barren: EntitlementsResolution in [
            .unsupported(reason: "newer"), .unavailable(status: 500), .unavailable(status: 404),
        ] {
            gate.apply(barren, for: authority)
            #expect(gate.knowledge == .contract(known))
            #expect(gate.allowsAudioTransfer(for: "user-1") == false)
        }
    }

    @Test @MainActor func withoutAPreviousSnapshotNothingIsKnownAndNothingIsGated() {
        let gate = EntitlementsGate()
        let authority = Self.authority()
        gate.bind(to: authority)
        gate.apply(.unsupported(reason: "newer"), for: authority)
        #expect(gate.knowledge == nil)
        // No authority is no grant: audio needs positive evidence, while
        // structured sync continues until a server refusal stops it.
        #expect(gate.allowsAudioTransfer(for: "user-1") == false)
        #expect(gate.allowsStructuredSync(for: "user-1") == true)
    }

    @Test @MainActor func selfHostOpenAllowsEverything() {
        let gate = EntitlementsGate()
        let authority = Self.authority(
            account: Self.bound(issuer: "https://sync.example.test:8443")
        )
        gate.bind(to: authority)
        gate.note(.textQuotaExceeded, for: authority)
        gate.note(.audioUploadNotEntitled, for: authority)
        gate.apply(.selfHostOpen, for: authority)
        #expect(gate.knowledge == .selfHostOpen)
        #expect(gate.allowsStructuredSync(for: "user-1") == true)
        #expect(gate.allowsAudioTransfer(for: "user-1") == true)
    }

    // MARK: - Pauses

    @Test @MainActor func aTextQuotaRejectionStopsStructuredSyncOnly() {
        let gate = EntitlementsGate()
        let authority = Self.authority()
        gate.bind(to: authority)
        gate.apply(.entitled(Self.contract(audioUpload: true)), for: authority)
        gate.note(.textQuotaExceeded, for: authority)
        #expect(gate.allowsStructuredSync(for: "user-1") == false)
        // A text refusal leaves an entitled audio transfer alone.
        #expect(gate.allowsAudioTransfer(for: "user-1") == true)
        #expect(gate.pause.structuredCode == "text_quota_exceeded")
    }

    @Test @MainActor func anAudioRejectionStopsAudioOnly() {
        for (rejection, code) in [
            (EntitlementRejection.audioUploadNotEntitled, "audio_upload_not_entitled"),
            (EntitlementRejection.storageQuotaExceeded, "storage_quota_exceeded"),
        ] {
            let gate = EntitlementsGate()
            let authority = Self.authority()
            gate.bind(to: authority)
            gate.apply(.entitled(Self.contract(audioUpload: true)), for: authority)
            gate.note(rejection, for: authority)
            #expect(gate.allowsAudioTransfer(for: "user-1") == false)
            #expect(gate.allowsStructuredSync(for: "user-1") == true)
            #expect(gate.pause.audioCode == code)
        }
    }

    @Test @MainActor func anUnknownRejectionCodeChangesNothing() {
        let gate = EntitlementsGate()
        let authority = Self.authority()
        gate.bind(to: authority)
        gate.apply(.entitled(Self.contract(audioUpload: true)), for: authority)
        gate.note(.unknown(code: "some_future_code"), for: authority)
        #expect(gate.pause == .none)
        #expect(gate.allowsStructuredSync(for: "user-1") == true)
        #expect(gate.allowsAudioTransfer(for: "user-1") == true)
    }

    @Test @MainActor func aRejectionForAnotherAccountIsNotRecorded() {
        let gate = EntitlementsGate()
        let current = Self.authority(account: Self.bound(userID: "user-1"))
        let other = Self.authority(account: Self.bound(userID: "user-2"))
        gate.bind(to: current)
        gate.note(.textQuotaExceeded, for: other)
        #expect(gate.pause == .none)
    }

    // MARK: - Reopening

    @Test @MainActor func provenCapacityClearsTheMatchingPause() {
        let gate = EntitlementsGate()
        let authority = Self.authority()
        gate.bind(to: authority)
        gate.note(.textQuotaExceeded, for: authority)
        gate.note(.storageQuotaExceeded, for: authority)

        gate.apply(
            .entitled(Self.contract(audioUpload: true, textQuota: 100, textUsed: 2, storageQuota: 1_000, usedBytes: 3)),
            for: authority
        )
        #expect(gate.pause == .none)
        #expect(gate.allowsStructuredSync(for: "user-1") == true)
        #expect(gate.allowsAudioTransfer(for: "user-1") == true)
    }

    @Test @MainActor func aSnapshotStillAtCapacityKeepsThePause() {
        let gate = EntitlementsGate()
        let authority = Self.authority()
        gate.bind(to: authority)
        gate.note(.textQuotaExceeded, for: authority)
        gate.note(.storageQuotaExceeded, for: authority)

        gate.apply(
            .entitled(Self.contract(
                audioUpload: true, textQuota: 100, textUsed: 100,
                storageQuota: 1_000, usedBytes: 900, reserved: 100
            )),
            for: authority
        )
        #expect(gate.allowsStructuredSync(for: "user-1") == false)
        #expect(gate.allowsAudioTransfer(for: "user-1") == false)
    }

    @Test @MainActor func audioNeedsPositiveEvidenceRatherThanTheAbsenceOfDenial() {
        let gate = EntitlementsGate()
        // No account bound at all: an unbound gate grants nothing.
        #expect(gate.allowsAudioTransfer(for: "user-1") == false)

        gate.bind(to: Self.authority())
        // Bound but nothing learned yet.
        #expect(gate.allowsAudioTransfer(for: "user-1") == false)
        // An unreadable answer teaches nothing, so it is still no.
        gate.apply(.unavailable(status: 404), for: Self.authority())
        #expect(gate.allowsAudioTransfer(for: "user-1") == false)
        // Positive evidence opens it.
        gate.apply(.entitled(Self.contract(audioUpload: true)), for: Self.authority())
        #expect(gate.allowsAudioTransfer(for: "user-1") == true)
    }

    @Test @MainActor func aReopenReportsExactlyWhichTransfersItLifted() {
        let gate = EntitlementsGate()
        let authority = Self.authority()
        gate.bind(to: authority)
        gate.note(.textQuotaExceeded, for: authority)
        gate.note(.storageQuotaExceeded, for: authority)

        // Text has room again; audio is still at its ceiling.
        var reopened = gate.apply(
            .entitled(Self.contract(
                audioUpload: true, textQuota: 100, textUsed: 1, storageQuota: 10, usedBytes: 10
            )),
            for: authority
        )
        #expect(reopened.reopened.structured == true)
        #expect(reopened.reopened.audio == false)
        #expect(reopened.learned == true)

        reopened = gate.apply(
            .entitled(Self.contract(audioUpload: true, storageQuota: 1_000, usedBytes: 1)),
            for: authority
        )
        #expect(reopened.reopened.structured == false)
        #expect(reopened.reopened.audio == true)

        // Nothing left to lift.
        #expect(gate.apply(.selfHostOpen, for: authority).reopened.isEmpty)
    }

    @Test @MainActor func aStorageTotalThatCannotBeRepresentedIsNotCapacity() {
        let gate = EntitlementsGate()
        let authority = Self.authority()
        gate.bind(to: authority)
        gate.note(.storageQuotaExceeded, for: authority)
        // A pair whose sum overflows is never read as room under the quota.
        let overflowing = EntitlementsContract(
            contractVersion: 1, plan: "free", subscriptionStatus: .active,
            textSyncQuota: nil, textSyncUsed: 0, textSyncUnit: .recordings,
            textSyncPeriod: .none, textSyncPeriodStart: nil, textSyncPeriodEnd: nil,
            audioUpload: true, storageQuotaBytes: Int64.max,
            usedBytes: Int64.max, storageReservedBytes: Int64.max, graceUntil: nil
        )
        #expect(gate.apply(.entitled(overflowing), for: authority).reopened.audio == false)
        #expect(gate.allowsAudioTransfer(for: "user-1") == false)
    }

    @Test @MainActor func learningIsReportedOnlyWhenTheSnapshotActuallyChanges() {
        let gate = EntitlementsGate()
        let authority = Self.authority()
        gate.bind(to: authority)

        // Establishing knowledge counts, even with no pause to lift.
        var applied = gate.apply(.entitled(Self.contract(audioUpload: true)), for: authority)
        #expect(applied.learned == true)
        #expect(applied.reopened.isEmpty)

        // The same snapshot again teaches nothing.
        applied = gate.apply(.entitled(Self.contract(audioUpload: true)), for: authority)
        #expect(applied.learned == false)

        // A changed snapshot does, in either direction.
        #expect(gate.apply(.entitled(Self.contract(audioUpload: false)), for: authority).learned)
        #expect(gate.apply(.entitled(Self.contract(audioUpload: true)), for: authority).learned)
        #expect(gate.apply(.selfHostOpen, for: authority).learned)

        // A resolution for another account is not learning.
        let other = Self.authority(account: Self.bound(userID: "user-2"))
        #expect(gate.apply(.entitled(Self.contract(audioUpload: false)), for: other).learned == false)
    }

    @Test @MainActor func anUnchangedSnapshotCanStillLiftARefusal() {
        let gate = EntitlementsGate()
        let authority = Self.authority()
        let contract = Self.contract(audioUpload: true, storageQuota: 1_000, usedBytes: 1)
        gate.bind(to: authority)
        gate.apply(.entitled(contract), for: authority)
        gate.note(.storageQuotaExceeded, for: authority)

        let applied = gate.apply(.entitled(contract), for: authority)
        #expect(applied.learned == false)
        #expect(applied.reopened.audio == true)
        #expect(gate.allowsAudioTransfer(for: "user-1") == true)
    }

    @Test @MainActor func aRefreshWithoutAuthorityNeverClearsAPause() {
        let gate = EntitlementsGate()
        let authority = Self.authority()
        gate.bind(to: authority)
        gate.note(.textQuotaExceeded, for: authority)
        gate.note(.audioUploadNotEntitled, for: authority)

        for barren: EntitlementsResolution in [
            .unsupported(reason: "newer"), .unavailable(status: 503), .unavailable(status: 404),
        ] {
            let applied = gate.apply(barren, for: authority)
            #expect(applied.reopened.isEmpty)
            #expect(applied.learned == false)
            #expect(gate.allowsStructuredSync(for: "user-1") == false)
            #expect(gate.allowsAudioTransfer(for: "user-1") == false)
        }
    }

    @Test @MainActor func audioStillNotEntitledKeepsTheAudioPauseEvenWithRoom() {
        let gate = EntitlementsGate()
        let authority = Self.authority()
        gate.bind(to: authority)
        gate.note(.audioUploadNotEntitled, for: authority)
        gate.apply(.entitled(Self.contract(audioUpload: false, storageQuota: nil)), for: authority)
        #expect(gate.allowsAudioTransfer(for: "user-1") == false)
    }

    @Test @MainActor func unlimitedQuotasCountAsCapacity() {
        let gate = EntitlementsGate()
        let authority = Self.authority()
        gate.bind(to: authority)
        gate.note(.textQuotaExceeded, for: authority)
        gate.note(.storageQuotaExceeded, for: authority)
        gate.apply(
            .entitled(Self.contract(audioUpload: true, textQuota: nil, storageQuota: nil)),
            for: authority
        )
        #expect(gate.pause == .none)
    }
}
