import Foundation

/// Client-side view of the versioned entitlement contract served by
/// GET /me/entitlements (spec 11). Enforcement lives entirely on the
/// server (INV-12); everything here informs UI and upload-switch
/// availability only. The wire protocol is documented in
/// docs/entitlements-contract.md, maintained in lockstep with the
/// server repository.
struct EntitlementsContract: Equatable, Sendable {
    /// The newest response shape this client understands.
    static let supportedContractVersion = 1

    enum TextPeriod: Equatable, Sendable {
        case none
        case monthly
        /// Forward compatibility: an unrecognized period renders as
        /// opaque data and never gates anything client-side.
        case unknown(String)

        init(rawValue: String) {
            switch rawValue {
            case "none": self = .none
            case "monthly": self = .monthly
            default: self = .unknown(rawValue)
            }
        }
    }

    enum TextUnit: Equatable, Sendable {
        case recordings
        case bytes
        case unknown(String)

        init(rawValue: String) {
            switch rawValue {
            case "recordings": self = .recordings
            case "bytes": self = .bytes
            default: self = .unknown(rawValue)
            }
        }
    }

    /// Provider-neutral entitlement lifecycle state.
    enum SubscriptionStatus: Equatable, Sendable {
        case active
        case grace
        case expired
        case unknown(String)

        init(rawValue: String) {
            switch rawValue {
            case "active": self = .active
            case "grace": self = .grace
            case "expired": self = .expired
            default: self = .unknown(rawValue)
            }
        }
    }

    let contractVersion: Int
    let plan: String
    let subscriptionStatus: SubscriptionStatus
    /// nil = unlimited. Entitlement fields describe the server's
    /// effective behavior, not raw plan configuration.
    let textSyncQuota: Int64?
    let textSyncUsed: Int64
    let textSyncUnit: TextUnit
    let textSyncPeriod: TextPeriod
    /// Authoritative accounting-window boundary for period-based
    /// quotas; nil for all-time accounting.
    let textSyncPeriodStart: Date?
    let textSyncPeriodEnd: Date?
    let audioUpload: Bool
    /// nil = unlimited.
    let storageQuotaBytes: Int64?
    let usedBytes: Int64
    let storageReservedBytes: Int64
    /// Downgrade grace deadline; audio stays readable until it passes
    /// while `audioUpload` is already false.
    let graceUntil: Date?
}

/// How the caller classifies the origin it fetched from. Only a
/// caller-proven self-hosted origin may interpret a missing endpoint as
/// fully entitled; on the official service a 404 proves nothing.
enum EntitlementsService: Equatable, Sendable {
    case official
    case selfHost
}

/// Classified outcome of one entitlements fetch. Only two shapes carry
/// authority: a supported contract, and the self-host open state. Every
/// other outcome means "nothing learned" — the caller keeps its
/// last-known state and never guesses entitlements.
enum EntitlementsResolution: Equatable, Sendable {
    case entitled(EntitlementsContract)
    /// 404 from a caller-proven self-hosted origin: that backend does
    /// not implement the endpoint and enforcement is its own concern
    /// (spec 11), so the account is treated as fully entitled.
    case selfHostOpen
    /// A response this client cannot interpret (newer or invalid
    /// contract, malformed body).
    case unsupported(reason: String)
    /// Transport or server failure — including a 404 from the official
    /// service, which is an outage shape, never an entitlement grant.
    case unavailable(status: Int)

    static func classify(
        status: Int, body: Data, service: EntitlementsService
    ) -> EntitlementsResolution {
        switch status {
        case 200:
            return decode(body: body)
        case 404:
            switch service {
            case .selfHost: return .selfHostOpen
            case .official: return .unavailable(status: 404)
            }
        default:
            return .unavailable(status: status)
        }
    }

    private static func decode(body: Data) -> EntitlementsResolution {
        do {
            let contract = try JSONDecoder().decode(EntitlementsContract.self, from: body)
            guard contract.contractVersion <= EntitlementsContract.supportedContractVersion else {
                return .unsupported(
                    reason: "contract version \(contract.contractVersion) is newer than supported"
                )
            }
            return .entitled(contract)
        } catch let error as EntitlementsContract.ContractError {
            return .unsupported(reason: error.reason)
        } catch {
            return .unsupported(reason: "undecodable entitlements body")
        }
    }
}

extension EntitlementsContract: Decodable {
    struct ContractError: Error {
        let reason: String
    }

