import Foundation

/// Persists whether Cadenza may start a Core Audio tap from automatic recording.
///
/// New installs reach this state only after a user-initiated action successfully
/// starts a tap. The one-time legacy migration also preserves an existing explicit
/// auto-record opt-in. This is deliberately not an authorization status: Core Audio
/// exposes no public preflight API, and the user can later revoke or reset TCC.
enum SystemAudioCapturePreparation {
    static let preparedDefaultsKey = "systemAudioCapturePrepared.v1"
    private static let legacyMigrationDefaultsKey = "systemAudioCaptureLegacyMigration.v1"

    static func isPrepared(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: preparedDefaultsKey)
    }

    static func markPrepared(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: preparedDefaultsKey)
    }

    /// Preserve existing explicit auto-record setups without treating a newly
    /// registered default as evidence that the tap has previously succeeded.
    static func migrateLegacyAutoRecordUser(
        legacyAutoRecordWasExplicitlyEnabled: Bool,
        defaults: UserDefaults = .standard
    ) {
        guard !defaults.bool(forKey: legacyMigrationDefaultsKey) else { return }

        if legacyAutoRecordWasExplicitlyEnabled {
            markPrepared(defaults: defaults)
        }
        defaults.set(true, forKey: legacyMigrationDefaultsKey)
    }
}
