import Foundation

/// Lightweight recording struct for list display (no SwiftData dependency).
/// `Equatable` so SwiftUI can prove a card or list input unchanged instead
/// of re-evaluating its body, and so AppState can guard observable writes.
struct RecordingDTO: Codable, Sendable, Identifiable, Equatable {
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
    var trashedDate: Date?
    var folderID: UUID?

    var linkedCalendarEventID: String?
    var createdAt: Date? = nil
    var updatedAt: Date? = nil
    var source: String? = nil

    // Preview strings
    var hasTranscript: Bool
    var hasSummary: Bool
    var transcriptPreview: String?
    var summaryPreview: String?
    /// Mapped speaker display names, resolved at the store boundary.
    /// Only confirmed mappings appear here; raw `SPEAKER_N` labels don't.
    /// Optional so previously encoded DTOs keep decoding.
    var speakerNames: [String]? = nil
    /// Resolve to a URL via `ProfileStorageResolver`; the DTO never exposes
    /// a raw path string (spec §10.1).
    var audioFile: AudioFileReference?
}
