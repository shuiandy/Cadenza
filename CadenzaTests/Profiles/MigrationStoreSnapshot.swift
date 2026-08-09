import Foundation
import SwiftData
import Testing

@testable import Cadenza

/// Full-graph store snapshot for migration verification, independent of
/// the migration code and of the archive schema: every entity type and
/// every user-data field, with path columns and ownership taken in RAW
/// storage form (never through the resolver). Rows are typed Equatable
/// structs — no delimiter-joined strings, so field values containing
/// separators can never collide. Cross-row ordering uses UTF-8 code-unit
/// comparison (canonical-equivalence-blind) and floating-point fields are
/// held as bit patterns, making both equality and order total and
/// byte-stable. Stored arrays (segments, mappings, suggestions, action
/// items) keep their persisted order — order is data.
struct MigrationStoreSnapshot: Equatable {

    /// String wrapper whose equality is raw UTF-8 code units. Swift's
    /// String == follows Unicode canonical equivalence, which would make
    /// an NFC source and an NFD product compare equal despite different
    /// stored bytes.
    struct RawString: Equatable, Sendable {
        var string: String

        init(_ string: String) {
            self.string = string
        }

        static func == (lhs: RawString, rhs: RawString) -> Bool {
            lhs.string.utf8.elementsEqual(rhs.string.utf8)
        }
    }

    struct MappingRow: Equatable {
        var rawLabel: RawString
        var profileID: UUID

        init(
            rawLabel: String,
            profileID: UUID
        ) {
            self.rawLabel = RawString(rawLabel)
            self.profileID = profileID
        }
    }

    struct SuggestionRow: Equatable {
        var rawLabel: RawString
        var profileID: UUID
        var scoreBits: UInt32
        var strategy: RawString
        var modelVersion: RawString
        var generatedAtBits: UInt64

        init(
            rawLabel: String,
            profileID: UUID,
            scoreBits: UInt32,
            strategy: String,
            modelVersion: String,
            generatedAtBits: UInt64
        ) {
            self.rawLabel = RawString(rawLabel)
            self.profileID = profileID
            self.scoreBits = scoreBits
            self.strategy = RawString(strategy)
            self.modelVersion = RawString(modelVersion)
            self.generatedAtBits = generatedAtBits
        }
    }

    struct SegmentRow: Equatable {
        var id: UUID
        var startTimeBits: UInt64
        var endTimeBits: UInt64
        var text: RawString
        var speaker: RawString?

        init(
            id: UUID,
            startTimeBits: UInt64,
            endTimeBits: UInt64,
            text: String,
            speaker: String?
        ) {
            self.id = id
            self.startTimeBits = startTimeBits
            self.endTimeBits = endTimeBits
            self.text = RawString(text)
            self.speaker = speaker.map(RawString.init)
        }
    }

    struct ActionItemRow: Equatable {
        var id: UUID
        var assignee: RawString?
        var task: RawString
        var deadline: RawString?
        var isCompleted: Bool
        var priority: RawString
        var createdAtBits: UInt64?
        var updatedAtBits: UInt64?

        init(
            id: UUID,
            assignee: String?,
            task: String,
            deadline: String?,
            isCompleted: Bool,
            priority: String,
            createdAtBits: UInt64?,
            updatedAtBits: UInt64?
        ) {
            self.id = id
            self.assignee = assignee.map(RawString.init)
            self.task = RawString(task)
            self.deadline = deadline.map(RawString.init)
            self.isCompleted = isCompleted
            self.priority = RawString(priority)
            self.createdAtBits = createdAtBits
            self.updatedAtBits = updatedAtBits
        }
    }

    struct TranscriptRow: Equatable {
        var id: UUID
        var fullText: RawString
        var detectedLanguage: RawString?
        var createdAtBits: UInt64
        var segments: [SegmentRow]

        init(
            id: UUID,
            fullText: String,
            detectedLanguage: String?,
            createdAtBits: UInt64,
            segments: [SegmentRow]
        ) {
            self.id = id
            self.fullText = RawString(fullText)
            self.detectedLanguage = detectedLanguage.map(RawString.init)
            self.createdAtBits = createdAtBits
            self.segments = segments
        }
    }

    struct SummaryRow: Equatable {
        var id: UUID
        var overview: RawString
        var keyPoints: [RawString]
        var decisions: [RawString]
        var followUps: [RawString]
        var yourTasks: [RawString]
        var provider: RawString
        var model: RawString
        var language: RawString
        var createdAtBits: UInt64
        var chaptersJSON: RawString?
        var actionItems: [ActionItemRow]

