import Foundation
import SwiftData
import Testing
@testable import Cadenza

// MARK: - In-Memory SwiftData

enum TestPersistence {
    /// Shared in-memory container reused across tests.
    /// Creating multiple ModelContainers concurrently can trigger SwiftData
    /// SIGTRAP crashes on macOS 26 beta. Reusing a single container avoids this.
    @MainActor
    private static var _sharedContainer: ModelContainer?

    @MainActor
    static func makeContainer() throws -> ModelContainer {
        if let existing = _sharedContainer { return existing }
        let schema = Schema([
            Recording.self, Transcript.self, MeetingSummary.self, ExternalRecordingImport.self,
            Folder.self, SpeakerProfile.self, SpeakerVoiceSample.self, Recap.self,
            AgentArtifact.self, WebSyncRecord.self,
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        _sharedContainer = container
        return container
    }

    /// Create a fresh context that clears all existing data first.
    @MainActor
    static func makeFreshContext() throws -> ModelContext {
        let container = try makeContainer()
        let ctx = container.mainContext
        // Clear relationships first, then delete objects individually.
        // SwiftData batch delete (ctx.delete(model:)) fails when models have
        // inverse relationships with nullify delete rules.
        let externalImports = try ctx.fetch(FetchDescriptor<ExternalRecordingImport>())
        for externalImport in externalImports { externalImport.recording = nil; ctx.delete(externalImport) }
        let recordings = try ctx.fetch(FetchDescriptor<Recording>())
        for r in recordings { r.folder = nil; ctx.delete(r) }
        let folders = try ctx.fetch(FetchDescriptor<Folder>())
        for f in folders { ctx.delete(f) }
        let transcripts = try ctx.fetch(FetchDescriptor<Transcript>())
        for t in transcripts { ctx.delete(t) }
        let summaries = try ctx.fetch(FetchDescriptor<MeetingSummary>())
        for s in summaries { ctx.delete(s) }
        let speakers = try ctx.fetch(FetchDescriptor<SpeakerProfile>())
        for sp in speakers { ctx.delete(sp) }
        let artifacts = try ctx.fetch(FetchDescriptor<AgentArtifact>())
        for a in artifacts { ctx.delete(a) }
        let webSyncRecords = try ctx.fetch(FetchDescriptor<WebSyncRecord>())
        for record in webSyncRecords { ctx.delete(record) }
        try ctx.save()
        return ctx
    }
}

// MARK: - Recording Factory

enum TestRecordingFactory {
    static func makeRecording(
        title: String = "Test Recording",
        startDate: Date = Date(),
        language: String = "en"
    ) -> Recording {
        let r = Recording(title: title, startDate: startDate, language: language)
        return r
    }

    static func makeTranscript(
        fullText: String = "Hello world",
        segments: [TranscriptEntry] = [],
        detectedLanguage: String? = "en"
    ) -> Transcript {
        let t = Transcript(fullText: fullText, segments: segments)
        t.detectedLanguage = detectedLanguage
        return t
    }

    static func makeSummary(
        overview: String = "Meeting overview",
        keyPoints: [String] = ["Point 1"],
        actionItems: [ActionItem] = [],
        decisions: [String] = [],
        followUps: [String] = [],
        provider: AIProvider = .openai,
        model: String = "gpt-4o",
        language: String = "en"
    ) -> MeetingSummary {
        MeetingSummary(
            overview: overview,
            keyPoints: keyPoints,
            actionItems: actionItems,
            decisions: decisions,
            followUps: followUps,
            provider: provider,
            model: model,
            language: language
        )
    }

    static func makeFolder(
        name: String = "Test Folder",
        icon: String = "folder",
        iconColor: String = "blue",
        sortOrder: Int = 0
    ) -> Folder {
        Folder(name: name, icon: icon, iconColor: iconColor, sortOrder: sortOrder)
    }
}

// MARK: - DTO Factory

enum TestDTOFactory {
    static let fixedUUID = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
    static let fixedDate = Date(timeIntervalSinceReferenceDate: 0) // 2001-01-01

    static func makeRecordingDTO(
        id: UUID = fixedUUID,
        title: String = "Test",
        startDate: Date = fixedDate,
        endDate: Date? = nil,
        duration: TimeInterval = 300,
        meetingApp: String? = nil,
        meetingURL: String? = nil,
        language: String = "en",
        tags: [String] = [],
        meetingType: String? = nil,
        lastAccessedDate: Date? = nil,
        trashedDate: Date? = nil,
        folderID: UUID? = nil,
        hasTranscript: Bool = false,
        hasSummary: Bool = false,
        transcriptPreview: String? = nil,
        summaryPreview: String? = nil,
        audioFileURL: URL? = nil
    ) -> RecordingDTO {
        RecordingDTO(
            id: id,
            title: title,
            startDate: startDate,
            endDate: endDate,
            duration: duration,
            meetingApp: meetingApp,
            meetingURL: meetingURL,
            language: language,
            tags: tags,
            meetingType: meetingType,
            lastAccessedDate: lastAccessedDate,
            trashedDate: trashedDate,
            folderID: folderID,
            hasTranscript: hasTranscript,
            hasSummary: hasSummary,
            transcriptPreview: transcriptPreview,
            summaryPreview: summaryPreview,
            audioFile: audioFileURL.map { .legacyAbsolute($0.path) }
        )
    }

    static func makeFolderDTO(
        id: UUID = fixedUUID,
        name: String = "Folder",
        icon: String = "folder",
        iconColor: String = "blue",
        createdAt: Date = fixedDate,
        sortOrder: Int = 0,
        recordingCount: Int = 0
    ) -> FolderDTO {
        FolderDTO(
            id: id,
            name: name,
            icon: icon,
            iconColor: iconColor,
            colorHex: nil,
            status: "active",
            createdAt: createdAt,
            sortOrder: sortOrder,
            recordingCount: recordingCount,
            parentFolderID: nil,
            subfolderCount: 0
        )
    }

    static func makeTranscriptSegmentDTO(
        id: UUID = UUID(),
        timestamp: TimeInterval = 0,
        text: String = "segment",
        isFinal: Bool = true
    ) -> TranscriptSegmentDTO {
        TranscriptSegmentDTO(id: id, timestamp: timestamp, text: text, isFinal: isFinal)
    }

    static func makeMeetingEventDTO(
        id: String = "evt-1",
        title: String = "Team Standup",
        startDate: Date = fixedDate,
        endDate: Date = fixedDate.addingTimeInterval(3600),
        meetingURL: String? = nil,
        meetingApp: String? = nil,
        calendarName: String = "Work",
        notes: String? = nil,
        source: String = "apple",
        calendarID: String = "cal-1",
        defaultColorHex: String = "#FF0000",
        organizer: String? = nil,
        attendees: [EventAttendeeDTO] = [],
        isRecurring: Bool = false,
        location: String? = nil
    ) -> MeetingEventDTO {
        MeetingEventDTO(
            id: id,
            title: title,
            startDate: startDate,
            endDate: endDate,
            meetingURL: meetingURL,
            meetingApp: meetingApp,
            calendarName: calendarName,
            notes: notes,
            source: source,
            calendarID: calendarID,
            defaultColorHex: defaultColorHex,
            organizer: organizer,
            attendees: attendees,
            isRecurring: isRecurring,
            location: location
        )
    }

    static func makeRecordingDetailDTO(
        id: UUID = fixedUUID,
        title: String = "Detail",
        startDate: Date = fixedDate,
        duration: TimeInterval = 600,
        language: String = "en",
        tags: [String] = [],
        transcript: TranscriptDTO? = nil,
        summary: SummaryDTO? = nil,
        speakerMappings: [SpeakerLabelMappingDTO] = [],
        speakerSuggestions: [SpeakerLabelSuggestionDTO] = []
    ) -> RecordingDetailDTO {
        RecordingDetailDTO(
            id: id,
            title: title,
            startDate: startDate,
            endDate: nil,
            duration: duration,
            meetingApp: nil,
            meetingURL: nil,
            language: language,
            tags: tags,
            meetingType: nil,
            lastAccessedDate: nil,
            folderID: nil,
            audioFile: nil,
            linkedCalendarEventID: nil,
            transcript: transcript,
            summary: summary,
            speakerMappings: speakerMappings,
            speakerSuggestions: speakerSuggestions
        )
    }
}
