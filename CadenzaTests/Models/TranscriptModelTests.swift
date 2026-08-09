import Testing
import Foundation
import SwiftData
@testable import Cadenza

@Suite("Transcript Model")
struct TranscriptModelTests {

    @Test func defaultInit() {
        let t = Transcript()
        #expect(t.fullText == "")
        #expect(t.segments.isEmpty)
        #expect(t.detectedLanguage == nil)
        #expect(t.recording == nil)
    }

    @Test func customInit() {
        let entry = TranscriptEntry(startTime: 0, endTime: 5, text: "Hi")
        let t = Transcript(fullText: "Hi", segments: [entry])
        #expect(t.fullText == "Hi")
        #expect(t.segments.count == 1)
    }

    @Test func idIsUnique() {
        let t1 = Transcript()
        let t2 = Transcript()
        #expect(t1.id != t2.id)
    }

    @Test func createdAtIsNow() {
        let before = Date()
        let t = Transcript()
        let after = Date()
        #expect(t.createdAt >= before)
        #expect(t.createdAt <= after)
    }

    @Test func mutableProperties() {
        let t = Transcript()
        t.fullText = "Updated text"
        t.detectedLanguage = "ja"
        #expect(t.fullText == "Updated text")
        #expect(t.detectedLanguage == "ja")
    }

    // MARK: - TranscriptEntry

    @Test func entryDefaultInit() {
        let e = TranscriptEntry(startTime: 1.0, endTime: 5.0, text: "Hello world")
        #expect(e.startTime == 1.0)
        #expect(e.endTime == 5.0)
        #expect(e.text == "Hello world")
        #expect(e.speaker == nil)
    }

    @Test func entryWithSpeaker() {
        let e = TranscriptEntry(startTime: 0, endTime: 3, text: "Test", speaker: "Alice")
        #expect(e.speaker == "Alice")
    }

    @Test func entryIdIsUnique() {
        let e1 = TranscriptEntry(startTime: 0, endTime: 1, text: "a")
        let e2 = TranscriptEntry(startTime: 0, endTime: 1, text: "a")
        #expect(e1.id != e2.id)
    }

    @Test func entryCodable() throws {
        let original = TranscriptEntry(startTime: 1.5, endTime: 3.5, text: "Codable test", speaker: "Bob")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TranscriptEntry.self, from: data)
        #expect(decoded.id == original.id)
        #expect(decoded.startTime == original.startTime)
        #expect(decoded.endTime == original.endTime)
        #expect(decoded.text == original.text)
        #expect(decoded.speaker == original.speaker)
    }

    @MainActor @Test func persistWithRecording() throws {
        let context = try TestPersistence.makeFreshContext()

        let r = TestRecordingFactory.makeRecording()
        let entry = TranscriptEntry(startTime: 0, endTime: 10, text: "Test entry")
        let t = Transcript(fullText: "Test entry", segments: [entry])
        t.detectedLanguage = "en"
        r.transcript = t
        context.insert(r)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Transcript>()).first!
        #expect(fetched.fullText == "Test entry")
        #expect(fetched.segments.count == 1)
        #expect(fetched.detectedLanguage == "en")
    }

    @Test func multipleSegments() {
        let segments = (0..<10).map { i in
            TranscriptEntry(startTime: Double(i), endTime: Double(i + 1), text: "Segment \(i)")
        }
        let t = Transcript(fullText: "long text", segments: segments)
        #expect(t.segments.count == 10)
    }

    @Test func emptySegments() {
        let t = Transcript(fullText: "No segments")
        #expect(t.segments.isEmpty)
    }

    @Test func entryIdIsStable() {
        let e = TranscriptEntry(startTime: 0, endTime: 1, text: "test")
        let id1 = e.id
        let id2 = e.id
        #expect(id1 == id2) // id should be stable across reads
    }
}