        init(
            id: UUID,
            overview: String,
            keyPoints: [String],
            decisions: [String],
            followUps: [String],
            yourTasks: [String],
            provider: String,
            model: String,
            language: String,
            createdAtBits: UInt64,
            chaptersJSON: String?,
            actionItems: [ActionItemRow]
        ) {
            self.id = id
            self.overview = RawString(overview)
            self.keyPoints = keyPoints.map(RawString.init)
            self.decisions = decisions.map(RawString.init)
            self.followUps = followUps.map(RawString.init)
            self.yourTasks = yourTasks.map(RawString.init)
            self.provider = RawString(provider)
            self.model = RawString(model)
            self.language = RawString(language)
            self.createdAtBits = createdAtBits
            self.chaptersJSON = chaptersJSON.map(RawString.init)
            self.actionItems = actionItems
        }
    }

    struct RecordingRow: Equatable {
        var id: UUID
        var title: RawString
        var startDateBits: UInt64
        var createdAtBits: UInt64?
        var updatedAtBits: UInt64?
        var source: RawString?
        var endDateBits: UInt64?
        var durationBits: UInt64
        var audioFilePath: RawString?
        var meetingApp: RawString?
        var meetingURL: RawString?
        var language: RawString
        var tags: [RawString]
        var meetingType: RawString?
        var lastAccessedDateBits: UInt64?
        var trashedDateBits: UInt64?
        var audioSegmentsDirectory: RawString?
        var linkedCalendarEventID: RawString?
        var speakerMappings: [MappingRow]
        var speakerSuggestions: [SuggestionRow]?
        var processingAttempts: Int
        var postProcessingBackfillState: RawString?
        var postProcessingBackfillRequestedAtBits: UInt64?
        var postProcessingBackfillLastAttemptAtBits: UInt64?
        var postProcessingBackfillNextAttemptAtBits: UInt64?
        var postProcessingBackfillFailureCount: Int
        var postProcessingBackfillLastError: RawString?
        var calendarAutoLinkState: RawString?
        var calendarAutoLinkAttemptedAtBits: UInt64?
        var audioFileOwnership: RawString?
        var folderID: UUID?
        var transcript: TranscriptRow?
        var summary: SummaryRow?

        init(
            id: UUID,
            title: String,
            startDateBits: UInt64,
            createdAtBits: UInt64?,
            updatedAtBits: UInt64?,
            source: String?,
            endDateBits: UInt64?,
            durationBits: UInt64,
            audioFilePath: String?,
            meetingApp: String?,
            meetingURL: String?,
            language: String,
            tags: [String],
            meetingType: String?,
            lastAccessedDateBits: UInt64?,
            trashedDateBits: UInt64?,
            audioSegmentsDirectory: String?,
            linkedCalendarEventID: String?,
            speakerMappings: [MappingRow],
            speakerSuggestions: [SuggestionRow]?,
            processingAttempts: Int,
            postProcessingBackfillState: String?,
            postProcessingBackfillRequestedAtBits: UInt64?,
            postProcessingBackfillLastAttemptAtBits: UInt64?,
            postProcessingBackfillNextAttemptAtBits: UInt64?,
            postProcessingBackfillFailureCount: Int,
            postProcessingBackfillLastError: String?,
            calendarAutoLinkState: String?,
            calendarAutoLinkAttemptedAtBits: UInt64?,
            audioFileOwnership: String?,
            folderID: UUID?,
            transcript: TranscriptRow?,
            summary: SummaryRow?
        ) {
            self.id = id
            self.title = RawString(title)
            self.startDateBits = startDateBits
            self.createdAtBits = createdAtBits
            self.updatedAtBits = updatedAtBits
            self.source = source.map(RawString.init)
            self.endDateBits = endDateBits
            self.durationBits = durationBits
            self.audioFilePath = audioFilePath.map(RawString.init)
            self.meetingApp = meetingApp.map(RawString.init)
            self.meetingURL = meetingURL.map(RawString.init)
            self.language = RawString(language)
            self.tags = tags.map(RawString.init)
            self.meetingType = meetingType.map(RawString.init)
            self.lastAccessedDateBits = lastAccessedDateBits
            self.trashedDateBits = trashedDateBits
            self.audioSegmentsDirectory = audioSegmentsDirectory.map(RawString.init)
            self.linkedCalendarEventID = linkedCalendarEventID.map(RawString.init)
            self.speakerMappings = speakerMappings
            self.speakerSuggestions = speakerSuggestions
            self.processingAttempts = processingAttempts
            self.postProcessingBackfillState = postProcessingBackfillState.map(RawString.init)
            self.postProcessingBackfillRequestedAtBits = postProcessingBackfillRequestedAtBits
            self.postProcessingBackfillLastAttemptAtBits = postProcessingBackfillLastAttemptAtBits
            self.postProcessingBackfillNextAttemptAtBits = postProcessingBackfillNextAttemptAtBits
            self.postProcessingBackfillFailureCount = postProcessingBackfillFailureCount
            self.postProcessingBackfillLastError = postProcessingBackfillLastError.map(RawString.init)
            self.calendarAutoLinkState = calendarAutoLinkState.map(RawString.init)
            self.calendarAutoLinkAttemptedAtBits = calendarAutoLinkAttemptedAtBits
            self.audioFileOwnership = audioFileOwnership.map(RawString.init)
            self.folderID = folderID
            self.transcript = transcript
            self.summary = summary
        }
    }

