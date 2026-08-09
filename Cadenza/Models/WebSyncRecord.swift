import Foundation
import SwiftData

enum WebStructuredSyncState: String, Codable, Sendable {
    case pending
    case synced
    case failed
}

enum WebAudioSyncState: String, Codable, Sendable {
    case pending
    case uploading
    case synced
    case localOnly
    case unavailable
    case failed
}

enum WebSyncRetryDomain: String, Codable, Sendable {
    case structured
    case audio
}

enum WebSyncPersistenceError: Error, LocalizedError {
    case fetchFailed
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .fetchFailed:
            "Web sync state could not be loaded."
        case .saveFailed:
            "Web sync state could not be saved."
        }
    }
}

@Model
final class WebSyncRecord {
    @Attribute(.unique) var syncKey: String
    var userID: String
    var recordingID: UUID
    var remoteRecordingID: String?
    var structuredState: String
    var structuredHash: String?
    /// Exact local recording revision captured by the last accepted payload.
    /// This is intentionally separate from `syncedAt`: a local edit can land
    /// while an older request is in flight and must remain dirty afterwards.
    var structuredSourceRevision: Date?
    /// Exact local revision captured by the most recent structured attempt,
    /// successful or not. This lets backoff skip unchanged retries without
    /// hiding an edit made after the failed attempt began.
    var structuredAttemptRevision: Date?
    var audioState: String
    var audioFingerprint: String?
    /// Exact local revision covered by the last bounded audio metadata probe.
    /// This is independent of structured acknowledgement so an audio relink
    /// can be detected while text sync is entitlement-paused.
    var audioProbeRevision: Date?
    var uploadSessionID: String?
    var attemptCount: Int
    var nextAttemptAt: Date?
    /// Identifies which independent sync lane owns `nextAttemptAt`.
    /// Durable audio sessions may bypass structured backoff, but must honor
    /// failures produced by their own status, part, or commit requests.
    var retryDomain: String?
    var lastErrorCode: String?
    var lastAttemptAt: Date?
    var syncedAt: Date?
    var isDeletionTombstone: Bool

    init(userID: String, recordingID: UUID) {
        self.syncKey = Self.key(userID: userID, recordingID: recordingID)
        self.userID = userID
        self.recordingID = recordingID
        self.structuredState = WebStructuredSyncState.pending.rawValue
        self.audioState = WebAudioSyncState.pending.rawValue
        self.attemptCount = 0
        self.isDeletionTombstone = false
    }

    static func key(userID: String, recordingID: UUID) -> String {
        // Canonical-representation-safe: ASCII IDs keep their deployed
        // key spelling; other IDs embed as tagged UTF-8 hex so
        // byte-distinct spellings cannot alias one unique row.
        "\(AccountIdentity.keyComponent(userID)):\(recordingID.uuidString.lowercased())"
    }
}
