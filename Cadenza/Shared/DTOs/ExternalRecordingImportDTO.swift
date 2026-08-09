import Foundation

enum ExternalImportDisposition: String, Codable, Sendable, CaseIterable {
    case pending
    case imported
    case ignored
    case conflict
}

enum ExternalImportPreviewStatus: String, Codable, Sendable {
    case new
    case unchanged
    case updated
    case ignored
    case possibleDuplicate = "possible_duplicate"
    case conflict
}

enum ExternalImportQualitySignal: String, Codable, Sendable, Hashable {
    case likelyEmpty = "likely_empty"
    case likelyTest = "likely_test"
    case shortDuration = "short_duration"
    case noTranscript = "no_transcript"
}

enum ExternalRecordingUpsertStatus: String, Codable, Sendable {
    case imported
    case updated
    case unchanged
    case ignored
    case conflict
    case possibleDuplicate = "possible_duplicate"
    case stale
    case incompleteUpload = "incomplete_upload"
    case failed
}

enum ExternalTranscriptChunkStatus: String, Codable, Sendable {
    case staged
    case alreadyStaged = "already_staged"
    case complete
    case rejected
}

enum ExternalImportError: Error, LocalizedError, Sendable {
    case invalidProvider
    case invalidExternalID
    case invalidTitle

    var errorDescription: String? {
        switch self {
        case .invalidProvider:
            "Provider must be 1-64 characters using letters, numbers, '.', '_' or '-'."
        case .invalidExternalID:
            "External id must be 1-512 non-control characters."
        case .invalidTitle:
            "Title must not be empty."
        }
    }
}

struct ExternalRecordingIdentity: Sendable, Equatable {
    let provider: String
    let externalID: String
    let externalKey: String

    static func make(provider rawProvider: String, externalID rawExternalID: String) throws -> Self {
        let provider = rawProvider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let externalID = rawExternalID.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowedProvider = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard (1...64).contains(provider.count),
              provider.unicodeScalars.allSatisfy({ allowedProvider.contains($0) }) else {
            throw ExternalImportError.invalidProvider
        }
        guard (1...512).contains(externalID.count),
              !externalID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ExternalImportError.invalidExternalID
        }
        return Self(provider: provider, externalID: externalID, externalKey: "\(provider):\(externalID)")
    }
}

struct ExternalRecordingImportDTO: Codable, Sendable, Identifiable {
    let id: UUID
    let externalKey: String
    let provider: String
    let externalID: String
    let recordingID: UUID?
    let sourceCreatedAt: Date?
    let sourceUpdatedAt: Date
    let lastSeenAt: Date
    let lastAppliedAt: Date?
    let contentFingerprint: String?
    let lastAppliedLocalFingerprint: String?
    let disposition: ExternalImportDisposition
    let reason: String?
    let qualitySignals: [ExternalImportQualitySignal]
}

struct ExternalRecordingPreviewInput: Codable, Sendable {
    var provider: String
    var externalID: String
    var title: String
    var startDate: Date
    var duration: TimeInterval
    var calendarEventID: String?
    var sourceCreatedAt: Date?
    var sourceUpdatedAt: Date
    var transcriptCharacterCount: Int
    var transcriptSegmentCount: Int
    var hasSummary: Bool
    var actionItemCount: Int
    var transcriptFingerprint: String?
}

struct ExternalRecordingPreviewResult: Codable, Sendable {
    let provider: String
    let externalID: String
    let externalKey: String
    let status: ExternalImportPreviewStatus
    let recordingID: UUID?
    let matchedRecordingID: UUID?
    let reason: String?
    let qualitySignals: [ExternalImportQualitySignal]
}

struct ExternalTranscriptSegmentInput: Codable, Sendable {
    var startTime: TimeInterval
    var endTime: TimeInterval
    var text: String
    var speaker: String?
}

struct ExternalTranscriptInput: Codable, Sendable {
    var fullText: String
    var segments: [ExternalTranscriptSegmentInput]
    var detectedLanguage: String?
}

struct ExternalActionItemInput: Codable, Sendable {
    var assignee: String?
    var task: String
    var deadline: String?
    var isCompleted: Bool
    var priority: ActionPriority
}

struct ExternalSummaryInput: Codable, Sendable {
    var overview: String
    var keyPoints: [String]
    var actionItems: [ExternalActionItemInput]
    var decisions: [String]
    var followUps: [String]
    var yourTasks: [String]
    var language: String
}

struct ExternalRecordingUpsertInput: Codable, Sendable {
    var provider: String
    var externalID: String
    var title: String
    var startDate: Date
    var endDate: Date?
    var duration: TimeInterval
    var language: String
    var meetingApp: String?
    var meetingURL: String?
    var calendarEventID: String?
    var sourceCreatedAt: Date?
    var sourceUpdatedAt: Date
    var tags: [String]
    var transcript: ExternalTranscriptInput?
    var summary: ExternalSummaryInput?
}

struct ExternalRecordingUpsertResult: Codable, Sendable {
    let status: ExternalRecordingUpsertStatus
    let externalKey: String?
    let recordingID: UUID?
    var matchedRecordingID: UUID? = nil
    let reason: String?
    let qualitySignals: [ExternalImportQualitySignal]
}

struct ExternalImportDispositionResult: Codable, Sendable {
    let status: ExternalImportDisposition
    let externalKey: String?
    let recordingID: UUID?
    let reason: String?
}

struct ExternalTranscriptChunkInput: Codable, Sendable {
    var uploadID: UUID
    var index: Int
    var totalChunks: Int
    var text: String
    var chunkSHA256: String?
    var transcriptSHA256: String?
}

struct ExternalTranscriptChunkResult: Codable, Sendable {
    let status: ExternalTranscriptChunkStatus
    let uploadID: UUID
    let receivedChunks: Int
    let totalChunks: Int
    let receivedBytes: Int
    let reason: String?
}
