import Foundation
import SwiftData
import Testing
@testable import Cadenza

@Suite("MCPMeetingPrepTools", .serialized)
struct MCPMeetingPrepToolsTests {

    // 与 MCPToolsTests 同模式:suite 级共享 in-memory container(并发建会 SIGTRAP)。
    @MainActor private static var sharedContainer: ModelContainer?

    @MainActor
    private func makeStore() async throws -> RecordingsStore {
        let container: ModelContainer
        if let existing = Self.sharedContainer { container = existing }
        else {
            container = try RecordingsStore.makeContainer(inMemory: true)
            Self.sharedContainer = container
        }
        let store = RecordingsStore(modelContainer: container)
        await store.clearAll()
        return store
    }

    private func makeRegistry(_ store: RecordingsStore, writes: Bool = true,
                              meetingContext: Bool = true,
                              events: [MeetingEvent] = []) -> MCPToolRegistry {
        MCPToolRegistry(store: store, writesEnabled: { writes },
                        meetingContextEnabled: { meetingContext },
                        upcomingEvents: { events })
    }

    private func sampleEvent(id: String = "EVT1", title: String = "Roadmap Sync",
                             startIn minutes: Int = 20, now: Date = Date()) -> MeetingEvent {
        MeetingEvent(id: id, title: title,
            startDate: now.addingTimeInterval(Double(minutes) * 60),
            endDate: now.addingTimeInterval(Double(minutes) * 60 + 3600),
            meetingURL: URL(string: "https://zoom.us/j/1"), meetingApp: .zoom,
            calendarName: "Work", notes: nil, source: .apple, calendarID: "cal1",
            attendees: [EventAttendee(name: "Dana", email: "dana@x.com", isOrganizer: true, status: .accepted)])
    }

