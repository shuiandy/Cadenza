import Foundation
import Testing
@testable import Cadenza

@Suite("Entitlements presentation")
struct EntitlementsPresentationTests {
    private static let officialOrigin = CadenzaBackendConfig.official().origin.normalized
    private static let accountURL = URL(string: CadenzaBackendConfig.officialAccountURLString)!
    private static let webAppURL = URL(string: CadenzaBackendConfig.officialWebAppURLString)!

    private static func bound(
        userID: String = "user-1",
        issuer: String = officialOrigin,
        originKey: String? = nil
    ) -> Profile.BoundAccount {
        let resolved = originKey ?? ((try? IssuerOrigin(validating: issuer))?.originKey ?? "broken")
        return Profile.BoundAccount(
            userID: userID, originKey: resolved, issuerOrigin: issuer,
            apiBaseURL: "\(issuer)/api/v1", displayEmail: "a@b.com", displayName: "Andy",
            boundAt: Date(timeIntervalSince1970: 1_785_628_800)
        )
    }

    private static func authority(_ account: Profile.BoundAccount = bound()) -> EntitlementsAuthority {
        guard let authority = EntitlementsAuthority(
            profileID: UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000001")!, bound: account
        ) else {
            fatalError("bound account must yield an authority")
        }
        return authority
    }

    private static func contract(
        plan: String = "free",
        status: String = "active",
        graceUntil: Double? = nil,
        textQuota: Int64? = 100,
        textUsed: Int64 = 13,
        textUnit: String = "recordings",
        period: String = "none",
        periodStart: Double? = nil,
        periodEnd: Double? = nil,
        audioUpload: Bool = true,
        storageQuota: Int64? = 5_000,
        usedBytes: Int64 = 1_000,
        reserved: Int64 = 0
    ) -> EntitlementsContract {
        var body: [String: Any] = [
            "contract_version": 1, "plan": plan, "subscription_status": status,
            "text_sync_used": textUsed, "text_sync_unit": textUnit, "text_sync_period": period,
            "audio_upload": audioUpload, "used_bytes": usedBytes,
            "storage_reserved_bytes": reserved,
        ]
        body["text_sync_quota"] = textQuota as Any? ?? NSNull()
        body["storage_quota_bytes"] = storageQuota as Any? ?? NSNull()
        if let graceUntil { body["grace_until"] = graceUntil }
        if let periodStart { body["text_sync_period_start"] = periodStart }
        if let periodEnd { body["text_sync_period_end"] = periodEnd }
        let data = try! JSONSerialization.data(withJSONObject: body)
        guard case .entitled(let contract) = EntitlementsResolution.classify(
            status: 200, body: data, service: .official
        ) else {
            fatalError("fixture must decode")
        }
        return contract
    }

    private static func make(
        authority: EntitlementsAuthority? = authority(),
        knowledge: EntitlementsKnowledge? = nil,
        pause: EntitlementsPause = .none,
        preference: Bool = false,
        audioAllowed: Bool = false
    ) -> EntitlementsPresentation {
        EntitlementsPresentation.make(
            authority: authority, knowledge: knowledge, pause: pause,
            audioPreferenceEnabled: preference, audioUploadAllowed: audioAllowed,
            officialAccountURL: accountURL, officialWebAppURL: webAppURL,
            officialIssuerOrigin: officialOrigin
        )
    }

    // MARK: - Authoritative limits

    @Test func anOfficialContractIsShownFieldByField() {
        let presentation = Self.make(
            knowledge: .contract(Self.contract(
                plan: "pro", textQuota: 200, textUsed: 13,
                storageQuota: 5_000, usedBytes: 1_000, reserved: 200
            )),
            audioAllowed: true
        )
        guard case .limits(let limits) = presentation.state else {
            Issue.record("expected limits")
            return
        }
        #expect(limits.plan == "pro")
        #expect(limits.lifecycle == .defined(.active))
        #expect(limits.textUnit == .defined(.recordings))
        #expect(limits.period == .defined(.allTime))
        #expect(limits.text == .init(used: 13, limit: 200))
        #expect(limits.audioUploadEntitled == true)
        // Storage counts committed plus reserved, as admission charges it.
        #expect(limits.storage == .init(used: 1_200, limit: 5_000))
        #expect(limits.storageReserved == 200)
    }

