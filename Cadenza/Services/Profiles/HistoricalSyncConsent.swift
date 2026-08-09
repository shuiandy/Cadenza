import Foundation

/// Per-profile decision about syncing recordings that existed before the
/// profile was bound to an account (spec §6.6, INV-15). Binding never
/// implies historical upload: until the user decides, marked rows stay
/// local. Stored in the profile's scoped defaults.
enum HistoricalSyncConsent: String, CaseIterable, Sendable {
    case undecided
    case textOnly
    case withAudio

    static let scopedKeyBase = "historicalSyncConsent.v1"

    /// Absent or unrecognized stored values read as `.undecided` — the
    /// value that blocks historical sync, so corruption can never widen
    /// consent.
    static func read(from scope: ProfileDefaultsScope) -> HistoricalSyncConsent {
        guard let raw = scope.string(forKey: scopedKeyBase),
              let value = HistoricalSyncConsent(rawValue: raw) else {
            return .undecided
        }
        return value
    }

    func write(to scope: ProfileDefaultsScope) {
        scope.set(rawValue, forKey: Self.scopedKeyBase)
    }

    /// Active-profile read through the boot-installed resolver; the same
    /// fail-closed default as the scope-based read.
    static func readActiveProfile(defaults: UserDefaults = .standard) -> HistoricalSyncConsent {
        guard let raw = defaults.string(forKey: ActiveProfileDefaults.key(scopedKeyBase)),
              let value = HistoricalSyncConsent(rawValue: raw) else {
            return .undecided
        }
        return value
    }

    /// Active-profile write through the boot-installed resolver.
    static func writeActiveProfile(
        _ consent: HistoricalSyncConsent, defaults: UserDefaults = .standard
    ) {
        defaults.set(consent.rawValue, forKey: ActiveProfileDefaults.key(scopedKeyBase))
    }

    /// Whether rows marked awaiting-historical-consent may sync at all.
    var allowsHistoricalSync: Bool {
        switch self {
        case .undecided: return false
        case .textOnly, .withAudio: return true
        }
    }

    /// Whether the user consented to historical audio leaving the machine.
    /// Recorded as intent; the runtime audio-upload switches still apply.
    var allowsHistoricalAudio: Bool {
        self == .withAudio
    }
}