    private func decode(_ result: MCPToolResult) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(result.text.utf8))
    }

    // MARK: - Gating

    @Test @MainActor func meetingContextToolsHiddenAndRejectedWhenDisabled() async throws {
        let store = try await makeStore()
        let registry = makeRegistry(store, meetingContext: false, events: [sampleEvent()])
        let defs = await registry.toolDefinitions()
        let names = defs.compactMap { $0["name"]?.asString }
        #expect(!names.contains("list_upcoming_meetings"))
        let result = await registry.call(name: "list_upcoming_meetings", arguments: nil)
        #expect(result.isError)
        #expect(result.text.contains("disabled"))
    }

    @Test @MainActor func meetingContextToolsListedWhenEnabled() async throws {
        let store = try await makeStore()
        let registry = makeRegistry(store, meetingContext: true)
        let names = await registry.toolDefinitions().compactMap { $0["name"]?.asString }
        #expect(names.contains("list_upcoming_meetings"))
    }

    // MARK: - list_upcoming_meetings

    @Test @MainActor func listUpcomingMeetingsReturnsEventsWithPrepStatus() async throws {
        let store = try await makeStore()
        let event = sampleEvent()
        // 预写一个 external prep,占住该会的槽位
        let candidate = ArtifactCandidate(kind: .meetingPrep, targetType: .calendarEvent,
            targetKey: event.artifactTargetKey, bodyMarkdown: "EXT", provenanceSource: .external,
            provenanceDetail: "mcp", status: .ready, generationID: nil, generatingStartedAt: nil,
            errorClass: nil, errorMessage: nil, targetStartDate: event.startDate,
            targetEndDate: event.endDate, targetFingerprint: "fp", contextBuiltAt: Date(), staleReason: nil)
        _ = await store.writeExternalArtifact(candidate)

        let registry = makeRegistry(store, events: [event])
        let result = await registry.call(name: "list_upcoming_meetings", arguments: nil)
        #expect(!result.isError)
        let json = try decode(result)
        let meetings = json["meetings"]?.asArray ?? []
        #expect(meetings.count == 1)
        let m = meetings[0]
        #expect(m["occurrenceKey"]?.asString == event.artifactTargetKey)
        #expect(m["title"]?.asString == "Roadmap Sync")
        #expect(m["hasPrep"]?.asBool == true)
        #expect(m["prepSource"]?.asString == "external")
        #expect(m["prepStatus"]?.asString == "ready")
        #expect(m["attendees"]?.asArray?.first?["name"]?.asString == "Dana")
    }

    /// Codex merge review P2: the MCP listener now starts at the top of AppState.setup(),
    /// before calendar monitoring — a cold cache must not be reported as "no meetings".
    @Test @MainActor func meetingToolsRefuseWhileCalendarIsCold() async throws {
        let store = try await makeStore()
        var registry = makeRegistry(store, events: [sampleEvent()])
        registry.calendarIsReady = { false }

        for tool in ["list_upcoming_meetings", "get_meeting_context", "write_artifact"] {
            let result = await registry.call(name: tool, arguments: .object([
                "occurrenceKey": .string(sampleEvent().artifactTargetKey),
                "bodyMarkdown": .string("body")]))
            #expect(result.isError)
            #expect(result.text.contains("hasn't finished loading"))
        }
    }

    @Test @MainActor func listUpcomingMeetingsFiltersByWithinHours() async throws {
        let store = try await makeStore()
        let now = Date()
        let soon = sampleEvent(id: "SOON", title: "Soon", startIn: 30, now: now)
        let far = sampleEvent(id: "FAR", title: "Far", startIn: 10 * 60, now: now)  // 10h 后
        let registry = makeRegistry(store, events: [soon, far])
        let result = await registry.call(name: "list_upcoming_meetings",
                                         arguments: .object(["withinHours": .number(2)]))
        let json = try decode(result)
        let titles = (json["meetings"]?.asArray ?? []).compactMap { $0["title"]?.asString }
        #expect(titles == ["Soon"])
    }

    // MARK: - get_meeting_context

    @Test @MainActor func getMeetingContextReturnsAssembledContext() async throws {
        let store = try await makeStore()
        let event = sampleEvent()
        let registry = makeRegistry(store, events: [event])
        let result = await registry.call(name: "get_meeting_context",
            arguments: .object(["occurrenceKey": .string(event.artifactTargetKey)]))
        #expect(!result.isError)
        let json = try decode(result)
        let ctx = json["context"]?.asString ?? ""
        #expect(ctx.contains("Roadmap Sync"))   // 事件头
        #expect(ctx.contains("Dana"))            // 参会人
        #expect(json["occurrenceKey"]?.asString == event.artifactTargetKey)
    }

    @Test @MainActor func getMeetingContextScopesOutUnrelatedRecordings() async throws {
        // 与 scheduler 同一条隐私红线:无关会议内容不得进 context(共享 assemble 保证)
        let store = try await makeStore()
        let recID = UUID()
        await store.createRecording(id: recID, title: "Security Incident Review",
                                    startDate: Date().addingTimeInterval(-86_400), segmentsDirURL: nil)
        let summary = SummaryResult(title: "Security Incident Review", overview: "Rotated all keys.",
            keyPoints: [], actionItems: [], decisions: [], followUps: [], yourTasks: [],
            tags: [], chapters: [], rawText: "")
        await store.saveSummary(recordingID: recID, summary: summary, chaptersJSON: nil)

        let event = sampleEvent()   // "Roadmap Sync",与 Security 无关
        let registry = makeRegistry(store, events: [event])
        let result = await registry.call(name: "get_meeting_context",
            arguments: .object(["occurrenceKey": .string(event.artifactTargetKey)]))
        #expect(!(result.text.contains("Security Incident Review")))
        #expect(!(result.text.contains("Rotated all keys.")))
    }

    @Test @MainActor func getMeetingContextUnknownKeyFails() async throws {
        let store = try await makeStore()
        let registry = makeRegistry(store, events: [sampleEvent()])
        let result = await registry.call(name: "get_meeting_context",
            arguments: .object(["occurrenceKey": .string("nope|nope|nope|")]))
        #expect(result.isError)
        #expect(result.text.contains("occurrenceKey"))
    }

    // MARK: - write_artifact

    private func writeArgs(_ event: MeetingEvent, body: String = "## Prep\nfrom agent") -> JSONValue {
        .object(["occurrenceKey": .string(event.artifactTargetKey), "bodyMarkdown": .string(body)])
    }

    @Test @MainActor func writeArtifactPersistsExternalReady() async throws {
        let store = try await makeStore()
        let event = sampleEvent()
        let registry = makeRegistry(store, events: [event])
        let result = await registry.call(name: "write_artifact", arguments: writeArgs(event))
        #expect(!result.isError)

        let slot = ArtifactTargetKey.slotKey(kind: "meetingPrep", targetType: "calendarEvent",
                                             targetKey: event.artifactTargetKey)
        let dto = await store.fetchArtifact(slotKey: slot)
        #expect(dto?.provenanceSource == "external")   // mapper 强制,调用方给不了别的
        #expect(dto?.provenanceDetail == "mcp")
        #expect(dto?.status == "ready")
        #expect(dto?.bodyMarkdown == "## Prep\nfrom agent")
    }

    @Test @MainActor func writeArtifactOverwritesBuiltinAndRefreshesFingerprint() async throws {
        let store = try await makeStore()
        let event = sampleEvent()
        // 先放一个 builtin ready(模拟内置已生成)
        let builtin = ArtifactCandidate(kind: .meetingPrep, targetType: .calendarEvent,
            targetKey: event.artifactTargetKey, bodyMarkdown: "BUILTIN", provenanceSource: .builtin,
            provenanceDetail: "model-x", status: .ready, generationID: nil, generatingStartedAt: nil,
            errorClass: nil, errorMessage: nil, targetStartDate: event.startDate,
            targetEndDate: event.endDate, targetFingerprint: "old-fp", contextBuiltAt: Date(), staleReason: nil)
        _ = await store.writeExternalArtifact(builtin)

        let registry = makeRegistry(store, events: [event])
        _ = await registry.call(name: "write_artifact", arguments: writeArgs(event, body: "AGENT"))
        let slot = ArtifactTargetKey.slotKey(kind: "meetingPrep", targetType: "calendarEvent",
                                             targetKey: event.artifactTargetKey)
        let dto = await store.fetchArtifact(slotKey: slot)
        #expect(dto?.bodyMarkdown == "AGENT")                                   // external 覆盖 builtin
        #expect(dto?.targetFingerprint == MeetingPrepFingerprint.compute(event)) // 指纹随写刷新
        #expect(dto?.staleReason == nil)
    }

    @Test @MainActor func writeArtifactRejectedWhenWritesDisabled() async throws {
        let store = try await makeStore()
        let event = sampleEvent()
        let registry = makeRegistry(store, writes: false, events: [event])
        let result = await registry.call(name: "write_artifact", arguments: writeArgs(event))
        #expect(result.isError)
        // 且从 tools/list 隐藏
        let names = await registry.toolDefinitions().compactMap { $0["name"]?.asString }
        #expect(!names.contains("write_artifact"))
    }

    @Test @MainActor func writeArtifactRequiresMeetingContextToo() async throws {
        // 关掉 meeting-context 应该关闭整个 meeting-prep MCP 面(含 write_artifact),
        // 即便 writes 开着——两个开关都要满足。
        let store = try await makeStore()
        let event = sampleEvent()
        let registry = makeRegistry(store, writes: true, meetingContext: false, events: [event])
        let result = await registry.call(name: "write_artifact", arguments: writeArgs(event))
        #expect(result.isError)
        #expect(result.text.contains("disabled"))
        let names = await registry.toolDefinitions().compactMap { $0["name"]?.asString }
        #expect(!names.contains("write_artifact"))
    }

    @Test @MainActor func writeArtifactValidatesKindAndKey() async throws {
        let store = try await makeStore()
        let event = sampleEvent()
        let registry = makeRegistry(store, events: [event])

        let badKind = await registry.call(name: "write_artifact", arguments: .object([
            "occurrenceKey": .string(event.artifactTargetKey),
            "bodyMarkdown": .string("x"), "kind": .string("followUp")]))
        #expect(badKind.isError)

        let badKey = await registry.call(name: "write_artifact", arguments: .object([
            "occurrenceKey": .string("nope|x|y|"), "bodyMarkdown": .string("x")]))
        #expect(badKey.isError)

        let emptyBody = await registry.call(name: "write_artifact", arguments: .object([
            "occurrenceKey": .string(event.artifactTargetKey), "bodyMarkdown": .string("  ")]))
        #expect(emptyBody.isError)
    }
}
