import Foundation

/// The exact authority one entitlement snapshot belongs to: the profile plus
/// the complete frozen bound tuple, compared byte for byte so canonically
/// equivalent but byte-distinct spellings never adopt each other's state.
struct EntitlementsAuthority: Sendable {
    let profileID: UUID
    let bound: Profile.BoundAccount
    /// How a missing endpoint may be read, decided once from the frozen
    /// binding rather than per response.
    let service: EntitlementsService

    /// Nil while the profile is unbound.
    ///
    /// The service classification comes from the frozen validated binding and
    /// nothing else. A binding that no longer validates proves no self-hosted
    /// identity, so it reads as official and a missing endpoint means an
    /// outage.
    init?(
        profileID: UUID,
        bound: Profile.BoundAccount?,
        officialIssuerOrigin: String = CadenzaBackendConfig.official().origin.normalized
    ) {
        guard let bound else { return nil }
        self.profileID = profileID
        self.bound = bound
        self.service = Self.classify(bound: bound, officialIssuerOrigin: officialIssuerOrigin)
    }

    private static func classify(
        bound: Profile.BoundAccount, officialIssuerOrigin: String
    ) -> EntitlementsService {
        guard let origin = try? IssuerOrigin(validating: bound.issuerOrigin),
              AccountIdentity.matches(origin.originKey, bound.originKey) else {
            return .official
        }
        return AccountIdentity.matches(origin.normalized, officialIssuerOrigin) ? .official : .selfHost
    }

    /// Byte-exact identity; display fields of a binding are not identity.
    func matches(_ other: EntitlementsAuthority) -> Bool {
        profileID == other.profileID && AccountIdentity.boundTupleMatches(bound, other.bound)
    }

    func owns(userID: String) -> Bool {
        AccountIdentity.matches(bound.userID, userID)
    }
}

/// What the client currently knows about an account's entitlements.
enum EntitlementsKnowledge: Equatable, Sendable {
    case contract(EntitlementsContract)
    /// A caller-proven self-hosted backend that does not implement the
    /// endpoint; enforcement is that deployment's own concern.
    case selfHostOpen
}

/// Local transfer pauses recorded from stable server rejection codes.
///
/// A pause is advisory: the server remains the only enforcement authority, and
/// these only stop the client repeating an attempt it has already refused for a
/// stated reason.
struct EntitlementsPause: Equatable, Sendable {
    var structuredCode: String?
    var audioCode: String?

    static let none = EntitlementsPause()

    var isStructuredPaused: Bool { structuredCode != nil }
    var isAudioPaused: Bool { audioCode != nil }
}

/// Per-account entitlement knowledge and the pauses derived from server
/// rejections.
///
/// Every read and write names the authority it belongs to; a call naming a
/// different one finds nothing, so no account reads another's snapshot or
/// inherits its pauses. State is in memory only: the endpoint is cheap, and
/// having no snapshot is already a defined state.
@MainActor
@Observable
final class EntitlementsGate {
    private(set) var authority: EntitlementsAuthority?
    private(set) var knowledge: EntitlementsKnowledge?
    private(set) var pause: EntitlementsPause = .none

    /// Which transfers a fresh authoritative snapshot reopened.
    struct Reopened: Equatable, Sendable {
        var structured = false
        var audio = false

        var isEmpty: Bool { !structured && !audio }
    }

    /// What one applied resolution did.
    ///
    /// `learned` is what the caller acts on: an authoritative answer accepted
    /// for the bound account that established knowledge it did not have, or
    /// replaced what it had. A repeat of the same snapshot teaches nothing, and
    /// neither does a resolution carrying no authority or naming another
    /// account.
    struct Applied: Equatable, Sendable {
        var learned = false
        var reopened = Reopened()
    }

    /// Points the gate at an account, discarding what the previous one knew.
    func bind(to authority: EntitlementsAuthority?) {
        if let authority, let current = self.authority, current.matches(authority) {
            return
        }
        self.authority = authority
        knowledge = nil
        pause = .none
    }

