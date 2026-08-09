import Testing
import Foundation
import SwiftData
@testable import Cadenza

@Suite("Folder Model")
struct FolderModelTests {

    @Test func defaultInit() {
        let f = Folder()
        #expect(f.name == "New Folder")
        #expect(f.icon == "folder")
        #expect(f.iconColor == "")
        #expect(f.sortOrder == 0)
        #expect(f.recordings.isEmpty)
    }

    @Test func customInit() {
        let f = Folder(name: "Work", icon: "briefcase", iconColor: "blue", sortOrder: 3)
        #expect(f.name == "Work")
        #expect(f.icon == "briefcase")
        #expect(f.iconColor == "blue")
        #expect(f.sortOrder == 3)
    }

    @Test func idIsUnique() {
        let f1 = Folder()
        let f2 = Folder()
        #expect(f1.id != f2.id)
    }

    @MainActor @Test func recordingsRelationship() throws {
        let context = try TestPersistence.makeFreshContext()

        let folder = Folder(name: "Test")
        let r1 = TestRecordingFactory.makeRecording(title: "R1")
        let r2 = TestRecordingFactory.makeRecording(title: "R2")
        context.insert(folder)
        context.insert(r1)
        context.insert(r2)
        r1.folder = folder
        r2.folder = folder
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Folder>()).first!
        #expect(fetched.recordings.count == 2)
    }

    @MainActor @Test func deleteFolderNullifiesRecordings() throws {
        let context = try TestPersistence.makeFreshContext()

        let folder = Folder(name: "Work")
        let r = TestRecordingFactory.makeRecording(title: "In Folder")
        context.insert(folder)
        context.insert(r)
        r.folder = folder
        try context.save()
        #expect(r.folder != nil)

        // Delete folder — recording should survive with folder = nil
        context.delete(folder)
        try context.save()

        let recordings = try context.fetch(FetchDescriptor<Recording>())
        #expect(recordings.count == 1)
        #expect(recordings.first?.folder == nil)
    }

    @Test func createdAtIsPopulated() {
        let before = Date()
        let f = Folder(name: "New")
        let after = Date()
        #expect(f.createdAt >= before)
        #expect(f.createdAt <= after)
    }
}