    struct FolderRow: Equatable {
        var id: UUID
        var name: RawString
        var icon: RawString
        var iconColor: RawString
        var colorHex: RawString?
        var status: RawString
        var createdAtBits: UInt64
        var sortOrder: Int
        var parentFolderID: UUID?

        init(
            id: UUID,
            name: String,
            icon: String,
            iconColor: String,
            colorHex: String?,
            status: String,
            createdAtBits: UInt64,
            sortOrder: Int,
            parentFolderID: UUID?
        ) {
            self.id = id
            self.name = RawString(name)
            self.icon = RawString(icon)
            self.iconColor = RawString(iconColor)
            self.colorHex = colorHex.map(RawString.init)
            self.status = RawString(status)
            self.createdAtBits = createdAtBits
            self.sortOrder = sortOrder
            self.parentFolderID = parentFolderID
        }
    }

    struct ExternalImportRow: Equatable {
        var id: UUID
        var externalKey: RawString
        var provider: RawString
        var externalID: RawString
        var sourceTitle: RawString
        var sourceStartDateBits: UInt64
        var sourceDurationBits: UInt64
        var sourceCalendarEventID: RawString?
        var sourceCreatedAtBits: UInt64?
        var sourceUpdatedAtBits: UInt64
        var lastSeenAtBits: UInt64
        var lastAppliedAtBits: UInt64?
        var contentFingerprint: RawString?
        var transcriptFingerprint: RawString?
        var lastAppliedSourceFingerprint: RawString?
        var lastAppliedLocalFingerprint: RawString?
        var disposition: RawString
        var reason: RawString?
        var qualitySignals: [RawString]
        var recordingID: UUID?

        init(
            id: UUID,
            externalKey: String,
            provider: String,
            externalID: String,
            sourceTitle: String,
            sourceStartDateBits: UInt64,
            sourceDurationBits: UInt64,
            sourceCalendarEventID: String?,
            sourceCreatedAtBits: UInt64?,
            sourceUpdatedAtBits: UInt64,
            lastSeenAtBits: UInt64,
            lastAppliedAtBits: UInt64?,
            contentFingerprint: String?,
            transcriptFingerprint: String?,
            lastAppliedSourceFingerprint: String?,
            lastAppliedLocalFingerprint: String?,
            disposition: String,
            reason: String?,
            qualitySignals: [String],
            recordingID: UUID?
        ) {
            self.id = id
            self.externalKey = RawString(externalKey)
            self.provider = RawString(provider)
            self.externalID = RawString(externalID)
            self.sourceTitle = RawString(sourceTitle)
            self.sourceStartDateBits = sourceStartDateBits
            self.sourceDurationBits = sourceDurationBits
            self.sourceCalendarEventID = sourceCalendarEventID.map(RawString.init)
            self.sourceCreatedAtBits = sourceCreatedAtBits
            self.sourceUpdatedAtBits = sourceUpdatedAtBits
            self.lastSeenAtBits = lastSeenAtBits
            self.lastAppliedAtBits = lastAppliedAtBits
            self.contentFingerprint = contentFingerprint.map(RawString.init)
            self.transcriptFingerprint = transcriptFingerprint.map(RawString.init)
            self.lastAppliedSourceFingerprint = lastAppliedSourceFingerprint.map(RawString.init)
            self.lastAppliedLocalFingerprint = lastAppliedLocalFingerprint.map(RawString.init)
            self.disposition = RawString(disposition)
            self.reason = reason.map(RawString.init)
            self.qualitySignals = qualitySignals.map(RawString.init)
            self.recordingID = recordingID
        }
    }