    /// Records what one fetch resolved to, reporting which pauses it lifted.
    ///
    /// Only the two shapes that carry authority replace what is known. An
    /// unsupported or unavailable response leaves the same account's previous
    /// snapshot untouched and lifts nothing. A resolution for an account no
    /// longer bound is discarded.
    @discardableResult
    func apply(
        _ resolution: EntitlementsResolution, for authority: EntitlementsAuthority
    ) -> Applied {
        guard let current = self.authority, current.matches(authority) else { return Applied() }
        let fresh: EntitlementsKnowledge
        switch resolution {
        case .entitled(let contract):
            fresh = .contract(contract)
        case .selfHostOpen:
            fresh = .selfHostOpen
        case .unsupported, .unavailable:
            return Applied()
        }
        let learned = knowledge != fresh
        knowledge = fresh
        return Applied(learned: learned, reopened: liftPauses(allowedBy: fresh))
    }

    /// Lifts a pause only where fresh authority proves the capacity or
    /// permission it stood for has returned.
    private func liftPauses(allowedBy knowledge: EntitlementsKnowledge) -> Reopened {
        var reopened = Reopened()
        switch knowledge {
        case .selfHostOpen:
            reopened.structured = pause.isStructuredPaused
            reopened.audio = pause.isAudioPaused
            pause = .none
        case .contract(let contract):
            if pause.isStructuredPaused, hasTextCapacity(contract) {
                pause.structuredCode = nil
                reopened.structured = true
            }
            if pause.isAudioPaused, contract.audioUpload, hasStorageCapacity(contract) {
                pause.audioCode = nil
                reopened.audio = true
            }
        }
        return reopened
    }

    private func hasTextCapacity(_ contract: EntitlementsContract) -> Bool {
        guard let quota = contract.textSyncQuota else { return true }
        return contract.textSyncUsed < quota
    }

    private func hasStorageCapacity(_ contract: EntitlementsContract) -> Bool {
        guard let quota = contract.storageQuotaBytes else { return true }
        // A total that cannot be represented is not capacity. Decoding already
        // refuses such a pair; this stays correct for any contract value.
        let consumed = contract.usedBytes.addingReportingOverflow(contract.storageReservedBytes)
        guard !consumed.overflow else { return false }
        return consumed.partialValue < quota
    }

    /// Records a stable rejection code as a pause for the account that received
    /// it. An unrecognized code changes nothing.
    func note(_ rejection: EntitlementRejection, for authority: EntitlementsAuthority) {
        guard let current = self.authority, current.matches(authority) else { return }
        switch rejection {
        case .textQuotaExceeded:
            pause.structuredCode = "text_quota_exceeded"
        case .audioUploadNotEntitled:
            pause.audioCode = "audio_upload_not_entitled"
        case .storageQuotaExceeded:
            pause.audioCode = "storage_quota_exceeded"
        case .unknown:
            break
        }
    }

    /// Whether a further structured sync attempt should be made.
    ///
    /// Only a pause recorded from a stated server rejection stops one.
    /// Entitlement fields never gate structured sync, so an account with no
    /// snapshot keeps syncing text and the server refuses what it must.
    func allowsStructuredSync(for userID: String) -> Bool {
        guard let authority, authority.owns(userID: userID) else { return true }
        return !pause.isStructuredPaused
    }

    /// Whether a new audio transfer should be started.
    ///
    /// This fails closed. Audio moves user media to a backend that may refuse
    /// it, so it needs positive evidence: a supported contract that says the
    /// account may upload, or a caller-proven self-hosted backend. Absent
    /// knowledge, an unreadable response and an account this gate does not
    /// speak for all mean no evidence, which is not a grant.
    func allowsAudioTransfer(for userID: String) -> Bool {
        guard let authority, authority.owns(userID: userID) else { return false }
        if pause.isAudioPaused { return false }
        switch knowledge {
        case .contract(let contract):
            return contract.audioUpload
        case .selfHostOpen:
            return true
        case nil:
            return false
        }
    }
}
