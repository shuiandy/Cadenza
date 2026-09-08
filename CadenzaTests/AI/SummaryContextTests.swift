import Foundation
import Testing
@testable import Cadenza

@Suite("Private summary context", .serialized)
struct SummaryContextTests {
    private var summary: SummaryDTO {
        SummaryDTO(id: UUID(), overview: "Staging pilot remains proposed.", keyPoints: ["Nora will check access."],
            actionItems: [], decisions: [], followUps: ["Pilot owner remains unknown."], yourTasks: [],
            provider: "openai", model: "fictional", language: "en", createdAt: Date(), chapters: [])
    }
    private func snapshot(input: SummaryContextInput = .init(), job: String = "Engineer") throws -> SummaryContextSnapshot {
        try #require(SummaryContextSnapshot.build(detail: TestDTOFactory.makeRecordingDetailDTO(summary: summary),
            input: input, userName: "Nora", jobTitle: job, defaultFocus: "Access", event: nil, history: []))
    }
    @Test func contextChangesNeverChangeCanonicalFacts() throws {
        let detail = TestDTOFactory.makeRecordingDetailDTO(summary: summary)
        let a = try #require(SummaryContextSnapshot.build(detail: detail, input: .init(), userName: "Nora", jobTitle: "Engineer", defaultFocus: "Access", event: nil, history: []))
        let b = try #require(SummaryContextSnapshot.build(detail: detail, input: .init(), userName: "Mina", jobTitle: "Finance", defaultFocus: "Costs", event: nil, history: []))
        #expect(a.summaryDigest == b.summaryDigest)
        #expect(a.facts.map(\.text) == b.facts.map(\.text))
        #expect(a.fingerprint != b.fingerprint)
    }
    @Test func selectedHistoryIsBoundedAndOptIn() throws {
        let current = TestDTOFactory.makeRecordingDetailDTO(startDate: Date(), summary: summary)
        let history = (1...5).map { day in TestDTOFactory.makeRecordingDetailDTO(id: UUID(), startDate: current.startDate.addingTimeInterval(Double(-day) * 86400), summary: summary) }
        let future = TestDTOFactory.makeRecordingDetailDTO(id: UUID(), startDate: current.startDate.addingTimeInterval(86400), summary: summary)
        let ancient = TestDTOFactory.makeRecordingDetailDTO(id: UUID(), startDate: current.startDate.addingTimeInterval(-100 * 86400), summary: summary)
        var input = SummaryContextInput()
        input.historyIDs = (history + [future, ancient, current]).map(\.id)
        func build() throws -> SummaryContextSnapshot {
            try #require(SummaryContextSnapshot.build(detail: current, input: input, userName: "", jobTitle: "", defaultFocus: "", event: nil, history: history + [future, ancient, current]))
        }
        #expect(try build().history.isEmpty)
        input.includeHistory = true
        #expect(try build().history.map(\.recordingID) == history.prefix(3).map(\.id))
    }
    @Test func outputMustReferenceCurrentSummaryAndCannotInventHistory() throws {
        let source = try snapshot()
        #expect(PersonalRelevance.parse(#"{"relevant":[{"text":"Access matters","references":["key_points/0"]}],"suggestions":[],"progress":[]}"#, snapshot: source) != nil)
        #expect(PersonalRelevance.parse(#"{"relevant":[{"text":"Invented","references":["key_points/999"]}],"suggestions":[],"progress":[]}"#, snapshot: source) == nil)
        #expect(PersonalRelevance.parse(#"{"relevant":[],"suggestions":[{"text":"Assign Sam","references":[]}],"progress":[]}"#, snapshot: source) == nil)
    }
    @Test func missingCalendarDoesNotPreventSummaryContext() throws {
        var input = SummaryContextInput(); input.includeCalendar = true
        #expect(try snapshot(input: input).calendar == nil)
    }
    @Test func calendarRequiresExactLinkAndOmitsContacts() throws {
        var detail = TestDTOFactory.makeRecordingDetailDTO(summary: summary)
        detail.linkedCalendarEventID = "linked"
        var input = SummaryContextInput(); input.includeCalendar = true
        let event = TestDTOFactory.makeMeetingEventDTO(id: "linked", title: "Pilot https://example.test/join?token=FICTIONAL title@example.test", notes: "Agenda only. https://example.test/private user@example.test",
            attendees: [.init(name: "Mina", email: "mina@example.test", isOrganizer: false, status: "accepted")])
        let source = try #require(SummaryContextSnapshot.build(detail: detail, input: input, userName: "", jobTitle: "", defaultFocus: "", event: event, history: []))
        let wire = String(decoding: try source.providerData(), as: UTF8.self)
        #expect(wire.contains("Agenda only"))
        #expect(wire.contains("Mina"))
        #expect(!wire.contains("https://"))
        #expect(!wire.contains("@example.test"))
        detail.linkedCalendarEventID = nil
        #expect(SummaryContextSnapshot.build(detail: detail, input: input, userName: "", jobTitle: "", defaultFocus: "", event: event, history: [])?.calendar == nil)
    }
    @Test func disabledSelectionsAreNotSentToProvider() throws {
        var input = SummaryContextInput(); input.historyIDs = [UUID()]
        let source = try snapshot(input: input)
        let data = try source.providerData()
        let wire = String(decoding: data, as: UTF8.self)
        #expect(!wire.contains("inputJSON"))
        #expect(!wire.contains(input.historyIDs[0].uuidString))
        #expect(source.history.isEmpty)
    }
    @Test func providerAliasesHideLocalIdentifiersAndResolveOnlyKnownReferences() throws {
        let priorID = UUID(), priorSummary = UUID(), taskID = UUID()
        let source = SummaryContextSnapshot(summaryID: UUID(), summaryDigest: "PRIVATE_CURRENT_DIGEST", userName: "Nora",
            jobTitle: "", focus: "Access", background: "", calendar: nil, calendarID: nil,
            history: [.init(recordingID: priorID, date: Date(), summaryID: priorSummary, digest: "PRIVATE_HISTORY_DIGEST",
                facts: [.init(id: "action_items/\(taskID)", text: "Check access")])],
            facts: [.init(id: "action_items/\(taskID)", text: "Access checked")], inputJSON: "{}")
        let wire = String(decoding: try source.providerData(), as: UTF8.self)
        for value in [source.summaryID.uuidString, priorID.uuidString, priorSummary.uuidString, taskID.uuidString,
                      source.summaryDigest, source.history[0].digest] { #expect(!wire.contains(value)) }
        let response = #"{"relevant":[{"text":"Access checked","references":["f0"]}],"progress":[{"recordingID":"h0","previousReference":"f0","currentReferences":["f0"],"text":"Access now checked"}]}"#
        let resolved = try #require(source.resolveProviderReferences(response))
        let parsed = try #require(PersonalRelevance.parse(resolved, snapshot: source))
        #expect(parsed.progress.first?.recordingID == priorID)
        #expect(parsed.relevant.first?.references == ["action_items/\(taskID)"])
        #expect(parsed.suggestions.isEmpty)
        #expect(source.resolveProviderReferences(response.replacingOccurrences(of: "h0", with: "h99")) == nil)
        #expect(source.resolveProviderReferences(response.replacingOccurrences(of: "f0", with: "f99")) == nil)
    }

    @Test func omittedArraysAreEmptyButMalformedArraysStillFail() throws {
        let source = try snapshot()
        let output = try #require(PersonalRelevance.parse(#"{"relevant":[]}"#, snapshot: source))
        #expect(output.suggestions.isEmpty && output.progress.isEmpty)
        #expect(PersonalRelevance.parse(#"{"relevant":"wrong type"}"#, snapshot: source) == nil)
    }

    @Test func localFocusUsesMeaningfulWordsInEnglishAndChinese() throws {
        let facts: [SummaryContextSnapshot.Fact] = [.init(id: "one", text: "密钥轮换仍需验证。"),
            .init(id: "two", text: "The access review is due."), .init(id: "three", text: "Happy launch day.")]
        func selected(_ focus: String) -> [String] {
            let source = SummaryContextSnapshot(summaryID: UUID(), summaryDigest: "fictional", userName: "", jobTitle: "",
                focus: focus, background: "", calendar: nil, calendarID: nil, history: [], facts: facts, inputJSON: "{}")
            return PersonalRelevanceGenerator.localRelevantFacts(source).flatMap(\.references)
        }
        #expect(selected("密钥轮换") == ["one"])
        #expect(selected("the and with").isEmpty)
        #expect(selected("app").isEmpty)
        #expect(selected("access") == ["two"])
    }

    @Test func storedContextRejectsLateResultsAndOtherProfiles() async throws {
        let store = RecordingsStore(modelContainer: try RecordingsStore.makeContainer(inMemory: true))
        let other = RecordingsStore(modelContainer: try RecordingsStore.makeContainer(inMemory: true))
        let id = UUID(); let earlier = UUID()
        for (recordID, date) in [(id, Date()), (earlier, Date().addingTimeInterval(-86400))] {
            #expect(await store.createRecording(id: recordID, title: "Fictional", startDate: date, segmentsDirURL: nil))
            let result = SummaryResult(title: "Fictional", overview: "Pilot proposed", keyPoints: ["Access needs checking"], actionItems: [], decisions: [], followUps: [], yourTasks: [], tags: [], chapters: [], rawText: "")
            #expect(await store.saveSummary(recordingID: recordID, summary: result, chaptersJSON: nil) == .saved)
        }
        #expect(await other.fetchConfirmedSummaryHistory(ids: [earlier], currentID: id, before: Date()).isEmpty)
        var input = SummaryContextInput(); input.includeHistory = true; input.historyIDs = [earlier]
        #expect(await store.saveSummaryContext(recordingID: id, input: input))
        let detail = try #require(await store.fetchRecordingDetail(recordingID: id))
        let history = await store.fetchConfirmedSummaryHistory(ids: input.historyIDs, currentID: id, before: detail.startDate)
        let source = try #require(SummaryContextSnapshot.build(detail: detail, input: input, userName: "Nora", jobTitle: "", defaultFocus: "Access", event: nil, history: history))
        let output = try #require(PersonalRelevance.parse(#"{"relevant":[],"suggestions":[],"progress":[]}"#, snapshot: source))
        #expect(await store.savePersonalRelevance(recordingID: id, result: output))
        #expect(await store.fetchSummaryContext(recordingID: id).1 != nil)
        #expect(await store.trashRecording(recordingID: earlier, reason: nil))
        #expect(await store.fetchSummaryContext(recordingID: id).1 == nil)
        #expect(await store.savePersonalRelevance(recordingID: id, result: output) == false)
        input.focus = "Changed focus"
        #expect(await store.saveSummaryContext(recordingID: id, input: input))
        #expect(await store.savePersonalRelevance(recordingID: id, result: output) == false)
    }
}