    struct SpeakerProfileRow: Equatable {
        var id: UUID
        var displayName: RawString
        var aliases: [RawString]
        var notes: RawString
        var teamOrOrg: RawString?
        var createdAtBits: UInt64
        var lastSeenAtBits: UInt64?

        init(
            id: UUID,
            displayName: String,
            aliases: [String],
            notes: String,
            teamOrOrg: String?,
            createdAtBits: UInt64,
            lastSeenAtBits: UInt64?
        ) {
            self.id = id
            self.displayName = RawString(displayName)
            self.aliases = aliases.map(RawString.init)
            self.notes = RawString(notes)
            self.teamOrOrg = teamOrOrg.map(RawString.init)
            self.createdAtBits = createdAtBits
            self.lastSeenAtBits = lastSeenAtBits
        }
    }

    struct VoiceSampleRow: Equatable {
        var recordingID: UUID
        var rawLabel: RawString
        var profileID: UUID?
        var embeddingData: Data
        var embeddingDimension: Int
        var sampleDurationBits: UInt64
        var nonOverlapRatioBits: UInt32
        var qualityScoreBits: UInt32
        var modelVersion: RawString
        var createdAtBits: UInt64

        init(
            recordingID: UUID,
            rawLabel: String,
            profileID: UUID?,
            embeddingData: Data,
            embeddingDimension: Int,
            sampleDurationBits: UInt64,
            nonOverlapRatioBits: UInt32,
            qualityScoreBits: UInt32,
            modelVersion: String,
            createdAtBits: UInt64
        ) {
            self.recordingID = recordingID
            self.rawLabel = RawString(rawLabel)
            self.profileID = profileID
            self.embeddingData = embeddingData
            self.embeddingDimension = embeddingDimension
            self.sampleDurationBits = sampleDurationBits
            self.nonOverlapRatioBits = nonOverlapRatioBits
            self.qualityScoreBits = qualityScoreBits
            self.modelVersion = RawString(modelVersion)
            self.createdAtBits = createdAtBits
        }
    }

    struct RecapRow: Equatable {
        var id: UUID
        var period: RawString
        var startDateBits: UInt64
        var endDateBits: UInt64
        var title: RawString
        var overview: RawString
        var sectionsJSON: Data
        var statsJSON: Data
        var recordingIDs: [UUID]
        var allActionItems: [RawString]
        var allDecisions: [RawString]
        var provider: RawString
        var createdAtBits: UInt64

        init(
            id: UUID,
            period: String,
            startDateBits: UInt64,
            endDateBits: UInt64,
            title: String,
            overview: String,
            sectionsJSON: Data,
            statsJSON: Data,
            recordingIDs: [UUID],
            allActionItems: [String],
            allDecisions: [String],
            provider: String,
            createdAtBits: UInt64
        ) {
            self.id = id
            self.period = RawString(period)
            self.startDateBits = startDateBits
            self.endDateBits = endDateBits
            self.title = RawString(title)
            self.overview = RawString(overview)
            self.sectionsJSON = sectionsJSON
            self.statsJSON = statsJSON
            self.recordingIDs = recordingIDs
            self.allActionItems = allActionItems.map(RawString.init)
            self.allDecisions = allDecisions.map(RawString.init)
            self.provider = RawString(provider)
            self.createdAtBits = createdAtBits
        }
    }

    struct ArtifactRow: Equatable {
        var id: UUID
        var kind: RawString
        var targetType: RawString
        var targetKey: RawString
        var slotKey: RawString
        var bodyMarkdown: RawString
        var provenanceSource: RawString
        var provenanceDetail: RawString
        var status: RawString
        var generationID: UUID?
        var generatingStartedAtBits: UInt64?
        var errorClass: RawString?
        var errorMessage: RawString?
        var lastAttemptedAtBits: UInt64?
        var retryAfterBits: UInt64?
        var targetStartDateBits: UInt64
        var targetEndDateBits: UInt64
        var targetFingerprint: RawString
        var contextBuiltAtBits: UInt64
        var staleReason: RawString?
        var createdAtBits: UInt64
        var updatedAtBits: UInt64

