import Foundation

enum WebSyncAudioSourceState: String, Codable, Sendable {
    case eligible
    case localOnly = "local_only"
    case unavailable
}

struct WebSyncPayload: Codable, Sendable {
    let protocolVersion: Int
    let contentHash: String
    let title: String
    let createdAtLocal: Int64
    let durationMs: Int64
    let folder: String
    let tags: [String]
    let trashedAt: Int64?
    let audioSourceState: WebSyncAudioSourceState
    let transcript: WebSyncTranscript?
    let summary: WebSyncSummary?
    let calendarEvent: WebSyncCalendarEvent?

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case contentHash = "content_hash"
        case title
        case createdAtLocal = "created_at_local"
        case durationMs = "duration_ms"
        case folder
        case tags
        case trashedAt = "trashed_at"
        case audioSourceState = "audio_source_state"
        case transcript
        case summary
        case calendarEvent = "calendar_event"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(contentHash, forKey: .contentHash)
        try container.encode(title, forKey: .title)
        try container.encode(createdAtLocal, forKey: .createdAtLocal)
        try container.encode(durationMs, forKey: .durationMs)
        try container.encode(folder, forKey: .folder)
        try container.encode(tags, forKey: .tags)
        if let trashedAt { try container.encode(trashedAt, forKey: .trashedAt) }
        else { try container.encodeNil(forKey: .trashedAt) }
        try container.encode(audioSourceState, forKey: .audioSourceState)
        if let transcript { try container.encode(transcript, forKey: .transcript) }
        else { try container.encodeNil(forKey: .transcript) }
        if let summary { try container.encode(summary, forKey: .summary) }
        else { try container.encodeNil(forKey: .summary) }
        if let calendarEvent { try container.encode(calendarEvent, forKey: .calendarEvent) }
        else { try container.encodeNil(forKey: .calendarEvent) }
    }
}

struct WebSyncTranscript: Codable, Sendable {
    let version: Int
    let fullText: String
    let detectedLanguage: String
    let segments: [WebSyncTranscriptSegment]

    enum CodingKeys: String, CodingKey {
        case version
        case fullText = "full_text"
        case detectedLanguage = "detected_language"
        case segments
    }
}

struct WebSyncTranscriptSegment: Codable, Sendable {
    let id: String
    let startMs: Int64
    let endMs: Int64
    let text: String
    let speaker: String

    enum CodingKeys: String, CodingKey {
        case id
        case startMs = "start_ms"
        case endMs = "end_ms"
        case text
        case speaker
    }
}

struct WebSyncSummary: Codable, Sendable {
    let format: String
    let markdown: String
    /// The summary before `summaryMarkdown` flattened it.
    ///
    /// The markdown is a rendering: sections joined under fixed headings, action
    /// items spelled as checkbox lines, chapter timestamps formatted into their
    /// titles. A client that shows those as separate surfaces would otherwise
    /// have to parse that rendering back apart, and would break the next time a
    /// heading here is reworded.
    let structured: WebSyncStructuredSummary?
}

/// `SummaryDTO` minus the fields that only describe how it was produced.
struct WebSyncStructuredSummary: Codable, Sendable {
    let overview: String
    let keyPoints: [String]
    let decisions: [String]
    let actionItems: [WebSyncActionItem]
    let yourTasks: [String]
    let followUps: [String]
    let chapters: [WebSyncChapter]
    let language: String

    enum CodingKeys: String, CodingKey {
        case overview
        case keyPoints = "key_points"
        case decisions
        case actionItems = "action_items"
        case yourTasks = "your_tasks"
        case followUps = "follow_ups"
        case chapters
        case language
    }
}

struct WebSyncActionItem: Codable, Sendable {
    let id: String
    let task: String
    let assignee: String
    let deadline: String
    let completed: Bool
    let priority: String
}

struct WebSyncChapter: Codable, Sendable {
    let title: String
    let startSeconds: Double
    let summary: String

    enum CodingKeys: String, CodingKey {
        case title
        case startSeconds = "start_seconds"
        case summary
    }
}

/// The meeting a recording was made for.
///
/// Three fields on purpose. `MeetingEventDTO` also carries attendees, organizer
/// addresses, calendar identifiers and colors; naming the meeting on a web
/// recording page needs none of it, and syncing it would widen what the server
/// knows about the user's calendar for nothing they would see.
struct WebSyncCalendarEvent: Codable, Sendable {
    let title: String
    let startAt: Int64
    let endAt: Int64

    enum CodingKeys: String, CodingKey {
        case title
        case startAt = "start_at"
        case endAt = "end_at"
    }
}

struct BuiltWebSyncPayload: Sendable {
    let encodedData: Data
    let contentHash: String

#if DEBUG
    /// Test-only inspection without retaining a second transcript/summary
    /// object graph across the detached-builder boundary.
    var payload: WebSyncPayload {
        try! JSONDecoder().decode(WebSyncPayload.self, from: encodedData)
    }
#endif
}
