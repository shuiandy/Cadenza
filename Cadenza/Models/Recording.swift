import Foundation
import SwiftData

enum PostProcessingBackfillState: String, CaseIterable, Sendable {
    case queued
    case processing
    case blocked
    case completed
}

enum CalendarAutoLinkState: String, CaseIterable, Sendable {
    case pending
    case linked
    case noMatch
    case userCleared
}

enum RecordingSource: String, CaseIterable, Codable, Sendable {
    case captured
    case importedAudio = "imported_audio"
    case external
}

@Model
final class Recording {
    var id: UUID
    var title: String
    var startDate: Date
    var createdAt: Date?
    var updatedAt: Date?
    var source: String?
    var endDate: Date?
    var duration: TimeInterval
    var audioFilePath: String?
    var meetingApp: String?
    var meetingURL: String?
    var language: String
    var tags: [String]
    var meetingType: String?
    var lastAccessedDate: Date?
    var trashedDate: Date?
    var audioSegmentsDirectory: String?
    var linkedCalendarEventID: String?
    var speakerMappings: [SpeakerLabelMapping]?
    var speakerSuggestions: [SpeakerLabelSuggestion]?
    var processingAttempts: Int = 0
    var postProcessingBackfillState: String?
    var postProcessingBackfillRequestedAt: Date?
    var postProcessingBackfillLastAttemptAt: Date?
    var postProcessingBackfillNextAttemptAt: Date?
    var postProcessingBackfillFailureCount: Int = 0
    var postProcessingBackfillLastError: String?
    var calendarAutoLinkState: String?
    var calendarAutoLinkAttemptedAt: Date?
    var audioFileOwnership: String?
    /// Non-nil marks a recording that already existed when its profile was
    /// bound to an account (spec §6.6): the binding transaction stamps every
    /// row with its transaction ID, and the historical-sync consent decides
    /// whether these rows may ever sync. Rows created after binding stay
    /// nil and sync under the normal rules. Never inferred from dates.
    var awaitingHistoricalConsentBindingID: UUID?

    @Relationship(deleteRule: .cascade)
    var transcript: Transcript?

    @Relationship(deleteRule: .cascade)
    var summary: MeetingSummary?

    @Relationship
    var folder: Folder?

    init(
        id: UUID = UUID(),
        title: String = "Recording",
        startDate: Date = Date(),
        language: String = "auto",
        source: RecordingSource = .captured
    ) {
        let now = Date()
        self.id = id
        self.title = title
        self.startDate = startDate
        self.createdAt = now
        self.updatedAt = now
        self.source = source.rawValue
        self.duration = 0
        self.language = language
        self.tags = []
        self.speakerMappings = []
    }
}

extension Recording {
    /// Typed view of the raw path columns. The stored String stays the
    /// database format (no schema migration); everything above the store
    /// boundary works with `AudioFileReference` + `ProfileStorageResolver`.
    var audioFileReference: AudioFileReference? {
        get { AudioFileReference(storageValue: audioFilePath) }
        set { audioFilePath = newValue?.storageValue }
    }

    var segmentsDirectoryReference: AudioFileReference? {
        get { AudioFileReference(storageValue: audioSegmentsDirectory) }
        set { audioSegmentsDirectory = newValue?.storageValue }
    }

    /// Typed view of the ownership column. Rows written before the column
    /// existed (nil) and unrecognized values read defensively as
    /// `unknownLegacy` — deletion-adjacent code must never assume the app
    /// owns a file it cannot prove it created (INV-18).
    var ownership: AudioFileOwnership {
        get { audioFileOwnership.flatMap(AudioFileOwnership.init(rawValue:)) ?? .unknownLegacy }
        set { audioFileOwnership = newValue.rawValue }
    }
}

/// Who owns the bytes behind a recording's audio reference (INV-18).
/// `appCreated`: Cadenza wrote the file and may delete or replace it.
/// `userOwned`: the user provided the file; Cadenza never mutates it.
/// `unknownLegacy`: provenance unprovable (pre-ownership rows, orphan
/// recovery, import-reuse) — treated like `userOwned` for safety.
enum AudioFileOwnership: String, Codable, Sendable, CaseIterable {
    case appCreated
    case userOwned
    case unknownLegacy
}

/// Maps a raw diarization label (e.g. "Speaker 1") to a SpeakerProfile ID for a specific recording.
struct SpeakerLabelMapping: Codable, Sendable {
    var rawLabel: String
    var profileID: UUID
}