    private enum CodingKeys: String, CodingKey {
        case contractVersion = "contract_version"
        case plan
        case subscriptionStatus = "subscription_status"
        case textSyncQuota = "text_sync_quota"
        case textSyncUsed = "text_sync_used"
        case textSyncUnit = "text_sync_unit"
        case textSyncPeriod = "text_sync_period"
        case textSyncPeriodStart = "text_sync_period_start"
        case textSyncPeriodEnd = "text_sync_period_end"
        case audioUpload = "audio_upload"
        case storageQuotaBytes = "storage_quota_bytes"
        case usedBytes = "used_bytes"
        case storageReservedBytes = "storage_reserved_bytes"
        case graceUntil = "grace_until"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let versioned = container.contains(.contractVersion)
        if versioned {
            contractVersion = try container.decode(Int.self, forKey: .contractVersion)
            guard contractVersion >= 1 else {
                throw ContractError(reason: "contract version below 1")
            }
            // A versioned v1 response must carry the full v1 field set;
            // an omission is a malformed response, not a default.
            if contractVersion == EntitlementsContract.supportedContractVersion {
                for key: CodingKeys in [
                    .plan, .subscriptionStatus, .textSyncQuota, .textSyncUsed,
                    .textSyncUnit, .textSyncPeriod, .audioUpload,
                    .storageQuotaBytes, .usedBytes, .storageReservedBytes,
                ] where !container.contains(key) {
                    throw ContractError(reason: "versioned response missing \(key.rawValue)")
                }
            }
        } else {
            // The pre-versioning flat shape: its own fields are still
            // required; only fields that never existed in that shape may
            // take neutral defaults below.
            contractVersion = 1
            for key: CodingKeys in [
                .plan, .textSyncQuota, .audioUpload, .storageQuotaBytes, .usedBytes,
            ] where !container.contains(key) {
                throw ContractError(reason: "flat response missing \(key.rawValue)")
            }
        }
        // Whitespace is never an identifier: a padded name normalizes, a
        // blank one is malformed.
        plan = try container.decode(String.self, forKey: .plan)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plan.isEmpty else {
            throw ContractError(reason: "empty plan")
        }
        textSyncQuota = try container.decodeIfPresent(Int64.self, forKey: .textSyncQuota)
        textSyncUsed = try container.decodeIfPresent(Int64.self, forKey: .textSyncUsed) ?? 0
        let rawUnit = try container.decodeIfPresent(String.self, forKey: .textSyncUnit)
        textSyncUnit = rawUnit.map(TextUnit.init(rawValue:)) ?? .recordings
        let rawPeriod = try container.decodeIfPresent(String.self, forKey: .textSyncPeriod)
        textSyncPeriod = rawPeriod.map(TextPeriod.init(rawValue:)) ?? .none
        textSyncPeriodStart = try container.decodeIfPresent(Double.self, forKey: .textSyncPeriodStart)
            .map(Date.init(timeIntervalSince1970:))
        textSyncPeriodEnd = try container.decodeIfPresent(Double.self, forKey: .textSyncPeriodEnd)
            .map(Date.init(timeIntervalSince1970:))
        audioUpload = try container.decode(Bool.self, forKey: .audioUpload)
        storageQuotaBytes = try container.decodeIfPresent(Int64.self, forKey: .storageQuotaBytes)
        usedBytes = try container.decodeIfPresent(Int64.self, forKey: .usedBytes) ?? 0
        storageReservedBytes =
            try container.decodeIfPresent(Int64.self, forKey: .storageReservedBytes) ?? 0
        graceUntil = try container.decodeIfPresent(Double.self, forKey: .graceUntil)
            .map(Date.init(timeIntervalSince1970:))
        let rawStatus = try container.decodeIfPresent(String.self, forKey: .subscriptionStatus)
        // The flat shape predates the status field but already carried
        // grace_until: its presence implied grace, so that is the
        // neutral default; otherwise active.
        subscriptionStatus = rawStatus.map(SubscriptionStatus.init(rawValue:))
            ?? (graceUntil != nil ? .grace : .active)
        // Negative measurements are corrupt, never interpretable.
        for (name, value) in [
            ("text_sync_quota", textSyncQuota), ("storage_quota_bytes", storageQuotaBytes),
        ] where value.map({ $0 < 0 }) == true {
            throw ContractError(reason: "negative \(name)")
        }
        for (name, value) in [
            ("text_sync_used", textSyncUsed), ("used_bytes", usedBytes),
            ("storage_reserved_bytes", storageReservedBytes),
        ] where value < 0 {
            throw ContractError(reason: "negative \(name)")
        }
        // Storage admission charges committed plus reserved, so a pair whose
        // sum is not representable is corrupt even where each half is.
        guard !usedBytes.addingReportingOverflow(storageReservedBytes).overflow else {
            throw ContractError(reason: "used_bytes and storage_reserved_bytes overflow")
        }
        // Known lifecycle and window invariants hold; unknown values
        // stay opaque and gate nothing.
        switch subscriptionStatus {
        case .grace:
            guard graceUntil != nil else {
                throw ContractError(reason: "grace status without grace_until")
            }
        case .active, .expired:
            guard graceUntil == nil else {
                throw ContractError(reason: "grace_until without grace status")
            }
        case .unknown:
            break
        }
        switch textSyncPeriod {
        case .monthly:
            guard let start = textSyncPeriodStart, let end = textSyncPeriodEnd,
                  start < end else {
                throw ContractError(reason: "monthly period without valid bounds")
            }
        case .none:
            guard textSyncPeriodStart == nil, textSyncPeriodEnd == nil else {
                throw ContractError(reason: "all-time period with bounds")
            }
        case .unknown:
            break
        }
    }
}

/// Stable machine-readable rejection codes emitted by entitlement
/// enforcement in the standard error envelope. The canonical field is
/// `code`; `error` remains readable as the legacy alias during the
/// envelope transition. Codes are append-only on the server; anything
/// unrecognized stays visible as an opaque code so a newer server never
/// crashes an older client.
enum EntitlementRejection: Equatable, Sendable {
    case textQuotaExceeded
    case audioUploadNotEntitled
    case storageQuotaExceeded
    case unknown(code: String)

    init(code: String) {
        switch code {
        case "text_quota_exceeded": self = .textQuotaExceeded
        case "audio_upload_not_entitled": self = .audioUploadNotEntitled
        case "storage_quota_exceeded": self = .storageQuotaExceeded
        default: self = .unknown(code: code)
        }
    }

    private struct ErrorEnvelope: Decodable {
        let code: String?
        let error: String?
    }

    /// Parses the standard error envelope, preferring the canonical
    /// `code` and falling back to the legacy `error` alias; nil when
    /// the body carries neither (the failure is then not an
    /// entitlement rejection). A blank code is not an identifier and
    /// never becomes an opaque diagnostic.
    static func classify(errorBody: Data) -> EntitlementRejection? {
        guard let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: errorBody),
              let raw = envelope.code ?? envelope.error else {
            return nil
        }
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return nil }
        return EntitlementRejection(code: code)
    }
}
