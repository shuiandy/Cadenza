import Testing
import Foundation
@testable import Cadenza

@Suite("DTO Coding")
struct DTOCodingTests {

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // MARK: - RecordingDTO

    @Test func recordingDTORoundTrip() throws {
        let original = TestDTOFactory.makeRecordingDTO(
            title: "Team Standup",
            duration: 1800,
            meetingApp: "Zoom",
            tags: ["work", "daily"],
            hasTranscript: true,
            transcriptPreview: "Hello everyone"
        )
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(RecordingDTO.self, from: data)
        #expect(decoded.id == original.id)
        #expect(decoded.title == "Team Standup")
        #expect(decoded.duration == 1800)
        #expect(decoded.meetingApp == "Zoom")
        #expect(decoded.tags == ["work", "daily"])
        #expect(decoded.hasTranscript == true)
        #expect(decoded.hasSummary == false)
        #expect(decoded.transcriptPreview == "Hello everyone")
        #expect(decoded.summaryPreview == nil)
    }

    @Test func recordingDTOWithNilOptionals() throws {
        let original = TestDTOFactory.makeRecordingDTO()
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(RecordingDTO.self, from: data)
        #expect(decoded.endDate == nil)
        #expect(decoded.meetingApp == nil)
        #expect(decoded.meetingURL == nil)
        #expect(decoded.meetingType == nil)
        #expect(decoded.lastAccessedDate == nil)
        #expect(decoded.trashedDate == nil)
        #expect(decoded.folderID == nil)
        #expect(decoded.audioFile == nil)
        #expect(decoded.createdAt == nil)
        #expect(decoded.updatedAt == nil)
        #expect(decoded.source == nil)
    }

    @Test func recordingDTOIdentifiable() {
        let dto = TestDTOFactory.makeRecordingDTO()
        #expect(dto.id == TestDTOFactory.fixedUUID)
    }

    // MARK: - FolderDTO

    @Test func folderDTORoundTrip() throws {
        let original = TestDTOFactory.makeFolderDTO(
            name: "Work",
            icon: "briefcase",
            iconColor: "blue",
            sortOrder: 2,
            recordingCount: 5
        )
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(FolderDTO.self, from: data)
        #expect(decoded.name == "Work")
        #expect(decoded.icon == "briefcase")
        #expect(decoded.iconColor == "blue")
        #expect(decoded.sortOrder == 2)
        #expect(decoded.recordingCount == 5)
    }

    // MARK: - TranscriptSegmentDTO

    @Test func transcriptSegmentDTORoundTrip() throws {
        let original = TestDTOFactory.makeTranscriptSegmentDTO(
            timestamp: 5.5,
            text: "Hello there",
            isFinal: true
        )
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(TranscriptSegmentDTO.self, from: data)
        #expect(decoded.timestamp == 5.5)
        #expect(decoded.text == "Hello there")
        #expect(decoded.isFinal == true)
    }

    @Test func transcriptSegmentDTONonFinal() throws {
        let original = TestDTOFactory.makeTranscriptSegmentDTO(isFinal: false)
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(TranscriptSegmentDTO.self, from: data)
        #expect(decoded.isFinal == false)
    }

    // MARK: - MeetingEventDTO

    @Test func meetingEventDTORoundTrip() throws {
        let attendee = EventAttendeeDTO(
            name: "Alice", email: "alice@example.com",
            isOrganizer: true, status: "accepted"
        )
        let original = TestDTOFactory.makeMeetingEventDTO(
            title: "Team Sync",
            meetingURL: "https://zoom.us/j/123",
            meetingApp: "Zoom",
            organizer: "Alice",
            attendees: [attendee],
            isRecurring: true,
            location: "Room A"
        )
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(MeetingEventDTO.self, from: data)
        #expect(decoded.title == "Team Sync")
        #expect(decoded.meetingURL == "https://zoom.us/j/123")
        #expect(decoded.meetingApp == "Zoom")
        #expect(decoded.organizer == "Alice")
        #expect(decoded.attendees.count == 1)
        #expect(decoded.isRecurring == true)
        #expect(decoded.location == "Room A")
    }

    @Test func meetingEventDTOIsAllDay() {
        // Create a full-day event starting at midnight, lasting 24h
        let cal = Calendar.current
        let midnight = cal.startOfDay(for: Date())
        let endOfDay = midnight.addingTimeInterval(24 * 3600)
        let event = TestDTOFactory.makeMeetingEventDTO(
            startDate: midnight,
            endDate: endOfDay
        )
        #expect(event.isAllDay == true)
    }

    @Test func meetingEventDTOIsNotAllDay() {
        let start = Date()
        let end = start.addingTimeInterval(3600)
        let event = TestDTOFactory.makeMeetingEventDTO(startDate: start, endDate: end)
        #expect(event.isAllDay == false)
    }

    // MARK: - RecordingDetailDTO

    @Test func recordingDetailDTORoundTrip() throws {
        let transcript = TranscriptDTO(
            id: UUID(), fullText: "Hello", segments: [],
            detectedLanguage: "en", createdAt: Date()
        )
        let summary = SummaryDTO(
            id: UUID(), overview: "Good meeting",
            keyPoints: ["P1"], actionItems: [],
            decisions: ["D1"], followUps: ["F1"], yourTasks: [],
            provider: "openai", model: "gpt-4o",
            language: "en", createdAt: Date(), chapters: []
        )
        let original = TestDTOFactory.makeRecordingDetailDTO(
            title: "Detail Test",
            transcript: transcript,
            summary: summary
        )
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(RecordingDetailDTO.self, from: data)
        #expect(decoded.title == "Detail Test")
        #expect(decoded.transcript?.fullText == "Hello")
        #expect(decoded.summary?.overview == "Good meeting")
    }