        init(
            id: UUID,
            kind: String,
            targetType: String,
            targetKey: String,
            slotKey: String,
            bodyMarkdown: String,
            provenanceSource: String,
            provenanceDetail: String,
            status: String,
            generationID: UUID?,
            generatingStartedAtBits: UInt64?,
            errorClass: String?,
            errorMessage: String?,
            lastAttemptedAtBits: UInt64?,
            retryAfterBits: UInt64?,
            targetStartDateBits: UInt64,
            targetEndDateBits: UInt64,
            targetFingerprint: String,
            contextBuiltAtBits: UInt64,
            staleReason: String?,
            createdAtBits: UInt64,
            updatedAtBits: UInt64
        ) {
            self.id = id
            self.kind = RawString(kind)
            self.targetType = RawString(targetType)
            self.targetKey = RawString(targetKey)
            self.slotKey = RawString(slotKey)
            self.bodyMarkdown = RawString(bodyMarkdown)
            self.provenanceSource = RawString(provenanceSource)
            self.provenanceDetail = RawString(provenanceDetail)
            self.status = RawString(status)
            self.generationID = generationID
            self.generatingStartedAtBits = generatingStartedAtBits
            self.errorClass = errorClass.map(RawString.init)
            self.errorMessage = errorMessage.map(RawString.init)
            self.lastAttemptedAtBits = lastAttemptedAtBits
            self.retryAfterBits = retryAfterBits
            self.targetStartDateBits = targetStartDateBits
            self.targetEndDateBits = targetEndDateBits
            self.targetFingerprint = RawString(targetFingerprint)
            self.contextBuiltAtBits = contextBuiltAtBits
            self.staleReason = staleReason.map(RawString.init)
            self.createdAtBits = createdAtBits
            self.updatedAtBits = updatedAtBits
        }
    }

    struct WebSyncRow: Equatable {
        var syncKey: RawString
        var userID: RawString
        var recordingID: UUID
        var remoteRecordingID: RawString?
        var structuredState: RawString
        var structuredHash: RawString?
        var audioState: RawString
        var audioFingerprint: RawString?
        var uploadSessionID: RawString?
        var attemptCount: Int
        var nextAttemptAtBits: UInt64?
        var lastErrorCode: RawString?
        var lastAttemptAtBits: UInt64?
        var syncedAtBits: UInt64?
        var isDeletionTombstone: Bool

        init(
            syncKey: String,
            userID: String,
            recordingID: UUID,
            remoteRecordingID: String?,
            structuredState: String,
            structuredHash: String?,
            audioState: String,
            audioFingerprint: String?,
            uploadSessionID: String?,
            attemptCount: Int,
            nextAttemptAtBits: UInt64?,
            lastErrorCode: String?,
            lastAttemptAtBits: UInt64?,
            syncedAtBits: UInt64?,
            isDeletionTombstone: Bool
        ) {
            self.syncKey = RawString(syncKey)
            self.userID = RawString(userID)
            self.recordingID = recordingID
            self.remoteRecordingID = remoteRecordingID.map(RawString.init)
            self.structuredState = RawString(structuredState)
            self.structuredHash = structuredHash.map(RawString.init)
            self.audioState = RawString(audioState)
            self.audioFingerprint = audioFingerprint.map(RawString.init)
            self.uploadSessionID = uploadSessionID.map(RawString.init)
            self.attemptCount = attemptCount
            self.nextAttemptAtBits = nextAttemptAtBits
            self.lastErrorCode = lastErrorCode.map(RawString.init)
            self.lastAttemptAtBits = lastAttemptAtBits
            self.syncedAtBits = syncedAtBits
            self.isDeletionTombstone = isDeletionTombstone
        }
    }

    var recordings: [RecordingRow]
    var folders: [FolderRow]
    var externalImports: [ExternalImportRow]
    var speakerProfiles: [SpeakerProfileRow]
    var voiceSamples: [VoiceSampleRow]
    var recaps: [RecapRow]
    var artifacts: [ArtifactRow]
    var webSyncRecords: [WebSyncRow]

    // MARK: - Value helpers

    private static func bits(_ date: Date) -> UInt64 {
        date.timeIntervalSince1970.bitPattern
    }

    private static func bits(_ date: Date?) -> UInt64? {
        date.map { $0.timeIntervalSince1970.bitPattern }
    }

    private static func bits(_ value: Double) -> UInt64 {
        value.bitPattern
    }

    private static func bits(_ value: Float) -> UInt32 {
        value.bitPattern
    }

    /// Raw UTF-8 code-unit order: Swift's String comparison follows Unicode
    /// canonical equivalence, which would let NFC/NFD spellings leak
    /// SwiftData's undefined fetch order into the snapshot.
    private static func utf8Less(_ a: String, _ b: String) -> Bool {
        a.utf8.lexicographicallyPrecedes(b.utf8)
    }

