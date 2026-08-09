import Foundation

/// What the subscription surface shows for one account, derived once from the
/// gate so the view holds no policy of its own.
///
/// Every case is explicit. Nothing here infers a limit, a plan meaning, or a
/// lifecycle from an absent or unrecognized value, and nothing carries over
/// when the bound account changes: the gate is already scoped, and this is a
/// pure function of what it currently holds.
struct EntitlementsPresentation: Equatable, Sendable {
    /// A value the server sent that this build does not define. It is shown as
    /// opaque data so it stays visible without being given a meaning.
    enum Known<Defined: Equatable & Sendable>: Equatable, Sendable {
        case defined(Defined)
        case unrecognized(raw: String)
    }

    enum Lifecycle: Equatable, Sendable {
        case active
        case grace(until: Date)
        case expired
    }

    enum TextUnit: Equatable, Sendable {
        case recordings
        case bytes
    }

    enum Period: Equatable, Sendable {
        case allTime
        case monthly(resetsAt: Date?)
    }

    /// A measured total against a ceiling. `limit` nil is unlimited; `used` nil
    /// is a total this runtime cannot represent exactly and therefore will not
    /// state.
    struct Meter: Equatable, Sendable {
        let used: Int64?
        let limit: Int64?

        var isUnlimited: Bool { limit == nil }
        var isOverLimit: Bool {
            guard let used, let limit else { return false }
            return used > limit
        }
    }

    struct Limits: Equatable, Sendable {
        /// Opaque deployment identifier, shown verbatim and never treated as
        /// stable display copy.
        let plan: String
        let lifecycle: Known<Lifecycle>
        let textUnit: Known<TextUnit>
        let period: Known<Period>
        let text: Meter
        /// What the server says about audio upload right now.
        let audioUploadEntitled: Bool
        let storage: Meter
        /// Bytes held by uploads still in flight, already included in
        /// `storage.used`.
        let storageReserved: Int64
    }

    enum State: Equatable, Sendable {
        /// No authority for this account: nothing is claimed either way.
        case unavailable
        /// A caller-proven self-hosted backend that does not serve the
        /// endpoint. Limits are that deployment's own concern.
        case selfHostManaged
        case limits(Limits)
    }

    /// Local warnings raised from stable server rejection codes. The code is
    /// what is carried; the server's own message text never is.
    enum Warning: Equatable, Sendable, CaseIterable {
        case textQuotaExceeded
        case audioUploadNotEntitled
        case storageQuotaExceeded
    }

    /// Whether the audio-upload switch may be operated, and why not when it
    /// may not. A denial disables the control; it never writes the stored
    /// preference, so a later grant restores the user's own choice.
    enum AudioControl: Equatable, Sendable {
        case available
        case deniedNoAuthority
        case deniedByPlan
        case deniedByPause(Warning)

        var isAvailable: Bool { self == .available }
    }

    let state: State
    let warnings: [Warning]
    /// The account's own audio-upload preference, unchanged by entitlement.
    let audioPreferenceEnabled: Bool
    /// Whether an audio upload would actually start now. A false entitlement
    /// suppresses the transfer without touching the preference above, so a
    /// later grant resumes it.
    let audioUploadEffective: Bool
    /// Whether the audio-upload switch may be operated right now.
    let audioControl: AudioControl
    /// Whether asking the server again could change anything. Without a bound
    /// authority a refresh has nothing to fetch, so the action is not offered.
    let canRefresh: Bool
    /// Where the account is managed, when that is knowable and safe. Present
    /// only for a frozen official binding.
    let managementURL: URL?
    /// The official web surface, on the same proof as management. A
    /// self-hosted account never resolves here and no address is derived for
    /// it.
    let webAppURL: URL?

    /// Builds the surface from the gate's current state.
    static func make(
        authority: EntitlementsAuthority?,
        knowledge: EntitlementsKnowledge?,
        pause: EntitlementsPause,
        audioPreferenceEnabled: Bool,
        audioUploadAllowed: Bool,
        officialAccountURL: URL? = CadenzaBackendConfig.officialAccountURL(),
        officialWebAppURL: URL? = CadenzaBackendConfig.officialWebAppURL(),
        officialIssuerOrigin: String = CadenzaBackendConfig.official().origin.normalized
    ) -> EntitlementsPresentation {
        let state: State
        if authority == nil {
            state = .unavailable
        } else {
            switch knowledge {
            case .contract(let contract):
                state = .limits(limits(from: contract))
            case .selfHostOpen:
                state = .selfHostManaged
            case nil:
                state = .unavailable
            }
        }
        let official = isOfficial(authority, officialIssuerOrigin: officialIssuerOrigin)
        return EntitlementsPresentation(
            state: state,
            warnings: warnings(from: pause),
            audioPreferenceEnabled: audioPreferenceEnabled,
            audioUploadEffective: audioPreferenceEnabled && audioUploadAllowed,
            audioControl: audioControl(authority: authority, knowledge: knowledge, pause: pause),
            canRefresh: authority != nil,
            managementURL: official ? officialAccountURL : nil,
            webAppURL: official ? officialWebAppURL : nil
        )
    }

