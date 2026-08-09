import SwiftUI

enum SettingsCategory: String, CaseIterable, Identifiable {
    case general
    case recording
    case appearance
    case transcription
    case integrations
    case profiles

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .recording: String(localized: "Recording")
        case .appearance: String(localized: "Appearance")
        case .transcription: String(localized: "Transcription & Summary")
        case .integrations: String(localized: "Integrations")
        case .profiles: String(localized: "Profiles")
        }
    }

    var icon: String {
        switch self {
        case .general: "gear"
        case .recording: "record.circle"
        case .appearance: "paintbrush"
        case .transcription: "text.quote"
        case .integrations: "link"
        case .profiles: "person.2.circle"
        }
    }
}