    private static func utf8Equal(_ a: String, _ b: String) -> Bool {
        a.utf8.elementsEqual(b.utf8)
    }

    // MARK: - Capture

    @MainActor
    static func capture(storeURL: URL) throws -> MigrationStoreSnapshot {
        let container = try ModelContainer(
            for: RecordingsStore.schema,
            configurations: ModelConfiguration(url: storeURL, allowsSave: false)
        )
        return try capture(container: container)
    }

    @MainActor
    static func capture(container: ModelContainer) throws -> MigrationStoreSnapshot {
        let context = ModelContext(container)

        let recordings = try context.fetch(FetchDescriptor<Recording>()).map { r in
            RecordingRow(
                id: r.id, title: r.title, startDateBits: bits(r.startDate),
                createdAtBits: bits(r.createdAt), updatedAtBits: bits(r.updatedAt),
                source: r.source, endDateBits: bits(r.endDate),
                durationBits: bits(r.duration),
                audioFilePath: r.audioFilePath,
                meetingApp: r.meetingApp, meetingURL: r.meetingURL,
                language: r.language, tags: r.tags, meetingType: r.meetingType,
                lastAccessedDateBits: bits(r.lastAccessedDate),
                trashedDateBits: bits(r.trashedDate),
                audioSegmentsDirectory: r.audioSegmentsDirectory,
                linkedCalendarEventID: r.linkedCalendarEventID,
                speakerMappings: (r.speakerMappings ?? []).map {
                    MappingRow(rawLabel: $0.rawLabel, profileID: $0.profileID)
                },
                speakerSuggestions: r.speakerSuggestions.map { suggestions in
                    suggestions.map {
                        SuggestionRow(
                            rawLabel: $0.rawLabel, profileID: $0.profileID,
                            scoreBits: bits($0.score), strategy: $0.strategy,
                            modelVersion: $0.modelVersion,
                            generatedAtBits: bits($0.generatedAt)
                        )
                    }
                },
                processingAttempts: r.processingAttempts,
                postProcessingBackfillState: r.postProcessingBackfillState,
                postProcessingBackfillRequestedAtBits: bits(r.postProcessingBackfillRequestedAt),
                postProcessingBackfillLastAttemptAtBits: bits(r.postProcessingBackfillLastAttemptAt),
                postProcessingBackfillNextAttemptAtBits: bits(r.postProcessingBackfillNextAttemptAt),
                postProcessingBackfillFailureCount: r.postProcessingBackfillFailureCount,
                postProcessingBackfillLastError: r.postProcessingBackfillLastError,
                calendarAutoLinkState: r.calendarAutoLinkState,
                calendarAutoLinkAttemptedAtBits: bits(r.calendarAutoLinkAttemptedAt),
                audioFileOwnership: r.audioFileOwnership,
                folderID: r.folder?.id,
                transcript: r.transcript.map { t in
                    TranscriptRow(
                        id: t.id, fullText: t.fullText,
                        detectedLanguage: t.detectedLanguage,
                        createdAtBits: bits(t.createdAt),
                        segments: t.segments.map {
                            SegmentRow(
                                id: $0.id, startTimeBits: bits($0.startTime),
                                endTimeBits: bits($0.endTime),
                                text: $0.text, speaker: $0.speaker
                            )
                        }
                    )
                },
                summary: r.summary.map { s in
                    SummaryRow(
                        id: s.id, overview: s.overview, keyPoints: s.keyPoints,
                        decisions: s.decisions, followUps: s.followUps,
                        yourTasks: s.yourTasks, provider: s.provider, model: s.model,
                        language: s.language, createdAtBits: bits(s.createdAt),
                        chaptersJSON: s.chaptersJSON,
                        actionItems: s.actionItems.map {
                            ActionItemRow(
                                id: $0.id, assignee: $0.assignee, task: $0.task,
                                deadline: $0.deadline, isCompleted: $0.isCompleted,
                                priority: $0.priority.rawValue,
                                createdAtBits: bits($0.createdAt),
                                updatedAtBits: bits($0.updatedAt)
                            )
                        }
                    )
                }
            )
        }.sorted { utf8Less($0.id.uuidString, $1.id.uuidString) }

        let folders = try context.fetch(FetchDescriptor<Folder>()).map {
            FolderRow(
                id: $0.id, name: $0.name, icon: $0.icon, iconColor: $0.iconColor,
                colorHex: $0.colorHex, status: $0.status, createdAtBits: bits($0.createdAt),
                sortOrder: $0.sortOrder, parentFolderID: $0.parentFolder?.id
            )
        }.sorted { utf8Less($0.id.uuidString, $1.id.uuidString) }

        let externalImports = try context.fetch(FetchDescriptor<ExternalRecordingImport>()).map {
            ExternalImportRow(
                id: $0.id, externalKey: $0.externalKey, provider: $0.provider,
                externalID: $0.externalID, sourceTitle: $0.sourceTitle,
                sourceStartDateBits: bits($0.sourceStartDate),
                sourceDurationBits: bits($0.sourceDuration),
                sourceCalendarEventID: $0.sourceCalendarEventID,
                sourceCreatedAtBits: bits($0.sourceCreatedAt),
                sourceUpdatedAtBits: bits($0.sourceUpdatedAt),
                lastSeenAtBits: bits($0.lastSeenAt),
                lastAppliedAtBits: bits($0.lastAppliedAt),
                contentFingerprint: $0.contentFingerprint,
                transcriptFingerprint: $0.transcriptFingerprint,
                lastAppliedSourceFingerprint: $0.lastAppliedSourceFingerprint,
                lastAppliedLocalFingerprint: $0.lastAppliedLocalFingerprint,
                disposition: $0.disposition, reason: $0.reason,
                qualitySignals: $0.qualitySignals, recordingID: $0.recording?.id
            )
        }.sorted { utf8Less($0.externalKey.string, $1.externalKey.string) }

        let speakerProfiles = try context.fetch(FetchDescriptor<SpeakerProfile>()).map {
            SpeakerProfileRow(
                id: $0.id, displayName: $0.displayName, aliases: $0.aliases, notes: $0.notes,
                teamOrOrg: $0.teamOrOrg, createdAtBits: bits($0.createdAt),
                lastSeenAtBits: bits($0.lastSeenAt)
            )
        }.sorted { utf8Less($0.id.uuidString, $1.id.uuidString) }

        let voiceSamples = try context.fetch(FetchDescriptor<SpeakerVoiceSample>()).map {
            VoiceSampleRow(
                recordingID: $0.recordingID, rawLabel: $0.rawLabel, profileID: $0.profile?.id,
                embeddingData: $0.embeddingData, embeddingDimension: $0.embeddingDimension,
                sampleDurationBits: bits($0.sampleDuration),
                nonOverlapRatioBits: bits($0.nonOverlapRatio),
                qualityScoreBits: bits($0.qualityScore),
                modelVersion: $0.modelVersion,
                createdAtBits: bits($0.createdAt)
            )
        }.sorted(by: voiceSampleTotalOrder)

        let recaps = try context.fetch(FetchDescriptor<Recap>()).map {
            RecapRow(
                id: $0.id, period: $0.period, startDateBits: bits($0.startDate),
                endDateBits: bits($0.endDate), title: $0.title, overview: $0.overview,
                sectionsJSON: $0.sectionsJSON, statsJSON: $0.statsJSON,
                recordingIDs: $0.recordingIDs, allActionItems: $0.allActionItems,
                allDecisions: $0.allDecisions, provider: $0.provider,
                createdAtBits: bits($0.createdAt)
            )
        }.sorted { utf8Less($0.id.uuidString, $1.id.uuidString) }

        let artifacts = try context.fetch(FetchDescriptor<AgentArtifact>()).map {
            ArtifactRow(
                id: $0.id, kind: $0.kind, targetType: $0.targetType, targetKey: $0.targetKey,
                slotKey: $0.slotKey, bodyMarkdown: $0.bodyMarkdown,
                provenanceSource: $0.provenanceSource, provenanceDetail: $0.provenanceDetail,
                status: $0.status, generationID: $0.generationID,
                generatingStartedAtBits: bits($0.generatingStartedAt), errorClass: $0.errorClass,
                errorMessage: $0.errorMessage, lastAttemptedAtBits: bits($0.lastAttemptedAt),
                retryAfterBits: bits($0.retryAfter),
                targetStartDateBits: bits($0.targetStartDate),
                targetEndDateBits: bits($0.targetEndDate),
                targetFingerprint: $0.targetFingerprint,
                contextBuiltAtBits: bits($0.contextBuiltAt), staleReason: $0.staleReason,
                createdAtBits: bits($0.createdAt), updatedAtBits: bits($0.updatedAt)
            )
        }.sorted { utf8Less($0.slotKey.string, $1.slotKey.string) }

        let webSyncRecords = try context.fetch(FetchDescriptor<WebSyncRecord>()).map {
            WebSyncRow(
                syncKey: $0.syncKey, userID: $0.userID,
                recordingID: $0.recordingID, remoteRecordingID: $0.remoteRecordingID,
                structuredState: $0.structuredState, structuredHash: $0.structuredHash,
                audioState: $0.audioState, audioFingerprint: $0.audioFingerprint,
                uploadSessionID: $0.uploadSessionID, attemptCount: $0.attemptCount,
                nextAttemptAtBits: bits($0.nextAttemptAt), lastErrorCode: $0.lastErrorCode,
                lastAttemptAtBits: bits($0.lastAttemptAt), syncedAtBits: bits($0.syncedAt),
                isDeletionTombstone: $0.isDeletionTombstone
            )
        }.sorted { utf8Less($0.syncKey.string, $1.syncKey.string) }

        return MigrationStoreSnapshot(
            recordings: recordings, folders: folders, externalImports: externalImports,
            speakerProfiles: speakerProfiles, voiceSamples: voiceSamples,
            recaps: recaps, artifacts: artifacts, webSyncRecords: webSyncRecords
        )
    }