    /// Mirrors the gate's own audio decision, keeping the reason so the control
    /// can say why it is unavailable.
    private static func audioControl(
        authority: EntitlementsAuthority?,
        knowledge: EntitlementsKnowledge?,
        pause: EntitlementsPause
    ) -> AudioControl {
        guard authority != nil else { return .deniedNoAuthority }
        if let audioCode = pause.audioCode {
            return .deniedByPause(
                audioCode == "storage_quota_exceeded" ? .storageQuotaExceeded : .audioUploadNotEntitled
            )
        }
        switch knowledge {
        case .contract(let contract):
            return contract.audioUpload ? .available : .deniedByPlan
        case .selfHostOpen:
            return .available
        case nil:
            return .deniedNoAuthority
        }
    }

    /// Whether this account is provably on the official service.
    ///
    /// The frozen binding decides: it must classify as official and its issuer
    /// must still validate to the official origin. Every official-web
    /// destination hangs off this one proof, so a self-hosted account never
    /// reaches one and no address is derived from a server response or a
    /// configured base URL.
    private static func isOfficial(
        _ authority: EntitlementsAuthority?, officialIssuerOrigin: String
    ) -> Bool {
        guard let authority, authority.service == .official,
              let origin = try? IssuerOrigin(validating: authority.bound.issuerOrigin),
              AccountIdentity.matches(origin.originKey, authority.bound.originKey),
              AccountIdentity.matches(origin.normalized, officialIssuerOrigin) else {
            return false
        }
        return true
    }

    private static func warnings(from pause: EntitlementsPause) -> [Warning] {
        var warnings: [Warning] = []
        if pause.structuredCode == "text_quota_exceeded" { warnings.append(.textQuotaExceeded) }
        switch pause.audioCode {
        case "audio_upload_not_entitled": warnings.append(.audioUploadNotEntitled)
        case "storage_quota_exceeded": warnings.append(.storageQuotaExceeded)
        default: break
        }
        return warnings
    }

    private static func limits(from contract: EntitlementsContract) -> Limits {
        Limits(
            plan: contract.plan,
            lifecycle: lifecycle(from: contract),
            textUnit: textUnit(from: contract.textSyncUnit),
            period: period(from: contract),
            text: Meter(used: contract.textSyncUsed, limit: contract.textSyncQuota),
            audioUploadEntitled: contract.audioUpload,
            storage: Meter(used: consumedBytes(contract), limit: contract.storageQuotaBytes),
            storageReserved: contract.storageReservedBytes
        )
    }

    /// Committed plus reserved, which is what storage admission charges. A sum
    /// that cannot be represented yields nil rather than a wrong number.
    private static func consumedBytes(_ contract: EntitlementsContract) -> Int64? {
        let sum = contract.usedBytes.addingReportingOverflow(contract.storageReservedBytes)
        return sum.overflow ? nil : sum.partialValue
    }

    private static func lifecycle(from contract: EntitlementsContract) -> Known<Lifecycle> {
        switch contract.subscriptionStatus {
        case .active:
            return .defined(.active)
        case .grace:
            // The contract guarantees a deadline in this state; without one
            // there is nothing to count down to, so it stays unrecognized.
            guard let until = contract.graceUntil else { return .unrecognized(raw: "grace") }
            return .defined(.grace(until: until))
        case .expired:
            return .defined(.expired)
        case .unknown(let raw):
            return .unrecognized(raw: raw)
        }
    }

    private static func textUnit(from unit: EntitlementsContract.TextUnit) -> Known<TextUnit> {
        switch unit {
        case .recordings: return .defined(.recordings)
        case .bytes: return .defined(.bytes)
        case .unknown(let raw): return .unrecognized(raw: raw)
        }
    }

    private static func period(from contract: EntitlementsContract) -> Known<Period> {
        switch contract.textSyncPeriod {
        case .none: return .defined(.allTime)
        case .monthly: return .defined(.monthly(resetsAt: contract.textSyncPeriodEnd))
        case .unknown(let raw): return .unrecognized(raw: raw)
        }
    }
}

extension EntitlementsPresentation {
    /// The surface for the coordinator's currently bound account, or nil when
    /// this session has no sync at all.
    @MainActor
    static func current(_ sync: WebSyncCoordinator?) -> EntitlementsPresentation? {
        guard let sync else { return nil }
        let gate = sync.entitlements
        let userID = gate.authority?.bound.userID
        return make(
            authority: gate.authority,
            knowledge: gate.knowledge,
            pause: gate.pause,
            audioPreferenceEnabled: userID.map { sync.audioUploadEnabled(userID: $0) } ?? false,
            audioUploadAllowed: userID.map { gate.allowsAudioTransfer(for: $0) } ?? false
        )
    }
}