    @Test func unlimitedAndOverLimitMetersReadCorrectly() {
        let unlimited = Self.make(knowledge: .contract(Self.contract(textQuota: nil, storageQuota: nil)))
        guard case .limits(let open) = unlimited.state else {
            Issue.record("expected limits")
            return
        }
        #expect(open.text.isUnlimited)
        #expect(open.text.isOverLimit == false)
        #expect(open.storage.isUnlimited)

        let over = Self.make(knowledge: .contract(Self.contract(textQuota: 10, textUsed: 11)))
        guard case .limits(let full) = over.state else {
            Issue.record("expected limits")
            return
        }
        #expect(full.text.isOverLimit)
    }

    @Test func graceCarriesTheServersDeadlineAndMonthlyCarriesItsReset() {
        let deadline = Date(timeIntervalSince1970: 1_788_000_000)
        let presentation = Self.make(knowledge: .contract(Self.contract(
            status: "grace", graceUntil: deadline.timeIntervalSince1970,
            period: "monthly", periodStart: 1_785_542_400, periodEnd: 1_788_220_800
        )))
        guard case .limits(let limits) = presentation.state else {
            Issue.record("expected limits")
            return
        }
        #expect(limits.lifecycle == .defined(.grace(until: deadline)))
        #expect(limits.period == .defined(.monthly(resetsAt: Date(timeIntervalSince1970: 1_788_220_800))))
    }

    @Test func unknownEnumValuesStayOpaqueAndGetNoMeaning() {
        let presentation = Self.make(knowledge: .contract(Self.contract(
            status: "suspended", textUnit: "minutes", period: "weekly"
        )))
        guard case .limits(let limits) = presentation.state else {
            Issue.record("expected limits")
            return
        }
        #expect(limits.lifecycle == .unrecognized(raw: "suspended"))
        #expect(limits.textUnit == .unrecognized(raw: "minutes"))
        #expect(limits.period == .unrecognized(raw: "weekly"))
    }

    @Test func aStorageTotalThatCannotBeRepresentedIsNotStated() {
        let overflowing = EntitlementsContract(
            contractVersion: 1, plan: "free", subscriptionStatus: .active,
            textSyncQuota: nil, textSyncUsed: 0, textSyncUnit: .recordings,
            textSyncPeriod: .none, textSyncPeriodStart: nil, textSyncPeriodEnd: nil,
            audioUpload: true, storageQuotaBytes: Int64.max,
            usedBytes: Int64.max, storageReservedBytes: Int64.max, graceUntil: nil
        )
        guard case .limits(let limits) = Self.make(knowledge: .contract(overflowing)).state else {
            Issue.record("expected limits")
            return
        }
        #expect(limits.storage.used == nil)
        // An unstatable total is never reported as within or over a limit.
        #expect(limits.storage.isOverLimit == false)
    }

    // MARK: - Non-authoritative states

    @Test func aSelfHostedBackendWithoutTheEndpointReadsAsManagedThere() {
        let presentation = Self.make(
            authority: Self.authority(Self.bound(issuer: "https://sync.example.test:8443")),
            knowledge: .selfHostOpen
        )
        #expect(presentation.state == .selfHostManaged)
        // Not an outage, and no official plan is invented for it.
        #expect(presentation.managementURL == nil)
    }

    @Test func noAuthorityAndNoSnapshotBothReadAsUnavailable() {
        #expect(Self.make(authority: nil, knowledge: nil).state == .unavailable)
        // A bound account that has learned nothing states nothing either.
        #expect(Self.make(knowledge: nil).state == .unavailable)
        // Knowledge without a bound account is never borrowed.
        #expect(Self.make(authority: nil, knowledge: .contract(Self.contract())).state == .unavailable)
        #expect(Self.make(authority: nil, knowledge: .selfHostOpen).state == .unavailable)
    }