    /// Total order over every field: SpeakerVoiceSample has no unique id,
    /// so only field-complete comparison guarantees a strict weak ordering
    /// (rows equal under it are equal rows, and reordering them cannot
    /// change the snapshot).
    static func voiceSampleTotalOrder(_ a: VoiceSampleRow, _ b: VoiceSampleRow) -> Bool {
        if !utf8Equal(a.recordingID.uuidString, b.recordingID.uuidString) {
            return utf8Less(a.recordingID.uuidString, b.recordingID.uuidString)
        }
        if !utf8Equal(a.rawLabel.string, b.rawLabel.string) {
            return utf8Less(a.rawLabel.string, b.rawLabel.string)
        }
        let aProfile = a.profileID?.uuidString ?? ""
        let bProfile = b.profileID?.uuidString ?? ""
        if !utf8Equal(aProfile, bProfile) { return utf8Less(aProfile, bProfile) }
        if a.embeddingData != b.embeddingData {
            return a.embeddingData.lexicographicallyPrecedes(b.embeddingData)
        }
        if a.embeddingDimension != b.embeddingDimension {
            return a.embeddingDimension < b.embeddingDimension
        }
        if a.sampleDurationBits != b.sampleDurationBits {
            return a.sampleDurationBits < b.sampleDurationBits
        }
        if a.nonOverlapRatioBits != b.nonOverlapRatioBits {
            return a.nonOverlapRatioBits < b.nonOverlapRatioBits
        }
        if a.qualityScoreBits != b.qualityScoreBits {
            return a.qualityScoreBits < b.qualityScoreBits
        }
        if !utf8Equal(a.modelVersion.string, b.modelVersion.string) {
            return utf8Less(a.modelVersion.string, b.modelVersion.string)
        }
        return a.createdAtBits < b.createdAtBits
    }

