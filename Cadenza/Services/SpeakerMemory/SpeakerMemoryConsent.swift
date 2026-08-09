import Foundation

enum SpeakerMemoryConsent {
    static let defaultsKey = "enableSpeakerMemory"

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: defaultsKey)
    }

    static func isSettingsToggleDisabled(
        diarizationEnabled: Bool,
        memoryEnabled: Bool,
        isDeleting: Bool
    ) -> Bool {
        isDeleting || (!diarizationEnabled && !memoryEnabled)
    }
}

struct SpeakerMemoryWriteSession: Sendable, Equatable {
    let generation: UInt64
}