    @Test func anAccountSwitchShowsTheNewAccountOnly() {
        let first = Self.make(knowledge: .contract(Self.contract(plan: "pro")), audioAllowed: true)
        guard case .limits(let shown) = first.state, shown.plan == "pro" else {
            Issue.record("expected the first account's plan")
            return
        }
        // The gate clears on a switch, so the next build has nothing to show.
        let second = Self.make(
            authority: Self.authority(Self.bound(userID: "user-2")), knowledge: nil
        )
        #expect(second.state == .unavailable)
    }

    // MARK: - Warnings

    @Test func stablePauseCodesBecomeWarningsAndNothingElseDoes() {
        #expect(Self.make(pause: .init(structuredCode: "text_quota_exceeded")).warnings
                == [.textQuotaExceeded])
        #expect(Self.make(pause: .init(audioCode: "audio_upload_not_entitled")).warnings
                == [.audioUploadNotEntitled])
        #expect(Self.make(pause: .init(audioCode: "storage_quota_exceeded")).warnings
                == [.storageQuotaExceeded])
        #expect(Self.make(pause: .init(
            structuredCode: "text_quota_exceeded", audioCode: "storage_quota_exceeded"
        )).warnings == [.textQuotaExceeded, .storageQuotaExceeded])
        #expect(Self.make(pause: .none).warnings.isEmpty)
        // A code this build does not define raises nothing rather than guessing.
        #expect(Self.make(pause: .init(structuredCode: "some_future_code")).warnings.isEmpty)
    }

    // MARK: - Management destination

    @Test func managementIsOfferedOnlyForAFrozenOfficialBinding() {
        #expect(Self.make().managementURL == Self.accountURL)
        // A self-hosted binding never crosses over to the official surface.
        #expect(Self.make(
            authority: Self.authority(Self.bound(issuer: "https://sync.example.test:8443"))
        ).managementURL == nil)
        // A binding that no longer validates proves nothing.
        #expect(Self.make(
            authority: Self.authority(Self.bound(originKey: "mismatched"))
        ).managementURL == nil)
        #expect(Self.make(authority: nil).managementURL == nil)
    }

    @Test func theManagementDestinationIsTheKnownOfficialRoute() {
        let url = try! #require(Self.make().managementURL)
        #expect(url.scheme == "https")
        #expect(url.host() == "cadenzapp.com")
        #expect(url.path() == "/app/settings")
    }

    // MARK: - Audio preference

    @Test func aFalseEntitlementSuppressesUploadWithoutClearingThePreference() {
        let presentation = Self.make(
            knowledge: .contract(Self.contract(audioUpload: false)),
            preference: true, audioAllowed: false
        )
        // The preference is what the user chose; only the effect is withheld.
        #expect(presentation.audioPreferenceEnabled == true)
        #expect(presentation.audioUploadEffective == false)
        guard case .limits(let limits) = presentation.state else {
            Issue.record("expected limits")
            return
        }
        #expect(limits.audioUploadEntitled == false)
    }

    // MARK: - The audio switch

    @Test func theAudioSwitchIsUnavailableWithoutPositiveEvidence() {
        // No authority at all, and a bound account that has learned nothing.
        #expect(Self.make(authority: nil).audioControl == .deniedNoAuthority)
        #expect(Self.make(knowledge: nil).audioControl == .deniedNoAuthority)
        // A plan that does not include audio.
        #expect(Self.make(knowledge: .contract(Self.contract(audioUpload: false))).audioControl
                == .deniedByPlan)
        // A stated server refusal outranks whatever the plan last said.
        #expect(Self.make(
            knowledge: .contract(Self.contract(audioUpload: true)),
            pause: .init(audioCode: "audio_upload_not_entitled")
        ).audioControl == .deniedByPause(.audioUploadNotEntitled))
        #expect(Self.make(
            knowledge: .contract(Self.contract(audioUpload: true)),
            pause: .init(audioCode: "storage_quota_exceeded")
        ).audioControl == .deniedByPause(.storageQuotaExceeded))
    }

    @Test func aDeniedSwitchNeverReportsTheStoredPreferenceAsChanged() {
        for control in [
            Self.make(authority: nil, preference: true),
            Self.make(knowledge: nil, preference: true),
            Self.make(knowledge: .contract(Self.contract(audioUpload: false)), preference: true),
            Self.make(
                knowledge: .contract(Self.contract(audioUpload: true)),
                pause: .init(audioCode: "storage_quota_exceeded"), preference: true
            ),
        ] {
            #expect(control.audioControl.isAvailable == false)
            // The user's own choice is reported unchanged in every denial.
            #expect(control.audioPreferenceEnabled == true)
            #expect(control.audioUploadEffective == false)
        }
    }

    @Test func aLaterGrantRestoresTheSwitchForBothDispositions() {
        #expect(Self.make(
            knowledge: .contract(Self.contract(audioUpload: true)), preference: true, audioAllowed: true
        ).audioControl == .available)
        // A caller-proven self-hosted backend enables it too.
        #expect(Self.make(
            authority: Self.authority(Self.bound(issuer: "https://sync.example.test:8443")),
            knowledge: .selfHostOpen, preference: true, audioAllowed: true
        ).audioControl == .available)
        // A user who never switched it on is not switched on by a grant.
        #expect(Self.make(
            knowledge: .contract(Self.contract(audioUpload: true)), preference: false, audioAllowed: true
        ).audioPreferenceEnabled == false)
    }

    @Test func theKeptPreferenceIsExplainedInEveryHeldState() {
        // The note the view shows is driven by this pair, and it must appear
        // where no plan conclusion exists as well as where one denies audio.
        for held in [
            Self.make(authority: nil, preference: true),
            Self.make(knowledge: nil, preference: true),
            Self.make(knowledge: .contract(Self.contract(audioUpload: false)), preference: true),
            Self.make(
                knowledge: .contract(Self.contract(audioUpload: true)),
                pause: .init(audioCode: "storage_quota_exceeded"), preference: true
            ),
        ] {
            #expect(held.audioPreferenceEnabled && !held.audioUploadEffective)
        }
        // Nothing to explain once uploads actually run.
        let running = Self.make(
            knowledge: .contract(Self.contract(audioUpload: true)), preference: true, audioAllowed: true
        )
        #expect(running.audioUploadEffective)
    }

    // MARK: - Refresh and the official web surface

    @Test func refreshIsOfferedOnlyWhenThereIsSomethingToFetch() {
        // Bound but signed out: the gate holds no authority, so a refresh would
        // be guaranteed inert.
        #expect(Self.make(authority: nil).canRefresh == false)
        // Official authority that has learned nothing can still be asked again.
        #expect(Self.make(knowledge: nil).canRefresh == true)
        #expect(Self.make(knowledge: .contract(Self.contract())).canRefresh == true)
        #expect(Self.make(
            authority: Self.authority(Self.bound(issuer: "https://sync.example.test:8443")),
            knowledge: .selfHostOpen
        ).canRefresh == true)
    }

    @Test func theOfficialWebAppIsOfferedOnTheSameProofAsManagement() {
        let official = Self.make()
        #expect(official.webAppURL == Self.webAppURL)
        #expect(official.managementURL == Self.accountURL)

        // A self-hosted account gets neither, and no address is derived for it.
        let selfHosted = Self.make(
            authority: Self.authority(Self.bound(issuer: "https://sync.example.test:8443")),
            knowledge: .selfHostOpen
        )
        #expect(selfHosted.webAppURL == nil)
        #expect(selfHosted.managementURL == nil)

        // A binding that no longer validates proves nothing either way.
        let corrupt = Self.make(authority: Self.authority(Self.bound(originKey: "mismatched")))
        #expect(corrupt.webAppURL == nil)
        #expect(corrupt.managementURL == nil)
        #expect(Self.make(authority: nil).webAppURL == nil)
    }

    @Test func aLaterGrantResumesUploadFromTheSamePreference() {
        let granted = Self.make(
            knowledge: .contract(Self.contract(audioUpload: true)),
            preference: true, audioAllowed: true
        )
        #expect(granted.audioUploadEffective == true)
        // A user who never enabled it is not switched on by a grant.
        let optedOut = Self.make(
            knowledge: .contract(Self.contract(audioUpload: true)),
            preference: false, audioAllowed: true
        )
        #expect(optedOut.audioUploadEffective == false)
    }
}
