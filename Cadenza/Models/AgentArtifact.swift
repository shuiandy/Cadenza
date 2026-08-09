import Foundation
import SwiftData

enum AgentArtifactKind: String, Codable, Sendable { case meetingPrep }
enum ArtifactTargetType: String, Codable, Sendable { case calendarEvent }
enum ArtifactProvenanceSource: String, Codable, Sendable { case builtin, external }
enum ArtifactStatus: String, Codable, Sendable { case idle, generating, ready, failed }
enum ArtifactErrorClass: String, Codable, Sendable { case retryable, permanent }

enum ArtifactWritePolicy: Sendable {
    case external
    case builtinAutomatic
    case userBuiltinOverrideExternal
}

/// upsert 输入的值对象(struct)。永远不把 @Model 实例当 candidate。
struct ArtifactCandidate: Sendable {
    var kind: AgentArtifactKind
    var targetType: ArtifactTargetType
    var targetKey: String
    var bodyMarkdown: String
    var provenanceSource: ArtifactProvenanceSource
    var provenanceDetail: String
    var status: ArtifactStatus
    var generationID: UUID?
    var generatingStartedAt: Date?
    var errorClass: ArtifactErrorClass?
    var errorMessage: String?
    var retryAfter: Date? = nil
    var targetStartDate: Date
    var targetEndDate: Date
    var targetFingerprint: String
    var contextBuiltAt: Date
    var staleReason: String?

    var slotKey: String {
        ArtifactTargetKey.slotKey(
            kind: kind.rawValue, targetType: targetType.rawValue, targetKey: targetKey)
    }
}

@Model
final class AgentArtifact {
    var id: UUID
    var kind: String
    var targetType: String
    var targetKey: String
    @Attribute(.unique) var slotKey: String
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

    init(id: UUID = UUID(), kind: String, targetType: String, targetKey: String,
         slotKey: String, bodyMarkdown: String, provenanceSource: String,
         provenanceDetail: String, status: String, generationID: UUID? = nil,
         generatingStartedAt: Date? = nil, errorClass: String? = nil,
         errorMessage: String? = nil, lastAttemptedAt: Date? = nil,
         retryAfter: Date? = nil, targetStartDate: Date, targetEndDate: Date,
         targetFingerprint: String, contextBuiltAt: Date, staleReason: String? = nil,
         createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id; self.kind = kind; self.targetType = targetType
        self.targetKey = targetKey; self.slotKey = slotKey
        self.bodyMarkdown = bodyMarkdown; self.provenanceSource = provenanceSource
        self.provenanceDetail = provenanceDetail; self.status = status
        self.generationID = generationID; self.generatingStartedAt = generatingStartedAt
        self.errorClass = errorClass; self.errorMessage = errorMessage
        self.lastAttemptedAt = lastAttemptedAt; self.retryAfter = retryAfter
        self.targetStartDate = targetStartDate; self.targetEndDate = targetEndDate
        self.targetFingerprint = targetFingerprint; self.contextBuiltAt = contextBuiltAt
        self.staleReason = staleReason; self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}
