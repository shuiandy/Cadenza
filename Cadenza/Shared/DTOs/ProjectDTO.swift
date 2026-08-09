import Foundation

// Project has been merged into Folder. These DTOs support folder-level
// aggregation features (action items, decisions, AI brief/chat) that
// were previously project-only.

struct FolderDetailDTO: Codable, Sendable, Identifiable {
    let id: UUID
    var name: String
    var status: String
    var createdAt: Date
    var colorHex: String?
    var recordings: [RecordingDTO]
    var actionItems: [FolderActionItemDTO]
    var decisions: [FolderDecisionDTO]
}

struct FolderActionItemDTO: Codable, Sendable, Identifiable {
    var id: UUID { item.id }
    var item: ActionItemDTO
    var sourceRecordingID: UUID
    var sourceRecordingTitle: String
}

struct FolderDecisionDTO: Codable, Sendable, Identifiable {
    let id: UUID
    var text: String
    var sourceRecordingID: UUID
    var sourceRecordingTitle: String
}

/// Context packet for folder-scoped AI retrieval.
struct FolderContextDTO: Sendable {
    var folderName: String
    var folderStatus: String
    var totalRecordingCount: Int
    var recentMeetings: [MeetingSummaryContext]
    var openActionItems: [FolderActionItemDTO]
    var recentDecisions: [FolderDecisionDTO]
    var followUps: [FollowUpContext]
    var knownSpeakers: [String]

    struct MeetingSummaryContext: Sendable {
        var recordingID: UUID
        var title: String
        var date: Date
        var durationMinutes: Int
        var overview: String
        var keyPoints: [String]
        var actionItems: [ActionItemDTO]
        var decisions: [String]
        var followUps: [String]
    }

    struct FollowUpContext: Sendable {
        var text: String
        var sourceRecordingTitle: String
        var sourceRecordingID: UUID
    }
}
