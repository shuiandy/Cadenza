import Foundation
import SwiftData

@Model
final class ExternalRecordingImport {
    var id: UUID
    @Attribute(.unique) var externalKey: String
    var provider: String
    var externalID: String
    var sourceTitle: String
    var sourceStartDate: Date
    var sourceDuration: TimeInterval
    var sourceCalendarEventID: String?
    var sourceCreatedAt: Date?
    var sourceUpdatedAt: Date
    var lastSeenAt: Date
    var lastAppliedAt: Date?
    var contentFingerprint: String?
    var transcriptFingerprint: String?
    var lastAppliedSourceFingerprint: String?
    var lastAppliedLocalFingerprint: String?
    var disposition: String
    var reason: String?
    var qualitySignals: [String]

    @Relationship(deleteRule: .nullify)
    var recording: Recording?

    init(
        externalKey: String,
        provider: String,
        externalID: String,
        sourceTitle: String,
        sourceStartDate: Date,
        sourceDuration: TimeInterval,
        sourceCalendarEventID: String?,
        sourceCreatedAt: Date?,
        sourceUpdatedAt: Date,
        lastSeenAt: Date,
        disposition: ExternalImportDisposition,
        reason: String? = nil,
        qualitySignals: [ExternalImportQualitySignal] = []
    ) {
        self.id = UUID()
        self.externalKey = externalKey
        self.provider = provider
        self.externalID = externalID
        self.sourceTitle = sourceTitle
        self.sourceStartDate = sourceStartDate
        self.sourceDuration = sourceDuration
        self.sourceCalendarEventID = sourceCalendarEventID
        self.sourceCreatedAt = sourceCreatedAt
        self.sourceUpdatedAt = sourceUpdatedAt
        self.lastSeenAt = lastSeenAt
        self.disposition = disposition.rawValue
        self.reason = reason
        self.qualitySignals = qualitySignals.map(\.rawValue)
    }
}