    // MARK: - Declared normalizations (independent of the migration code)

    /// Independent lexical rewrite rule: an absolute path strictly inside
    /// the root (string-prefix on a "/"-terminated root, no "."/".."
    /// components, non-empty remainder) becomes its subpath; anything else
    /// is unchanged.
    static func independentExpectedRewrite(_ raw: String?, rootPath: String) -> String? {
        guard let raw, raw.hasPrefix("/") else { return raw }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard raw.hasPrefix(prefix) else { return raw }
        let subpath = String(raw.dropFirst(prefix.count))
        let components = subpath.split(separator: "/").map(String.init)
        guard !subpath.isEmpty, !components.isEmpty,
              !components.contains("."), !components.contains("..") else { return raw }
        return subpath
    }

    /// The source snapshot transformed by the two normalizations M1 is
    /// allowed to perform. Comparing `expectedAfterM1(source) == product`
    /// proves the migration changed nothing else in the entire graph.
    func expectedAfterM1(audioRootPath: String) -> MigrationStoreSnapshot {
        var expected = self
        expected.recordings = recordings.map { row in
            var row = row
            if row.audioFileOwnership == nil {
                row.audioFileOwnership = RawString("unknownLegacy")
            }
            row.audioFilePath = Self.independentExpectedRewrite(
                row.audioFilePath?.string, rootPath: audioRootPath
            ).map(RawString.init)
            row.audioSegmentsDirectory = Self.independentExpectedRewrite(
                row.audioSegmentsDirectory?.string, rootPath: audioRootPath
            ).map(RawString.init)
            return row
        }
        return expected
    }
}
