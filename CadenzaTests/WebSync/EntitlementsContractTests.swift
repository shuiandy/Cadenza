import Foundation
import Testing

@testable import Cadenza

struct EntitlementsContractTests {
    private func data(_ json: String) -> Data { Data(json.utf8) }

    private let canonical = """
    {
      "contract_version": 1,
      "plan": "free",
      "subscription_status": "grace",
      "text_sync_quota": 3,
      "text_sync_used": 2,
      "text_sync_unit": "recordings",
      "text_sync_period": "monthly",
      "text_sync_period_start": 1785542400,
      "text_sync_period_end": 1788220800,
      "audio_upload": false,
      "storage_quota_bytes": 0,
      "used_bytes": 42,
      "storage_reserved_bytes": 7,
      "grace_until": 1788000000
    }
    """

    @Test func canonicalResponseDecodesEveryField() throws {
        let resolution = EntitlementsResolution.classify(
            status: 200, body: data(canonical), service: .official
        )
        guard case .entitled(let contract) = resolution else {
            Issue.record("expected entitled, got \(resolution)")
            return
        }
        #expect(contract.contractVersion == 1)
        #expect(contract.plan == "free")
        #expect(contract.subscriptionStatus == .grace)
        #expect(contract.textSyncQuota == 3)
        #expect(contract.textSyncUsed == 2)
        #expect(contract.textSyncUnit == .recordings)
        #expect(contract.textSyncPeriod == .monthly)
        #expect(contract.textSyncPeriodStart == Date(timeIntervalSince1970: 1_785_542_400))
        #expect(contract.textSyncPeriodEnd == Date(timeIntervalSince1970: 1_788_220_800))
        #expect(!contract.audioUpload)
        #expect(contract.storageQuotaBytes == 0)
        #expect(contract.usedBytes == 42)
        #expect(contract.storageReservedBytes == 7)
        #expect(contract.graceUntil == Date(timeIntervalSince1970: 1_788_000_000))
    }

    /// The pre-versioning flat spec shape decodes with neutral defaults
    /// only for fields that never existed in it; null quotas mean
    /// unlimited.
    @Test func flatSpecShapeAndNullQuotasDecode() throws {
        let flat = """
        {"plan":"pro","text_sync_quota":null,"audio_upload":true,
         "storage_quota_bytes":null,"used_bytes":7}
        """
        let resolution = EntitlementsResolution.classify(
            status: 200, body: data(flat), service: .official
        )
        guard case .entitled(let contract) = resolution else {
            Issue.record("expected entitled, got \(resolution)")
            return
        }
        #expect(contract.contractVersion == 1)
        #expect(contract.subscriptionStatus == .active)
        #expect(contract.textSyncQuota == nil)
        #expect(contract.textSyncUsed == 0)
        #expect(contract.textSyncUnit == .recordings)
        #expect(contract.textSyncPeriod == .none)
        #expect(contract.storageQuotaBytes == nil)
        #expect(contract.storageReservedBytes == 0)
        #expect(contract.graceUntil == nil)
    }

    /// A flat response missing one of its own original fields is
    /// malformed, not defaultable.
    @Test func flatShapeStillRequiresItsOwnFields() {
        let missingAudio = """
        {"plan":"pro","text_sync_quota":null,"storage_quota_bytes":null,"used_bytes":0}
        """
        guard case .unsupported = EntitlementsResolution.classify(
            status: 200, body: data(missingAudio), service: .official
        ) else {
            Issue.record("flat shape without audio_upload must be unsupported")
            return
        }
    }

    /// Unknown fields and unknown enum values are forward-compatible:
    /// they never fail the decode and raw values stay visible.
    @Test func unknownFieldsAndValuesStayTolerated() throws {
        let future = """
        {"contract_version":1,"plan":"free","subscription_status":"paused",
         "text_sync_quota":null,"text_sync_used":0,"text_sync_unit":"words",
         "text_sync_period":"weekly","audio_upload":true,
         "storage_quota_bytes":null,"used_bytes":0,"storage_reserved_bytes":0,
         "brand_new_field":{"nested":true}}
        """
        let resolution = EntitlementsResolution.classify(
            status: 200, body: data(future), service: .official
        )
        guard case .entitled(let contract) = resolution else {
            Issue.record("expected entitled, got \(resolution)")
            return
        }
        #expect(contract.subscriptionStatus == .unknown("paused"))
        #expect(contract.textSyncUnit == .unknown("words"))
        #expect(contract.textSyncPeriod == .unknown("weekly"))
    }

    @Test func newerContractVersionIsUnsupportedNotGuessed() throws {
        let future = """
        {"contract_version":2,"plan":"free","audio_upload":true}
        """
        guard case .unsupported = EntitlementsResolution.classify(
            status: 200, body: data(future), service: .official
        ) else {
            Issue.record("newer contract version must classify as unsupported")
            return
        }
    }

