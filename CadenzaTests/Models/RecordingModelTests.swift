import Testing
import Foundation
import SwiftData
@testable import Cadenza

@Suite("Recording Model")
struct RecordingModelTests {

    @Test func defaultInit() {
        let r = Recording()
        #expect(r.title == "Recording")
        #expect(r.language == "auto")
        #expect(r.duration == 0)
        #expect(r.tags.isEmpty)
        #expect(r.endDate == nil)
        #expect(r.audioFilePath == nil)
        #expect(r.meetingApp == nil)
        #expect(r.meetingURL == nil)
        #expect(r.meetingType == nil)
        #expect(r.lastAccessedDate == nil)
        #expect(r.trashedDate == nil)
        #expect(r.transcript == nil)
        #expect(r.summary == nil)
        #expect(r.folder == nil)
        #expect(r.createdAt != nil)
        #expect(r.createdAt == r.updatedAt)
        #expect(r.source == RecordingSource.captured.rawValue)
    }

    @Test func customInit() {
        let date = Date(timeIntervalSinceReferenceDate: 1000)
        let r = Recording(title: "My Meeting", startDate: date, language: "zh")
        #expect(r.title == "My Meeting")
        #expect(r.startDate == date)
        #expect(r.language == "zh")
    }

    @Test func idIsUniquePerInstance() {
        let r1 = Recording()
        let r2 = Recording()
        #expect(r1.id != r2.id)
    }

    @Test func mutableProperties() {
        let r = Recording()
        r.title = "Updated"
        r.duration = 120
        r.audioFilePath = "/tmp/audio.m4a"
        r.meetingApp = "Zoom"
        r.meetingURL = "https://zoom.us/j/123"
        r.tags = ["important", "work"]
        r.meetingType = "standup"
        r.endDate = Date()
        r.lastAccessedDate = Date()
        r.trashedDate = Date()

        #expect(r.title == "Updated")
        #expect(r.duration == 120)
        #expect(r.audioFilePath == "/tmp/audio.m4a")
        #expect(r.meetingApp == "Zoom")
        #expect(r.meetingURL == "https://zoom.us/j/123")
        #expect(r.tags.count == 2)
        #expect(r.meetingType == "standup")
        #expect(r.endDate != nil)
        #expect(r.lastAccessedDate != nil)
        #expect(r.trashedDate != nil)
    }

    @MainActor @Test func persistInMemoryStore() throws {
        let context = try TestPersistence.makeFreshContext()

        let r = TestRecordingFactory.makeRecording(title: "Persisted")
        context.insert(r)
        try context.save()

        let descriptor = FetchDescriptor<Recording>()
        let fetched = try context.fetch(descriptor)
        #expect(fetched.count == 1)
        #expect(fetched.first?.title == "Persisted")
    }

    @MainActor @Test func transcriptRelationship() throws {
        let context = try TestPersistence.makeFreshContext()

        let r = TestRecordingFactory.makeRecording()
        let t = TestRecordingFactory.makeTranscript(fullText: "Hello")
        r.transcript = t
        context.insert(r)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Recording>()).first!
        #expect(fetched.transcript != nil)
        #expect(fetched.transcript?.fullText == "Hello")
    }

    @MainActor @Test func summaryRelationship() throws {
        let context = try TestPersistence.makeFreshContext()

        let r = TestRecordingFactory.makeRecording()
        let s = TestRecordingFactory.makeSummary(overview: "Great meeting")
        r.summary = s
        context.insert(r)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Recording>()).first!
        #expect(fetched.summary != nil)
        #expect(fetched.summary?.overview == "Great meeting")
    }

    @MainActor @Test func folderRelationship() throws {
        let context = try TestPersistence.makeFreshContext()

        let r = TestRecordingFactory.makeRecording()
        let f = TestRecordingFactory.makeFolder(name: "Work")
        r.folder = f
        context.insert(r)
        context.insert(f)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Recording>()).first!
        #expect(fetched.folder?.name == "Work")
    }

    @MainActor @Test func cascadeDeleteTranscript() throws {
        let context = try TestPersistence.makeFreshContext()

        let r = TestRecordingFactory.makeRecording()
        r.transcript = TestRecordingFactory.makeTranscript()
        context.insert(r)
        try context.save()

        context.delete(r)
        try context.save()

        let transcripts = try context.fetch(FetchDescriptor<Transcript>())
        #expect(transcripts.isEmpty)
    }

    @MainActor @Test func cascadeDeleteSummary() throws {
        let context = try TestPersistence.makeFreshContext()

        let r = TestRecordingFactory.makeRecording()
        r.summary = TestRecordingFactory.makeSummary()
        context.insert(r)
        try context.save()

        context.delete(r)
        try context.save()

        let summaries = try context.fetch(FetchDescriptor<MeetingSummary>())
        #expect(summaries.isEmpty)
    }

    @Test func multipleTags() {
        let r = Recording()
        r.tags = ["meeting", "important", "q4"]
        #expect(r.tags.count == 3)
        #expect(r.tags.contains("important"))
    }

    @MainActor @Test func multipleRecordingsInStore() throws {
        let context = try TestPersistence.makeFreshContext()

        for i in 0..<5 {
            let r = TestRecordingFactory.makeRecording(title: "Recording \(i)")
            context.insert(r)
        }
        try context.save()

        let count = try context.fetch(FetchDescriptor<Recording>()).count
        #expect(count == 5)
    }
}
