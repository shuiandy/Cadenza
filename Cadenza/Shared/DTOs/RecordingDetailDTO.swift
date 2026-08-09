import Foundation

/// Full recording detail including transcript and summary content.
struct RecordingDetailDTO: Codable, Sendable, Identifiable {
    let id: UUID
    var title: String
    var startDate: Date
    var endDate: Date?
    var duration: TimeInterval
    var meetingApp: String?
    var meetingURL: String?
    var language: String
    var tags: [String]
    var meetingType: String?
    var lastAccessedDate: Date?
    var folderID: UUID?
    /// Resolve to a URL via `ProfileStorageResolver`; the DTO never exposes
    /// a raw path string (spec §10.1).
    var audioFile: AudioFileReference?
    var linkedCalendarEventID: String?
    var createdAt: Date? = nil
    var updatedAt: Date? = nil
    var source: String? = nil

    // Full content
    var transcript: TranscriptDTO?
    var summary: SummaryDTO?
    var speakerMappings: [SpeakerLabelMappingDTO]
    var speakerSuggestions: [SpeakerLabelSuggestionDTO]
}
