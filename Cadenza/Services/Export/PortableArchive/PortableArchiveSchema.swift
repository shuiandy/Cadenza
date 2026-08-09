import Foundation

/// Versioned entity structs for the Portable Archive (`.cadenza-archive/`).
///
/// Deliberately decoupled from app DTOs: app DTOs evolve with the UI, the
/// archive schema must stay decodable forever (spec §12.2). Bump
/// `PortableArchiveSchema.version` on any breaking shape change.
///
/// Completeness gate: `PortableArchiveRoundTripTests` rebuilds a store from
/// an archive and compares FULL model snapshots against the source store —
/// dropping a user-data field from this schema turns that test red. Fields
/// deliberately NOT archived (ephemeral/bookkeeping): lastAccessedDate,
/// processingAttempts, postProcessingBackfill*, calendarAutoLinkAttemptedAt,
/// speakerSuggestions, WebSyncRecord, ExternalRecordingImport;
/// audio and segments locations travel as archive payload files, not as
/// path strings (paths are machine-specific).
/// `calendarAutoLinkState` IS archived — `.userCleared` 是用户意图
/// （手动解除的日历关联），丢掉它会让恢复后的录音重新进入自动关联候选。
enum PortableArchiveSchema {
    static let version = 1

    /// Deterministic encoder shared by writer and validator: sorted keys +
    /// dates as epoch seconds (JSON Double, shortest round-trip form).
    ///
    /// 日期刻意用数字而非 ISO 字符串：字符串化的 format→parse **不幂等**
    /// （小数秒截断级联，每过一轮序列化可能掉 1ms —— round-trip 门禁实测抓到）。
    /// Double 经 JSON 最短表示往返在 Double 精度内无损且确定性；对外承诺的
    /// 时间精度为毫秒级（快照门禁按毫秒比较）。可读性由查看工具换算解决，
    /// 正确性不做交换。
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}

// MARK: - Entities

struct ArchiveRecording: Codable, Equatable, Sendable {
    let id: UUID
    var title: String
    var startDate: Date
    var endDate: Date?
    var duration: TimeInterval
    var meetingApp: String?
    var meetingURL: String?
    var meetingType: String?
    var linkedCalendarEventID: String?
    /// CalendarAutoLinkState rawValue；`.userCleared` 必须随档（用户意图）。
    var calendarAutoLinkState: String?
    var language: String
    var tags: [String]
    var folderID: UUID?
    var trashedDate: Date?
    var source: String?
    var createdAt: Date?
    var updatedAt: Date?
    var speakerMappings: [ArchiveSpeakerMapping]
    /// audio/<id>.m4a is present in the archive.
    var hasAudio: Bool
    /// segments/<id>/ is present (recording had no merged audio).
    var hasUnmergedSegments: Bool
    /// AudioFileOwnership rawValue (INV-18) — restore must not upgrade a
    /// file the app cannot prove it created. Additive optional: archives
    /// written before this field decode as nil (schema version stays 1).
    var audioOwnership: String?
}

struct ArchiveSpeakerMapping: Codable, Equatable, Sendable {
    var rawLabel: String
    var profileID: UUID
    var profileName: String
}

struct ArchiveTranscript: Codable, Equatable, Sendable {
    let recordingID: UUID
    var fullText: String
    var detectedLanguage: String?
    var createdAt: Date
    var segments: [ArchiveTranscriptSegment]
}

struct ArchiveTranscriptSegment: Codable, Equatable, Sendable {
    let id: UUID
    var startTime: TimeInterval
    var endTime: TimeInterval
    var text: String
    var speaker: String?
}

struct ArchiveSummary: Codable, Equatable, Sendable {
    let recordingID: UUID
    var overview: String
    var keyPoints: [String]
    var decisions: [String]
    var followUps: [String]
    var yourTasks: [String]
    var provider: String
    var model: String
    var language: String
    var createdAt: Date
    var chapters: [ArchiveChapter]
    var actionItems: [ArchiveActionItem]
}

struct ArchiveChapter: Codable, Equatable, Sendable {
    var title: String
    var startSeconds: TimeInterval
    var summary: String
}

struct ArchiveActionItem: Codable, Equatable, Sendable {
    let id: UUID
    var assignee: String?
    var task: String
    var deadline: String?
    var isCompleted: Bool
    var priority: String
    var createdAt: Date?
    var updatedAt: Date?
}

struct ArchiveFolder: Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    var parentFolderID: UUID?
    var icon: String
    var iconColor: String
    var colorHex: String?
    var status: String
    var createdAt: Date
    var sortOrder: Int
}

/// Recap sections/stats are archived as the exact JSON the model persists
/// (re-encoded deterministically) — coarse but schema-stable.
struct ArchiveRecap: Codable, Equatable, Sendable {
    let id: UUID
    var period: String
    var startDate: Date
    var endDate: Date
    var title: String
    var overview: String
    var recordingIDs: [UUID]
    var allActionItems: [String]
    var allDecisions: [String]
    var sectionsJSON: String
    var statsJSON: String
    var provider: String
    var createdAt: Date
}

/// Full AgentArtifact surface — mapped straight from the model (the app's
/// AgentArtifactDTO is a UI projection and drops fields; the archive must not).
struct ArchiveAgentArtifact: Codable, Equatable, Sendable {
    let id: UUID
    var kind: String
    var targetType: String
    var targetKey: String
    var slotKey: String
    var bodyMarkdown: String
    var provenanceSource: String
    var provenanceDetail: String
    var status: String
    var generationID: UUID?
    var generatingStartedAt: Date?
    var errorClass: String?
    var errorMessage: String?
    var lastAttemptedAt: Date?
    var retryAfter: Date?
    var targetStartDate: Date
    var targetEndDate: Date
    var targetFingerprint: String
    var contextBuiltAt: Date
    var staleReason: String?
    var createdAt: Date
    var updatedAt: Date
}

struct ArchiveSpeakerProfile: Codable, Equatable, Sendable {
    let id: UUID
    var displayName: String
    var aliases: [String]
    var notes: String
    var teamOrOrg: String?
    var createdAt: Date
    var lastSeenAt: Date?
}

/// Voice embedding sample — privacy-sensitive, only included when the user
/// explicitly opts in (spec §12.2). `embeddingData` is base64 in JSON.
struct ArchiveVoiceSample: Codable, Equatable, Sendable {
    var recordingID: UUID
    var rawLabel: String
    var profileID: UUID?
    var embeddingData: Data
    var embeddingDimension: Int
    var sampleDuration: TimeInterval
    var nonOverlapRatio: Float
    var qualityScore: Float
    var modelVersion: String
    var createdAt: Date
}

// MARK: - Manifest

struct PortableArchiveManifest: Codable, Sendable {
    var archiveSchemaVersion: Int
    var appVersion: String
    var createdAt: Date
    /// Entity name → count, for cheap integrity checks before full validation.
    var counts: [String: Int]
    var unmergedRecordingIDs: [UUID]
    var includesVoiceEmbeddings: Bool
    /// Every file in the archive except manifest.json itself; paths are
    /// archive-relative with "/" separators, sorted ascending.
    var files: [FileEntry]
    var failures: [Failure]

    struct FileEntry: Codable, Equatable, Sendable {
        var path: String
        var size: Int64
        var sha256: String
    }

    struct Failure: Codable, Equatable, Sendable {
        var recordingID: UUID?
        var reason: String
    }
}
