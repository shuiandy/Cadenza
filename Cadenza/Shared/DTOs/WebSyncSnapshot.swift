import Foundation

/// Minimal row metadata used to schedule web sync work.
///
/// Keeping queue discovery separate from `WebSyncSnapshot` prevents the
/// minute-by-minute reconciliation pass from materializing transcripts,
/// summaries, and transcript segments for the entire library. Full details
/// are fetched only when a candidate is actually processed.
struct WebSyncCandidate: Sendable, Equatable {
    let recordingID: UUID
    let contentRevision: Date
    let trashedDate: Date?
    let awaitingHistoricalConsentBindingID: UUID?
    let hasAudioReference: Bool

    init(
        recordingID: UUID,
        contentRevision: Date,
        trashedDate: Date?,
        awaitingHistoricalConsentBindingID: UUID?,
        hasAudioReference: Bool = false
    ) {
        self.recordingID = recordingID
        self.contentRevision = contentRevision
        self.trashedDate = trashedDate
        self.awaitingHistoricalConsentBindingID = awaitingHistoricalConsentBindingID
        self.hasAudioReference = hasAudioReference
    }
}

struct WebSyncSnapshot: Sendable {
    let detail: RecordingDetailDTO
    let folderPath: String
    let trashedDate: Date?
    /// Resolved at the store boundary so sync never re-interprets the
    /// reference against a different root.
    var audioFileURL: URL? = nil
    /// Non-nil marks a recording that predates its profile's account
    /// binding (spec §6.6): it may sync only under an affirmative
    /// historical-sync consent, and its audio additionally requires the
    /// with-audio consent.
    var awaitingHistoricalConsentBindingID: UUID? = nil
    /// Denormalized meeting snapshot persisted on the recording at link time.
    /// Sync sends this value and never asks EventKit.
    var calendarEvent: WebSyncCalendarEvent? = nil
    /// User tapped Remove Link (`.userCleared`). Encoded as JSON null so the
    /// server clears columns. Distinct from a missing field, which keeps the
    /// last snapshot (never linked, or EventKit gone).
    var calendarEventCleared: Bool = false
    /// Set only when the server speaker-identity switch is on. Omitted from
    /// the wire otherwise so older backends never see an unknown field.
    var speakerMappings: [WebSyncSpeakerMapping]? = nil

    var contentRevision: Date {
        detail.updatedAt ?? detail.createdAt ?? detail.startDate
    }
}

struct WebSyncRecordDTO: Sendable, Equatable {
    let syncKey: String
    let userID: String
    let recordingID: UUID
    let remoteRecordingID: String?
    let structuredState: String
    let structuredHash: String?
    let structuredSourceRevision: Date?
    let structuredAttemptRevision: Date?
    let audioState: String
    let audioFingerprint: String?
    let audioProbeRevision: Date?
    let uploadSessionID: String?
    let attemptCount: Int
    let nextAttemptAt: Date?
    let retryDomain: String?
    let lastAttemptAt: Date?
    let syncedAt: Date?
    let isDeletionTombstone: Bool
    /// Last durable failure diagnostic; a bounded code, never server prose.
    let lastErrorCode: String?
}

struct WebSyncMutation: Sendable {
    let userID: String
    let recordingID: UUID
    var remoteRecordingID: String?
    var structuredState: String?
    var structuredHash: String?
    var structuredSourceRevision: Date?
    var structuredAttemptRevision: Date?
    var audioState: String?
    var audioFingerprint: String?
    var audioProbeRevision: Date?
    var uploadSessionID: String?
    var clearUploadSessionID = false
    var attemptCount: Int?
    var nextAttemptAt: Date?
    var retryDomain: String?
    var lastErrorCode: String?
    var syncedAt: Date?
    var isDeletionTombstone: Bool?

    init(userID: String, recordingID: UUID) {
        self.userID = userID
        self.recordingID = recordingID
    }
}