    @Test func recordingDetailDTOWithoutTranscriptAndSummary() throws {
        let original = TestDTOFactory.makeRecordingDetailDTO()
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(RecordingDetailDTO.self, from: data)
        #expect(decoded.transcript == nil)
        #expect(decoded.summary == nil)
        #expect(decoded.createdAt == nil)
        #expect(decoded.updatedAt == nil)
        #expect(decoded.source == nil)
    }

    // MARK: - TranscriptDTO

    @Test func transcriptDTORoundTrip() throws {
        let entry = TranscriptEntryDTO(
            id: UUID(), startTime: 0, endTime: 5,
            text: "Hello", speaker: "Alice"
        )
        let original = TranscriptDTO(
            id: UUID(), fullText: "Hello",
            segments: [entry], detectedLanguage: "en",
            createdAt: Date()
        )
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(TranscriptDTO.self, from: data)
        #expect(decoded.fullText == "Hello")
        #expect(decoded.segments.count == 1)
        #expect(decoded.segments.first?.speaker == "Alice")
    }

    // MARK: - SummaryDTO

    @Test func summaryDTORoundTrip() throws {
        let action = ActionItemDTO(
            id: UUID(), assignee: "Bob", task: "Review", deadline: "Friday",
            isCompleted: false, priority: "medium"
        )
        let original = SummaryDTO(
            id: UUID(), overview: "Great",
            keyPoints: ["K1", "K2"],
            actionItems: [action],
            decisions: ["D1"], followUps: ["F1"], yourTasks: [],
            provider: "claude", model: "claude-sonnet-4-5-20250929",
            language: "en", createdAt: Date(), chapters: []
        )
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(SummaryDTO.self, from: data)
        #expect(decoded.overview == "Great")
        #expect(decoded.keyPoints.count == 2)
        #expect(decoded.actionItems.first?.assignee == "Bob")
        #expect(decoded.provider == "claude")
    }

    // MARK: - NotionDatabaseDTO

    @Test func notionDatabaseDTORoundTrip() throws {
        let original = NotionDatabaseDTO(id: "db-123", title: "Meeting Notes")
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(NotionDatabaseDTO.self, from: data)
        #expect(decoded.id == "db-123")
        #expect(decoded.title == "Meeting Notes")
    }

    // MARK: - PermissionsDTO

    @Test func permissionsDTORoundTrip() throws {
        let original = PermissionsDTO(
            hasMicrophonePermission: true,
            hasScreenRecordingPermission: false,
            hasCalendarPermission: true
        )
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(PermissionsDTO.self, from: data)
        #expect(decoded.hasMicrophonePermission == true)
        #expect(decoded.hasScreenRecordingPermission == false)
        #expect(decoded.hasCalendarPermission == true)
    }

    // MARK: - EventAttendeeDTO

    @Test func eventAttendeeDTORoundTrip() throws {
        let original = EventAttendeeDTO(
            name: "Charlie", email: "charlie@example.com",
            isOrganizer: false, status: "tentative"
        )
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(EventAttendeeDTO.self, from: data)
        #expect(decoded.name == "Charlie")
        #expect(decoded.email == "charlie@example.com")
        #expect(decoded.isOrganizer == false)
        #expect(decoded.status == "tentative")
    }

    @Test func eventAttendeeDTOIdentifiable() {
        let attendee = EventAttendeeDTO(
            name: "Alice", email: "alice@test.com",
            isOrganizer: true, status: "accepted"
        )
        #expect(attendee.id == "alice@test.com")
    }

    // MARK: - ActionItemDTO

    @Test func actionItemDTORoundTrip() throws {
        let original = ActionItemDTO(
            id: UUID(), assignee: "Dave", task: "Deploy v2", deadline: "Next Monday",
            isCompleted: true, priority: "high"
        )
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(ActionItemDTO.self, from: data)
        #expect(decoded.assignee == "Dave")
        #expect(decoded.task == "Deploy v2")
        #expect(decoded.deadline == "Next Monday")
        #expect(decoded.isCompleted == true)
        #expect(decoded.priority == "high")
    }

    // MARK: - TranscriptEntryDTO

    @Test func transcriptEntryDTORoundTrip() throws {
        let original = TranscriptEntryDTO(
            id: UUID(), startTime: 10.5, endTime: 15.3,
            text: "Good morning", speaker: "Eve"
        )
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(TranscriptEntryDTO.self, from: data)
        #expect(decoded.startTime == 10.5)
        #expect(decoded.endTime == 15.3)
        #expect(decoded.text == "Good morning")
        #expect(decoded.speaker == "Eve")
    }

    @Test func transcriptEntryDTONilSpeaker() throws {
        let original = TranscriptEntryDTO(
            id: UUID(), startTime: 0, endTime: 1, text: "Hello", speaker: nil
        )
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(TranscriptEntryDTO.self, from: data)
        #expect(decoded.speaker == nil)
    }
}
