// Cadenza/Services/AI/AIContextPacket.swift
import Foundation

// MARK: - Output

struct AIContextPacket: Sendable {
    let systemPrompt: String
    /// Multi-turn conversation. Last entry MUST have role == .user (the current question).
    /// An optional explicitly untrusted meeting-data message is prepended before prior chat turns.
    let messages: [ChatMessage]
    let metadata: ContextMetadata
    /// Concrete recording scope selected for this turn, when retrieval
    /// resolved an explicit or relative recording selector.
    let resolvedRecordingIDs: [UUID]
}

struct ContextMetadata: Sendable {
    let recordingCount: Int
    let dateRange: (start: Date, end: Date)?
    let speakerCount: Int
}

// MARK: - Store Data

/// How `fetchAIContext` treats a multi-name `speakerQueries` list when picking
/// recordings. The two callers genuinely want opposite things, so the mode is
/// explicit rather than inferred from another flag:
/// - Chat disambiguates "what did Andy and Caleb discuss *together*" and needs
///   every named speaker present in the same recording (`.all`, the default so
///   existing callers keep their behavior).
/// - Meeting prep gathers history with *any* of a meeting's attendees; requiring
///   co-occurrence would empty the brief for every 3+ person meeting, since those
///   people have usually never all been in one past recording (`.any`).
enum SpeakerMatchMode: Sendable {
    case all
    case any
}

struct AIContextData: Sendable {
    enum TranscriptCoverage: Sendable, Equatable {
        case excerpts
        case complete
    }

    struct RecordingSummary: Sendable {
        let recordingID: UUID
        let title: String
        let startDate: Date
        let duration: TimeInterval
        let summary: String?
        let meetingType: String?
    }

    struct ActionItem: Sendable {
        let recordingID: UUID
        let recordingTitle: String
        let text: String
        let isCompleted: Bool
        let assignee: String?
        let deadline: String?       // Raw string from model (e.g. "Friday", "next sprint", ISO date)
        let priority: String?
    }

    struct Decision: Sendable {
        let recordingID: UUID
        let recordingTitle: String
        let text: String
    }

    struct TranscriptExcerpt: Sendable {
        let recordingID: UUID
        let recordingTitle: String
        let startTime: TimeInterval
        let rawSpeaker: String?
        let resolvedSpeakerName: String?
        let text: String
    }

    struct SpeakerInfo: Sendable {
        let name: String
        let aliases: [String]
        let recordingCount: Int
    }

    let summaries: [RecordingSummary]
    let actionItems: [ActionItem]
    let decisions: [Decision]
    let followUps: [Decision]
    let transcriptExcerpts: [TranscriptExcerpt]
    let transcriptCoverage: TranscriptCoverage
    let speakers: [SpeakerInfo]
}

struct SpeakerNameInfo: Sendable {
    let displayName: String
    let aliases: [String]
}