    /// Invalid responses never carry authority: versions below 1,
    /// negative measurements, empty plan, and versioned-v1 omissions
    /// all classify as unsupported.
    @Test func invalidResponsesAreRejected() {
        let invalid = [
            #"{"contract_version":0,"plan":"p","audio_upload":true}"#,
            #"{"contract_version":-1,"plan":"p","audio_upload":true}"#,
            canonical.replacingOccurrences(of: #""text_sync_used": 2"#, with: #""text_sync_used": -2"#),
            canonical.replacingOccurrences(of: #""used_bytes": 42"#, with: #""used_bytes": -1"#),
            canonical.replacingOccurrences(
                of: #""storage_reserved_bytes": 7"#, with: #""storage_reserved_bytes": -7"#
            ),
            canonical.replacingOccurrences(of: #""text_sync_quota": 3"#, with: #""text_sync_quota": -3"#),
            canonical.replacingOccurrences(of: #""plan": "free""#, with: #""plan": """#),
            // Versioned v1 with a required field omitted entirely.
            #"{"contract_version":1,"plan":"p","audio_upload":true}"#,
        ]
        for body in invalid {
            guard case .unsupported = EntitlementsResolution.classify(
                status: 200, body: data(body), service: .official
            ) else {
                Issue.record("accepted invalid body: \(body.prefix(80))")
                continue
            }
        }
    }

    /// Known lifecycle and window invariants are enforced in both
    /// directions; unknown values stay opaque and gate nothing.
    @Test func lifecycleAndWindowInvariantsAreEnforced() {
        let invalid = [
            // Lifecycle: grace requires the deadline, active/expired forbid it.
            canonical.replacingOccurrences(
                of: ",\n  \"grace_until\": 1788000000", with: ""
            ),
            canonical.replacingOccurrences(of: #""subscription_status": "grace""#, with: #""subscription_status": "active""#),
            canonical.replacingOccurrences(of: #""subscription_status": "grace""#, with: #""subscription_status": "expired""#),
            // Window: monthly requires both bounds with start < end.
            canonical.replacingOccurrences(of: #""text_sync_period_start": 1785542400,"#, with: ""),
            canonical.replacingOccurrences(of: #""text_sync_period_end": 1788220800,"#, with: ""),
            canonical.replacingOccurrences(of: #""text_sync_period_start": 1785542400"#, with: #""text_sync_period_start": 1788220800"#),
            // Window: all-time forbids bounds.
            canonical.replacingOccurrences(of: #""text_sync_period": "monthly""#, with: #""text_sync_period": "none""#),
        ]
        for body in invalid {
            guard case .unsupported = EntitlementsResolution.classify(
                status: 200, body: data(body), service: .official
            ) else {
                Issue.record("accepted invariant violation: \(body.prefix(100))")
                continue
            }
        }
        // Unknown lifecycle with a deadline and unknown period with
        // bounds stay opaque and decodable.
        let unknownStatus = canonical.replacingOccurrences(
            of: #""subscription_status": "grace""#, with: #""subscription_status": "paused""#
        )
        guard case .entitled = EntitlementsResolution.classify(
            status: 200, body: data(unknownStatus), service: .official
        ) else {
            Issue.record("unknown status with grace_until must stay opaque")
            return
        }
        let unknownPeriod = canonical.replacingOccurrences(
            of: #""text_sync_period": "monthly""#, with: #""text_sync_period": "weekly""#
        )
        guard case .entitled = EntitlementsResolution.classify(
            status: 200, body: data(unknownPeriod), service: .official
        ) else {
            Issue.record("unknown period with bounds must stay opaque")
            return
        }
    }

    /// The flat shape predates subscription_status; a present
    /// grace_until implied grace, so that is the neutral default.
    @Test func flatShapeWithGraceDefaultsToGraceStatus() throws {
        let flat = """
        {"plan":"pro","text_sync_quota":null,"audio_upload":false,
         "storage_quota_bytes":null,"used_bytes":7,"grace_until":1788000000}
        """
        let resolution = EntitlementsResolution.classify(
            status: 200, body: data(flat), service: .official
        )
        guard case .entitled(let contract) = resolution else {
            Issue.record("expected entitled, got \(resolution)")
            return
        }
        #expect(contract.subscriptionStatus == .grace)
        #expect(contract.graceUntil == Date(timeIntervalSince1970: 1_788_000_000))
    }

    /// Whitespace is never an identifier: padded plans normalize, blank
    /// plans are malformed.
    @Test func whitespacePlanNamesNeverBecomeAuthority() throws {
        let padded = canonical.replacingOccurrences(of: #""plan": "free""#, with: #""plan": " free ""#)
        guard case .entitled(let contract) = EntitlementsResolution.classify(
            status: 200, body: data(padded), service: .official
        ) else {
            Issue.record("padded plan must normalize")
            return
        }
        #expect(contract.plan == "free")
        let blank = canonical.replacingOccurrences(of: #""plan": "free""#, with: #""plan": "   ""#)
        guard case .unsupported = EntitlementsResolution.classify(
            status: 200, body: data(blank), service: .official
        ) else {
            Issue.record("blank plan must be unsupported")
            return
        }
    }

    /// Only a caller-proven self-host origin maps a missing endpoint to
    /// fully entitled; the same 404 from the official service is an
    /// outage shape and never a grant.
    @Test func missingEndpointPolicyFollowsTheServiceClassification() {
        #expect(EntitlementsResolution.classify(
            status: 404, body: Data(), service: .selfHost
        ) == .selfHostOpen)
        #expect(EntitlementsResolution.classify(
            status: 404, body: Data(), service: .official
        ) == .unavailable(status: 404))
    }

    @Test func undecodableAndFailureResponsesCarryNoAuthority() {
        guard case .unsupported = EntitlementsResolution.classify(
            status: 200, body: data("not json"), service: .official
        ) else {
            Issue.record("garbage 200 must be unsupported")
            return
        }
        #expect(EntitlementsResolution.classify(status: 500, body: Data(), service: .official)
            == .unavailable(status: 500))
        #expect(EntitlementsResolution.classify(status: 401, body: Data(), service: .selfHost)
            == .unavailable(status: 401))
    }

    /// The synchronized contract document's canonical endpoint example
    /// (the fenced JSON block carrying contract_version) must decode as
    /// a valid entitled contract — the documented example can never
    /// drift ahead of what this client accepts.
    @Test func documentedCanonicalExampleDecodes() throws {
        let doc = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("docs/entitlements-contract.md"),
            encoding: .utf8
        )
        let blocks = doc.components(separatedBy: "```json").dropFirst().compactMap {
            $0.components(separatedBy: "```").first
        }
        let example = try #require(
            blocks.first { $0.contains("contract_version") },
            "contract doc has no canonical endpoint example"
        )
        let resolution = EntitlementsResolution.classify(
            status: 200, body: data(example), service: .official
        )
        guard case .entitled(let contract) = resolution else {
            Issue.record("documented example rejected by the client: \(resolution)")
            return
        }
        #expect(contract.contractVersion == EntitlementsContract.supportedContractVersion)
        #expect(contract.subscriptionStatus == .grace)
    }

    /// Canonical `code` wins; legacy `error` still classifies during the
    /// envelope transition.
    @Test func rejectionCodesClassifyStably() {
        #expect(EntitlementRejection.classify(
            errorBody: data(#"{"code":"text_quota_exceeded","error":"text_quota_exceeded"}"#)
        ) == .textQuotaExceeded)
        #expect(EntitlementRejection.classify(
            errorBody: data(#"{"error":"audio_upload_not_entitled"}"#)
        ) == .audioUploadNotEntitled)
        #expect(EntitlementRejection.classify(
            errorBody: data(#"{"code":"storage_quota_exceeded"}"#)
        ) == .storageQuotaExceeded)
        #expect(EntitlementRejection.classify(
            errorBody: data(#"{"code":"newer_code","error":"legacy_alias"}"#)
        ) == .unknown(code: "newer_code"))
        #expect(EntitlementRejection.classify(
            errorBody: data(#"{"error":"some_future_code"}"#)
        ) == .unknown(code: "some_future_code"))
        #expect(EntitlementRejection.classify(errorBody: data("plain text")) == nil)
        #expect(EntitlementRejection.classify(errorBody: data(#"{"message":"x"}"#)) == nil)
        // Blank codes are not identifiers; padded codes normalize.
        #expect(EntitlementRejection.classify(errorBody: data(#"{"code":"   "}"#)) == nil)
        #expect(EntitlementRejection.classify(
            errorBody: data(#"{"code":" text_quota_exceeded "}"#)
        ) == .textQuotaExceeded)
    }
}

extension EntitlementsContractTests {
    /// Storage admission charges committed plus reserved, so a pair whose sum
    /// cannot be represented is corrupt even where each half decodes.
    @Test func combinedStorageOverflowIsRefused() {
        for (used, reserved) in [
            (Int64.max, Int64(1)), (Int64.max, Int64.max), (Int64.max - 1, Int64(2)),
        ] {
            let body = Data("""
            {"contract_version":1,"plan":"free","subscription_status":"active",
             "text_sync_quota":null,"text_sync_used":0,"text_sync_unit":"recordings",
             "text_sync_period":"none","audio_upload":true,"storage_quota_bytes":null,
             "used_bytes":\(used),"storage_reserved_bytes":\(reserved)}
            """.utf8)
            guard case .unsupported(let reason) = EntitlementsResolution.classify(
                status: 200, body: body, service: .official
            ) else {
                Issue.record("expected an unsupported result for \(used) + \(reserved)")
                continue
            }
            #expect(reason.contains("overflow"))
        }
    }

    @Test func aCombinedStorageTotalAtTheLimitStillDecodes() {
        let body = Data("""
        {"contract_version":1,"plan":"free","subscription_status":"active",
         "text_sync_quota":null,"text_sync_used":0,"text_sync_unit":"recordings",
         "text_sync_period":"none","audio_upload":true,"storage_quota_bytes":null,
         "used_bytes":\(Int64.max - 1),"storage_reserved_bytes":1}
        """.utf8)
        guard case .entitled(let contract) = EntitlementsResolution.classify(
            status: 200, body: body, service: .official
        ) else {
            Issue.record("expected a contract")
            return
        }
        #expect(contract.usedBytes == Int64.max - 1)
        #expect(contract.storageReservedBytes == 1)
    }
}
