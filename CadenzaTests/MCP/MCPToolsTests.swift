import Foundation
import SwiftData
import Testing
@testable import Cadenza

@Suite("MCPTools", .serialized)
struct MCPToolsTests {

    // MARK: - Fixture

    /// One shared in-memory container for the whole suite. Creating
    /// ModelContainers concurrently SIGTRAPs on macOS 26 (see TestHelpers);
    /// suites run in parallel, so per-test containers crash the test host.
    @MainActor
    private static var sharedContainer: ModelContainer?

    @MainActor
    private func makeStore() async throws -> RecordingsStore {
        let container: ModelContainer
        if let existing = Self.sharedContainer {
            container = existing
        } else {
            container = try RecordingsStore.makeContainer(inMemory: true)
            Self.sharedContainer = container
        }
        let store = RecordingsStore(modelContainer: container)
        await store.clearAll()
        return store
    }

    private func makeRegistry(_ store: RecordingsStore, writes: Bool = true) -> MCPToolRegistry {
        MCPToolRegistry(store: store, writesEnabled: { writes })
    }

    /// Recording with a 6-segment transcript (two speakers) on the given date.
    @discardableResult
    private func seedTranscribed(_ store: RecordingsStore, title: String = "Roadmap sync",
                                 date: Date = Date(), speakerName: String? = "Alice") async -> UUID {
        let id = UUID()
        await store.createRecording(id: id, title: title, startDate: date, segmentsDirURL: nil)
        let segments = (0..<6).map { index in
            TranscriptEntry(startTime: Double(index) * 10, endTime: Double(index) * 10 + 9,
                            text: "Segment \(index) discussing the quarterly roadmap in detail.",
                            speaker: index % 2 == 0 ? "Speaker 1" : "Speaker 2")
        }
        let fullText = segments.map(\.text).joined(separator: " ")
        // "wiz" is a stable seed tag: not aliased, not in the default blocklist
        // (unlike "planning" → 规划, which the normalizer drops).
        await store.saveTranscript(recordingID: id, fullText: fullText, segments: segments,
                                   language: "en", tags: ["wiz"])
        if let speakerName,
           let profile = await store.createSpeakerProfile(displayName: speakerName) {
            await store.setSpeakerMapping(recordingID: id, rawLabel: "Speaker 1", profileID: profile.id)
        }
        return id
    }

    @discardableResult
    private func seedSummarized(_ store: RecordingsStore, title: String = "Budget review",
                                date: Date = Date()) async -> UUID {
        let id = await seedTranscribed(store, title: title, date: date, speakerName: nil)
        let summary = SummaryResult(
            title: title,
            overview: "The team agreed on the Q3 budget allocation for infrastructure.",
            keyPoints: ["Budget approved"],
            actionItems: [ActionItemResult(assignee: "Bob", task: "Draft budget doc", deadline: nil)],
            decisions: ["Ship in Q3"],
            followUps: ["Review headcount"],
            yourTasks: [],
            tags: ["finance"],
            chapters: [],
            rawText: ""
        )
        await store.saveSummary(recordingID: id, summary: summary, chaptersJSON: nil)
        return id
    }

    private func payload(_ result: MCPToolResult) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(result.text.utf8))
    }

    // MARK: - search_transcripts

    @Test @MainActor
    func searchFindsTranscriptContentWithSnippet() async throws {
        let store = try await makeStore()
        await seedTranscribed(store, title: "Roadmap sync")
        await seedSummarized(store, title: "Budget review")

        let result = await makeRegistry(store).call(
            name: "search_transcripts", arguments: ["query": "quarterly roadmap"])
        #expect(result.isError == false)
        let json = try payload(result)
        let results = json["results"]?.asArray ?? []
        #expect(results.count >= 1)
        let snippet = results.first?["snippet"]?.asString ?? ""
        #expect(snippet.localizedCaseInsensitiveContains("quarterly roadmap"))
    }

    @Test @MainActor
    func searchExcludesTrashedRecordings() async throws {
        let store = try await makeStore()
        let id = await seedTranscribed(store, title: "Doomed meeting")
        await store.deleteRecording(recordingID: id)

        let result = await makeRegistry(store).call(
            name: "search_transcripts", arguments: ["query": "quarterly roadmap"])
        let json = try payload(result)
        #expect(json["results"]?.asArray?.isEmpty == true)
    }

    @Test @MainActor
    func searchRequiresQuery() async throws {
        let store = try await makeStore()
        let result = await makeRegistry(store).call(name: "search_transcripts", arguments: ["query": "  "])
        #expect(result.isError)
    }

    // MARK: - list_recordings

    @Test @MainActor
    func listFiltersByDateRange() async throws {
        let store = try await makeStore()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let lastWeek = calendar.date(byAdding: .day, value: -7, to: today)!
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        await seedTranscribed(store, title: "Old meeting", date: lastWeek)
        await seedTranscribed(store, title: "Recent meeting", date: yesterday.addingTimeInterval(3600))

        let dayFormat = Date.ISO8601FormatStyle.iso8601.year().month().day()
        let result = await makeRegistry(store).call(name: "list_recordings", arguments: [
            "startDate": .string(yesterday.formatted(dayFormat)),
            "endDate": .string(yesterday.formatted(dayFormat)),
        ])
        let json = try payload(result)
        let recordings = json["recordings"]?.asArray ?? []
        #expect(recordings.count == 1)
        #expect(recordings.first?["title"]?.asString == "Recent meeting")
    }

    @Test @MainActor
    func listFiltersByTag() async throws {
        let store = try await makeStore()
        await seedTranscribed(store, title: "Tagged")           // tags: ["wiz"]
        let plain = UUID()
        await store.createRecording(id: plain, title: "Untagged", startDate: Date(), segmentsDirURL: nil)

        let result = await makeRegistry(store).call(name: "list_recordings", arguments: ["tag": "wiz"])
        let json = try payload(result)
        let recordings = json["recordings"]?.asArray ?? []
        #expect(recordings.count == 1)
        #expect(recordings.first?["title"]?.asString == "Tagged")
    }

    @Test @MainActor
    func listRejectsUnknownFolder() async throws {
        let store = try await makeStore()
        let result = await makeRegistry(store).call(name: "list_recordings", arguments: ["folderName": "Nope"])
        #expect(result.isError)
        #expect(result.text.contains("Folder not found"))
    }

    @Test @MainActor
    func listRejectsBadDate() async throws {
        let store = try await makeStore()
        let result = await makeRegistry(store).call(name: "list_recordings", arguments: ["startDate": "junk"])
        #expect(result.isError)
    }

    @Test @MainActor
    func listUsesStableCursorAndRequestedSort() async throws {
        let store = try await makeStore()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        await seedTranscribed(store, title: "Oldest", date: base)
        await seedTranscribed(store, title: "Middle", date: base.addingTimeInterval(60))
        await seedTranscribed(store, title: "Newest", date: base.addingTimeInterval(120))

        let registry = makeRegistry(store)
        let first = try payload(await registry.call(name: "list_recordings", arguments: [
            "limit": 2,
            "sort": "date_asc",
        ]))
        #expect(first["recordings"]?.asArray?.compactMap { $0["title"]?.asString } == ["Oldest", "Middle"])
        let cursor = try #require(first["nextCursor"]?.asString)

        let second = try payload(await registry.call(name: "list_recordings", arguments: [
            "limit": 2,
            "sort": "date_asc",
            "cursor": .string(cursor),
        ]))
        #expect(second["recordings"]?.asArray?.compactMap { $0["title"]?.asString } == ["Newest"])
        #expect(second["nextCursor"] == .null)
        #expect(second["totalMatches"]?.asInt == 3)
    }

    @Test @MainActor
    func listCursorExpiresWhenMatchingRecordingChanges() async throws {
        let store = try await makeStore()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let firstID = await seedTranscribed(store, title: "First", date: base)
        await seedTranscribed(store, title: "Second", date: base.addingTimeInterval(60))

        let registry = makeRegistry(store)
        let first = try payload(await registry.call(name: "list_recordings", arguments: [
            "limit": 1,
            "sort": "date_asc",
        ]))
        let cursor = try #require(first["nextCursor"]?.asString)
        #expect(await store.updateTitle(recordingID: firstID, title: "First updated"))

        let second = await registry.call(name: "list_recordings", arguments: [
            "limit": 1,
            "sort": "date_asc",
            "cursor": .string(cursor),
        ])
        #expect(second.isError)
        #expect(second.text.localizedCaseInsensitiveContains("cursor expired"))
    }

    @Test @MainActor
    func listCursorRejectsChangedFilters() async throws {
        let store = try await makeStore()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        await seedTranscribed(store, title: "First", date: base)
        await seedTranscribed(store, title: "Second", date: base.addingTimeInterval(60))

        let registry = makeRegistry(store)
        let first = try payload(await registry.call(name: "list_recordings", arguments: [
            "limit": 1,
            "sort": "date_asc",
        ]))
        let cursor = try #require(first["nextCursor"]?.asString)

        let changed = await registry.call(name: "list_recordings", arguments: [
            "limit": 1,
            "sort": "date_desc",
            "cursor": .string(cursor),
        ])
        #expect(changed.isError)
        #expect(changed.text.localizedCaseInsensitiveContains("does not match"))
    }

    @Test @MainActor
    func listFiltersByUpdatedAfter() async throws {
        let store = try await makeStore()
        let olderID = UUID()
        await store.createRecording(id: olderID, title: "Older", startDate: Date(), segmentsDirURL: nil)
        try await Task.sleep(for: .milliseconds(5))
        let cutoff = Date()
        try await Task.sleep(for: .milliseconds(5))
        let newerID = UUID()
        await store.createRecording(id: newerID, title: "Newer", startDate: Date(), segmentsDirURL: nil)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let result = try payload(await makeRegistry(store).call(name: "list_recordings", arguments: [
            "updatedAfter": .string(formatter.string(from: cutoff)),
        ]))
        #expect(result["recordings"]?.asArray?.compactMap { $0["id"]?.asString } == [newerID.uuidString])
    }

    @Test @MainActor
    func listFiltersBySourceAndContentStatus() async throws {
        let store = try await makeStore()
        let emptyID = UUID()
        await store.createRecording(id: emptyID, title: "Captured empty", startDate: Date(), segmentsDirURL: nil)
        await seedTranscribed(store, title: "Captured transcript")
        await seedSummarized(store, title: "Captured ready")
        let audioRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-audio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: audioRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: audioRoot) }
        await store.setAudioRootForTesting(audioRoot)
        #expect(await store.importAudioFile(
            id: UUID(), title: "Imported audio", startDate: Date(), duration: 120,
            audioURL: audioRoot.appendingPathComponent("imported-audio.m4a"), ownership: .appCreated))

        let registry = makeRegistry(store)
        let imported = try payload(await registry.call(name: "list_recordings", arguments: [
            "source": "imported_audio",
        ]))
        #expect(imported["recordings"]?.asArray?.compactMap { $0["title"]?.asString } == ["Imported audio"])

        let ready = try payload(await registry.call(name: "list_recordings", arguments: [
            "status": "ready",
        ]))
        #expect(ready["recordings"]?.asArray?.compactMap { $0["title"]?.asString } == ["Captured ready"])

        let empty = try payload(await registry.call(name: "list_recordings", arguments: [
            "source": "captured",
            "status": "empty",
        ]))
        let item = try #require(empty["recordings"]?.asArray?.first)
        #expect(item["id"]?.asString == emptyID.uuidString)
        #expect(item["source"]?.asString == "captured")
        #expect(item["status"]?.asString == "empty")
        #expect(item["createdAt"]?.asString != nil)
        #expect(item["updatedAt"]?.asString != nil)

        let folder = try #require(await store.createFolder(name: "Archive", icon: "folder", iconColor: ""))
        let trashedID = UUID()
        await store.createRecording(id: trashedID, title: "Archived", startDate: Date(), segmentsDirURL: nil)
        await store.moveToFolder(recordingID: trashedID, folderID: folder.id)
        await store.trashRecording(recordingID: trashedID, reason: nil)
        let trashed = try payload(await registry.call(name: "list_recordings", arguments: [
            "folderName": "archive",
            "status": "trashed",
        ]))
        #expect(trashed["recordings"]?.asArray?.compactMap { $0["id"]?.asString } == [trashedID.uuidString])
    }

    // MARK: - get_transcript

    @Test @MainActor
    func transcriptResolvesSpeakerNames() async throws {
        let store = try await makeStore()
        let id = await seedTranscribed(store)  // Speaker 1 → Alice

        let result = await makeRegistry(store).call(
            name: "get_transcript", arguments: ["recordingId": .string(id.uuidString)])
        let json = try payload(result)
        let text = json["text"]?.asString ?? ""
        #expect(text.contains("Alice: Segment 0"))
        #expect(text.contains("Speaker 2: Segment 1"))  // unmapped label kept as-is
        #expect(json["nextCursor"] == nil)
    }

    @Test @MainActor
    func transcriptPaginatesAndCursorChains() async throws {
        let store = try await makeStore()
        let id = UUID()
        await store.createRecording(id: id, title: "Long one", startDate: Date(), segmentsDirURL: nil)
        let segments = (0..<40).map { index in
            TranscriptEntry(startTime: Double(index), endTime: Double(index) + 1,
                            text: String(repeating: "word\(index) ", count: 30), speaker: nil)
        }
        await store.saveTranscript(recordingID: id, fullText: segments.map(\.text).joined(),
                                   segments: segments, language: nil, tags: [])

        let registry = makeRegistry(store)
        var cursor: String?
        var pages = 0
        var collected: [String] = []
        repeat {
            var args: [String: JSONValue] = ["recordingId": .string(id.uuidString), "maxChars": 1000]
            if let cursor { args["cursor"] = .string(cursor) }
            let json = try payload(await registry.call(name: "get_transcript", arguments: .object(args)))
            collected.append(json["text"]?.asString ?? "")
            cursor = json["nextCursor"]?.asString
            pages += 1
        } while cursor != nil && pages < 50

        #expect(pages > 1)
        let expected = segments.map(\.text).joined(separator: "\n")
        #expect(collected.joined(separator: "\n") == expected)
    }

    @Test @MainActor
    func transcriptTimeWindow() async throws {
        let store = try await makeStore()
        let id = await seedTranscribed(store, speakerName: nil)  // segments at 0-9, 10-19, ... 50-59

        let result = await makeRegistry(store).call(name: "get_transcript", arguments: [
            "recordingId": .string(id.uuidString), "startTime": 20, "endTime": 39,
        ])
        let json = try payload(result)
        let text = json["text"]?.asString ?? ""
        #expect(text.contains("Segment 2"))
        #expect(text.contains("Segment 3"))
        #expect(!text.contains("Segment 1 "))
        #expect(!text.contains("Segment 4"))
    }

    @Test @MainActor
    func transcriptSegmentsFormat() async throws {
        let store = try await makeStore()
        let id = await seedTranscribed(store)

        let result = await makeRegistry(store).call(name: "get_transcript", arguments: [
            "recordingId": .string(id.uuidString), "format": "segments",
        ])
        let json = try payload(result)
        let segments = json["segments"]?.asArray ?? []
        #expect(segments.count == 6)
        #expect(segments.first?["start"]?.asDouble == 0)
        #expect(segments.first?["speaker"]?.asString == "Alice")
        #expect(segments.first?["text"]?.asString?.isEmpty == false)
    }

    @Test @MainActor
    func transcriptMissingIsToolError() async throws {
        let store = try await makeStore()
        let id = UUID()
        await store.createRecording(id: id, title: "Fresh", startDate: Date(), segmentsDirURL: nil)

        let result = await makeRegistry(store).call(
            name: "get_transcript", arguments: ["recordingId": .string(id.uuidString)])
        #expect(result.isError)
        #expect(result.text.contains("no transcript"))
    }

    @Test @MainActor
    func unknownRecordingIsToolError() async throws {
        let store = try await makeStore()
        let result = await makeRegistry(store).call(
            name: "get_transcript", arguments: ["recordingId": .string(UUID().uuidString)])
        #expect(result.isError)
        #expect(result.text.contains("not found"))
    }

    @Test @MainActor
    func trashedRecordingIsHiddenFromGet() async throws {
        let store = try await makeStore()
        let id = await seedTranscribed(store)
        await store.deleteRecording(recordingID: id)

        let result = await makeRegistry(store).call(
            name: "get_transcript", arguments: ["recordingId": .string(id.uuidString)])
        #expect(result.isError)
        #expect(result.text.contains("not found"))
    }

    // MARK: - get_summary

    @Test @MainActor
    func summaryIncludesActionItemIDs() async throws {
        let store = try await makeStore()
        let id = await seedSummarized(store)

        let result = await makeRegistry(store).call(
            name: "get_summary", arguments: ["recordingId": .string(id.uuidString)])
        let json = try payload(result)
        #expect(json["overview"]?.asString?.contains("Q3 budget") == true)
        #expect(json["decisions"]?.asArray?.count == 1)
        let items = json["actionItems"]?.asArray ?? []
        #expect(items.count == 1)
        #expect(items.first?["isCompleted"]?.asBool == false)
        #expect(UUID(uuidString: items.first?["id"]?.asString ?? "") != nil)
    }

    @Test @MainActor
    func summaryMissingIsToolError() async throws {
        let store = try await makeStore()
        let id = await seedTranscribed(store)
        let result = await makeRegistry(store).call(
            name: "get_summary", arguments: ["recordingId": .string(id.uuidString)])
        #expect(result.isError)
        #expect(result.text.contains("no summary"))
    }

    // MARK: - Write switch

    @Test @MainActor
    func writeToolsHiddenWhenDisabled() async throws {
        let store = try await makeStore()
        let enabled = await makeRegistry(store, writes: true).toolDefinitions()
        let disabled = await makeRegistry(store, writes: false).toolDefinitions()
        // makeRegistry here leaves meetingContextEnabled at the struct default
        // ({ false }), so write_artifact (gated by writes AND meeting-context)
        // never appears in this suite: 7 read + 7 core write = 14 when enabled.
        #expect(enabled.count == 14)  // write_artifact needs meeting-context too
        #expect(disabled.count == 7)  // read only
        #expect(disabled.contains { $0["name"]?.asString == "list_tags" })
        #expect(!disabled.contains { $0["name"]?.asString == "rename_recording" })
    }

    @Test @MainActor
    func toolDefinitionsExposeRiskAnnotations() async throws {
        let store = try await makeStore()
        let registry = MCPToolRegistry(
            store: store,
            writesEnabled: { true },
            meetingContextEnabled: { true }
        )
        let definitions = await registry.toolDefinitions()
        #expect(definitions.count == 18)
        for definition in definitions {
            #expect(definition["title"]?.asString?.isEmpty == false)
            let annotations = definition["annotations"]
            #expect(annotations?["readOnlyHint"]?.asBool != nil)
            #expect(annotations?["destructiveHint"]?.asBool != nil)
            #expect(annotations?["idempotentHint"]?.asBool != nil)
            #expect(annotations?["openWorldHint"]?.asBool != nil)
        }

        let search = try #require(definitions.first { $0["name"]?.asString == "search_transcripts" })
        #expect(search["title"]?.asString?.isEmpty == false)
        #expect(search["annotations"]?["readOnlyHint"]?.asBool == true)
        #expect(search["annotations"]?["destructiveHint"]?.asBool == false)
        #expect(search["annotations"]?["idempotentHint"]?.asBool == true)
        #expect(search["annotations"]?["openWorldHint"]?.asBool == false)

        let toggle = try #require(definitions.first { $0["name"]?.asString == "toggle_action_item" })
        #expect(toggle["annotations"]?["readOnlyHint"]?.asBool == false)
        #expect(toggle["annotations"]?["idempotentHint"]?.asBool == false)

        let removeTag = try #require(definitions.first { $0["name"]?.asString == "remove_tag" })
        #expect(removeTag["annotations"]?["destructiveHint"]?.asBool == true)
    }

    @Test @MainActor
    func clientScopesFilterToolVisibilityAndDirectCalls() async throws {
        let store = try await makeStore()
        let registry = MCPToolRegistry(
            store: store,
            writesEnabled: { true },
            externalImportEnabled: { true },
            meetingContextEnabled: { true }
        )
        let context = MCPRequestContext(
            clientID: "reader",
            clientName: "Reader",
            scopes: [.recordingRead],
            isLegacy: false
        )
        let definitions = await registry.toolDefinitions(context: context)
        #expect(definitions.contains { $0["name"]?.asString == "list_recordings" })
        #expect(!definitions.contains { $0["name"]?.asString == "rename_recording" })
        #expect(!definitions.contains { $0["name"]?.asString == "list_upcoming_meetings" })
        #expect(!definitions.contains { $0["name"]?.asString == "preview_external_recordings" })

        let denied = await registry.call(
            name: "rename_recording",
            arguments: ["recordingId": .string(UUID().uuidString), "title": "No"],
            context: context
        )
        #expect(denied.isError)
        #expect(denied.text.contains("recording.write"))
    }

    @Test @MainActor
    func findPeopleReturnsAmbiguousCalendarAndSpeakerCandidatesWithoutMapping() async throws {
        let store = try await makeStore()
        await seedTranscribed(store, speakerName: "Alice")
        let event = MeetingEvent(
            id: "event-1",
            title: "Planning",
            startDate: Date().addingTimeInterval(600),
            endDate: Date().addingTimeInterval(3600),
            meetingURL: nil,
            meetingApp: nil,
            calendarName: "Work",
            notes: nil,
            attendees: [
                EventAttendee(
                    name: "Alice",
                    email: "alice@example.com",
                    isOrganizer: false,
                    status: .accepted
                ),
            ]
        )
        let registry = MCPToolRegistry(
            store: store,
            writesEnabled: { false },
            meetingContextEnabled: { true },
            upcomingEvents: { [event] }
        )

        let result = try payload(await registry.call(name: "find_people", arguments: ["query": "Alice"]))
        let candidates = result["candidates"]?.asArray ?? []
        #expect(candidates.count == 2)
        #expect(result["requiresDisambiguation"]?.asBool == true)
        #expect(candidates.contains { $0["personId"]?.asString == "email:alice@example.com" })
        let speaker = try #require(candidates.first { $0["personId"]?.asString?.hasPrefix("speaker:") == true })
        #expect(speaker["historicalMeetingCount"]?.asInt == 1)

        let limited = try payload(await registry.call(
            name: "find_people",
            arguments: ["query": "Alice", "limit": 1]
        ))
        #expect(limited["candidates"]?.asArray?.count == 1)
        #expect(limited["totalCandidates"]?.asInt == 2)
        #expect(limited["requiresDisambiguation"]?.asBool == true)

        let context = try payload(await registry.call(
            name: "get_person_meeting_context",
            arguments: ["personId": speaker["personId"] ?? .null]
        ))
        #expect(context["meetings"]?.asArray?.count == 1)
    }

    @Test @MainActor
    func calendarCandidateIsNotAutoLinkedToRecordingHistory() async throws {
        let store = try await makeStore()
        let result = try payload(await makeRegistry(store).call(
            name: "get_person_meeting_context",
            arguments: ["personId": "email:alice@example.com"]
        ))
        #expect(result["meetings"]?.asArray?.isEmpty == true)
        #expect(result["reason"]?.asString?.contains("not automatically linked") == true)

        let invalid = await makeRegistry(store).call(
            name: "get_person_meeting_context",
            arguments: ["personId": "unknown"]
        )
        #expect(invalid.isError)
    }

    @Test @MainActor
    func externalImportToolsUseIndependentVisibilityAndAnnotations() async throws {
        let store = try await makeStore()
        let disabled = MCPToolRegistry(
            store: store,
            writesEnabled: { true },
            externalImportEnabled: { false }
        )
        let enabled = MCPToolRegistry(
            store: store,
            writesEnabled: { false },
            externalImportEnabled: { true }
        )

        let disabledNames = await disabled.toolDefinitions().compactMap { $0["name"]?.asString }
        #expect(!disabledNames.contains("preview_external_recordings"))
        #expect(!disabledNames.contains("upsert_external_recording"))

        let enabledDefinitions = await enabled.toolDefinitions()
        let importTools = enabledDefinitions.filter {
            [
                "preview_external_recordings",
                "upload_external_transcript_chunk",
                "upsert_external_recording",
                "set_external_import_disposition",
            ].contains($0["name"]?.asString ?? "")
        }
        #expect(importTools.count == 4)
        let preview = try #require(importTools.first { $0["name"]?.asString == "preview_external_recordings" })
        #expect(preview["annotations"]?["readOnlyHint"]?.asBool == true)
        #expect(preview["annotations"]?["idempotentHint"]?.asBool == true)
        let upsert = try #require(importTools.first { $0["name"]?.asString == "upsert_external_recording" })
        #expect(upsert["annotations"]?["readOnlyHint"]?.asBool == false)
        #expect(upsert["annotations"]?["destructiveHint"]?.asBool == false)
        #expect(upsert["annotations"]?["idempotentHint"]?.asBool == true)
    }

    @Test @MainActor
    func externalImportDirectCallRejectedWhenDisabled() async throws {
        let store = try await makeStore()
        let registry = MCPToolRegistry(
            store: store,
            writesEnabled: { true },
            externalImportEnabled: { false }
        )
        let result = await registry.call(name: "preview_external_recordings", arguments: ["recordings": []])
        #expect(result.isError)
        #expect(result.text.contains("External recording imports are disabled"))
    }

    @Test @MainActor
    func externalImportToolsPreviewAndIdempotentlyUpsertWithoutLeakingPaths() async throws {
        let store = try await makeStore()
        let registry = MCPToolRegistry(
            store: store,
            writesEnabled: { false },
            externalImportEnabled: { true }
        )
        let start = Date(timeIntervalSince1970: 1_700_000_000).formatted(.iso8601)
        let updated = Date(timeIntervalSince1970: 1_700_000_100).formatted(.iso8601)
        let preview = try payload(await registry.call(
            name: "preview_external_recordings",
            arguments: [
                "recordings": [[
                    "provider": "example",
                    "externalId": "mcp-note-1",
                    "title": "Mic test",
                    "startDate": .string(start),
                    "sourceUpdatedAt": .string(updated),
                    "transcriptCharacterCount": 0,
                    "transcriptSegmentCount": 0,
                ]],
            ]
        ))
        let previewItem = try #require(preview["results"]?.asArray?.first)
        #expect(previewItem["status"]?.asString == "new")
        #expect(previewItem["qualitySignals"]?.asArray?.contains(.string("likely_empty")) == true)
        #expect(previewItem["qualitySignals"]?.asArray?.contains(.string("likely_test")) == true)

        let arguments: JSONValue = [
            "provider": "example",
            "externalId": "mcp-note-1",
            "title": "Team sync",
            "startDate": .string(start),
            "sourceUpdatedAt": .string(updated),
            "durationSeconds": 600,
            "language": "en",
            "transcript": [
                "fullText": "Imported through MCP.",
                "detectedLanguage": "en",
            ],
        ]
        let first = await registry.call(name: "upsert_external_recording", arguments: arguments)
        #expect(!first.isError)
        #expect(!first.text.contains("/Users/"))
        let firstJSON = try payload(first)
        #expect(firstJSON["status"]?.asString == "imported")
        let recordingIDString = try #require(firstJSON["recordingId"]?.asString)
        let recordingID = try #require(UUID(uuidString: recordingIDString))
        let detail = await store.fetchRecordingDetail(recordingID: recordingID)
        #expect(detail?.audioFile == nil)
        #expect(detail?.source == RecordingSource.external.rawValue)
        #expect(detail?.transcript?.fullText == "Imported through MCP.")

        let replay = try payload(await registry.call(name: "upsert_external_recording", arguments: arguments))
        #expect(replay["status"]?.asString == "unchanged")
        #expect(await store.countExternalRecordingImports() == 1)
    }

    @Test @MainActor
    func writeCallRejectedWhenDisabled() async throws {
        let store = try await makeStore()
        let id = await seedTranscribed(store)
        let result = await makeRegistry(store, writes: false).call(
            name: "rename_recording",
            arguments: ["recordingId": .string(id.uuidString), "title": "Hacked"])
        #expect(result.isError)
        #expect(result.text.contains("disabled"))

        let detail = await store.fetchRecordingDetail(recordingID: id)
        #expect(detail?.title == "Roadmap sync")  // unchanged
    }

    // MARK: - Write tools

    @Test @MainActor
    func renameRecording() async throws {
        let store = try await makeStore()
        let id = await seedTranscribed(store)
        let result = await makeRegistry(store).call(
            name: "rename_recording",
            arguments: ["recordingId": .string(id.uuidString), "title": "Q3 Planning"])
        #expect(result.isError == false)
        let detail = await store.fetchRecordingDetail(recordingID: id)
        #expect(detail?.title == "Q3 Planning")
    }

    @Test @MainActor
    func addAndRemoveTag() async throws {
        let store = try await makeStore()
        let id = await seedTranscribed(store)
        let registry = makeRegistry(store)

        // "urgent" is a new category → needs allowNew on first write.
        _ = await registry.call(name: "add_tag",
                                arguments: ["recordingId": .string(id.uuidString), "tag": "urgent", "allowNew": .bool(true)])
        _ = await registry.call(name: "add_tag",
                                arguments: ["recordingId": .string(id.uuidString), "tag": "urgent"])  // dedupe (now known)
        var detail = await store.fetchRecordingDetail(recordingID: id)
        #expect(detail?.tags.filter { $0 == "urgent" }.count == 1)

        let removal = await registry.call(name: "remove_tag",
                                          arguments: ["recordingId": .string(id.uuidString), "tag": "urgent"])
        #expect(removal.isError == false)
        detail = await store.fetchRecordingDetail(recordingID: id)
        #expect(detail?.tags.contains("urgent") == false)
    }

    // MARK: - Controlled tagging (list_tags + vocab-aware add_tag)

    @Test @MainActor
    func listTagsReturnsVocabularyWithCounts() async throws {
        let store = try await makeStore()
        _ = await seedTranscribed(store)   // seeds "wiz"
        _ = await seedSummarized(store)    // also seeds "wiz" (via seedTranscribed) + "finance"

        let json = try payload(await makeRegistry(store).call(name: "list_tags", arguments: nil))
        let tags = json["tags"]?.asArray ?? []
        #expect(json["total"]?.asInt == tags.count)
        let wiz = tags.first { $0["tag"]?.asString == "wiz" }
        #expect(wiz?["count"]?.asInt == 2)  // used by both recordings
        // frequency-sorted: first entry's count >= last entry's count
        if let first = tags.first?["count"]?.asInt, let last = tags.last?["count"]?.asInt {
            #expect(first >= last)
        }
    }

    @Test @MainActor
    func addTagRejectsUnknownByDefault() async throws {
        let store = try await makeStore()
        let id = await seedTranscribed(store)
        let result = await makeRegistry(store).call(
            name: "add_tag",
            arguments: ["recordingId": .string(id.uuidString), "tag": "totally-novel-tag"])
        #expect(result.isError)
        #expect(result.text.contains("allowNew"))
        #expect(result.text.contains("list_tags"))
        // not written
        #expect(await store.fetchRecordingDetail(recordingID: id)?.tags.contains("totally-novel-tag") == false)
    }

    @Test @MainActor
    func addTagAllowNewReportsNewCategory() async throws {
        let store = try await makeStore()
        let id = await seedTranscribed(store)
        let result = await makeRegistry(store).call(
            name: "add_tag",
            arguments: ["recordingId": .string(id.uuidString), "tag": "novel", "allowNew": .bool(true)])
        #expect(result.isError == false)
        #expect(result.text.localizedCaseInsensitiveContains("new category"))
    }

    @Test @MainActor
    func addTagSaveFailureReturnsToolErrorAndDoesNotAddTag() async throws {
        let store = try await makeStore()
        let id = await seedTranscribed(store)
        await store._test_failNextSave()

        let result = await makeRegistry(store).call(
            name: "add_tag",
            arguments: [
                "recordingId": .string(id.uuidString),
                "tag": "save-failure-category",
                "allowNew": .bool(true),
            ]
        )

        #expect(result.isError)
        #expect(result.text.contains("could not be saved"))
        #expect(
            await store.fetchRecordingDetail(recordingID: id)?.tags
                .contains("save-failure-category") == false
        )
    }

    @Test @MainActor
    func addTagPreflightFailureReturnsToolErrorWithoutMutatingStagedWork() async throws {
        let store = try await makeStore()
        await store.setSpeakerMemoryConsentForTesting(true)
        let id = UUID()
        #expect(await store.createRecording(
            id: id,
            title: "Preflight",
            startDate: .now,
            segmentsDirURL: nil
        ))
        let profile = try #require(
            await store.createSpeakerProfile(displayName: "Staged profile")
        )
        let modelVersion = "mcp-add-tag-preflight-v1"
        #expect(await store.upsertVoiceSample(
            recordingID: id,
            rawLabel: "Speaker 1",
            embeddingData: SpeakerVoiceSample.serializeEmbedding([0.1, 0.2, 0.3, 0.4]),
            embeddingDimension: 4,
            sampleDuration: 30,
            nonOverlapRatio: 0.8,
            qualityScore: 24,
            modelVersion: modelVersion
        ))
        #expect(await store.attachSampleToProfile(
            recordingID: id,
            rawLabel: "Speaker 1",
            profileID: profile.id,
            persist: false
        ))
        await store.failNextStandalonePreflightSaveForTesting()

        let result = await makeRegistry(store).call(
            name: "add_tag",
            arguments: [
                "recordingId": .string(id.uuidString),
                "tag": "preflight-failure-category",
                "allowNew": .bool(true),
            ]
        )

        #expect(result.isError)
        #expect(result.text.contains("could not be saved"))
        #expect(
            await store.fetchRecordingDetail(recordingID: id)?.tags
                .contains("preflight-failure-category") == false
        )
        #expect(await store.flushPendingChanges())
        #expect(
            await store.fetchConfirmedSamples(modelVersion: modelVersion)
                .contains { $0.profileID == profile.id }
        )
        #expect(
            await store.fetchRecordingDetail(recordingID: id)?.tags
                .contains("preflight-failure-category") == false
        )
    }

    @Test @MainActor
    func addTagAcceptsKnownVocabWithoutAllowNew() async throws {
        let store = try await makeStore()
        _ = await seedTranscribed(store)   // seeds "wiz" into the library vocabulary
        // A fresh recording with NO tags, so "Wiz" is genuinely added (not a no-op).
        let target = UUID()
        await store.createRecording(id: target, title: "Plain", startDate: Date(), segmentsDirURL: nil)

        let result = await makeRegistry(store).call(
            name: "add_tag",
            arguments: ["recordingId": .string(target.uuidString), "tag": "Wiz"])  // known, different case, no allowNew
        #expect(result.isError == false)
        #expect(await store.fetchRecordingDetail(recordingID: target)?.tags.contains("wiz") == true)
    }

    @Test @MainActor
    func summaryIncludesTags() async throws {
        let store = try await makeStore()
        let id = await seedSummarized(store)
        _ = await store.addTag(recordingID: id, tag: "wiz")
        let json = try payload(await makeRegistry(store).call(
            name: "get_summary", arguments: ["recordingId": .string(id.uuidString)]))
        #expect(json["tags"]?.asArray?.contains(.string("wiz")) == true)
    }

    @Test @MainActor
    func addAndToggleActionItem() async throws {
        let store = try await makeStore()
        let id = await seedSummarized(store)
        let registry = makeRegistry(store)

        let added = await registry.call(name: "add_action_item",
                                        arguments: ["recordingId": .string(id.uuidString), "task": "Send recap email"])
        #expect(added.isError == false)

        let summary = try payload(await registry.call(
            name: "get_summary", arguments: ["recordingId": .string(id.uuidString)]))
        let items = summary["actionItems"]?.asArray ?? []
        #expect(items.count == 2)
        let newItem = items.first { $0["task"]?.asString == "Send recap email" }
        let itemID = try #require(newItem?["id"]?.asString)

        let toggled = await registry.call(name: "toggle_action_item", arguments: [
            "recordingId": .string(id.uuidString), "actionItemId": .string(itemID),
        ])
        #expect(toggled.isError == false)
        #expect(toggled.text.contains("completed"))
    }

    @Test @MainActor
    func addActionItemWithoutSummaryFails() async throws {
        let store = try await makeStore()
        let id = await seedTranscribed(store)
        let result = await makeRegistry(store).call(
            name: "add_action_item",
            arguments: ["recordingId": .string(id.uuidString), "task": "Impossible"])
        #expect(result.isError)
        #expect(result.text.contains("no summary"))
    }

    @Test @MainActor
    func unknownToolIsToolError() async throws {
        let store = try await makeStore()
        let result = await makeRegistry(store).call(name: "delete_everything", arguments: nil)
        #expect(result.isError)
    }

    // MARK: - set_speaker_name & speakers roster

    @Test @MainActor
    func transcriptIncludesSpeakersRoster() async throws {
        let store = try await makeStore()
        let id = await seedTranscribed(store)  // Speaker 1 → Alice, Speaker 2 unmapped

        let json = try payload(await makeRegistry(store).call(
            name: "get_transcript", arguments: ["recordingId": .string(id.uuidString)]))
        let roster = json["speakers"]?.asArray ?? []
        #expect(roster.count == 2)
        let one = roster.first { $0["label"]?.asString == "Speaker 1" }
        let two = roster.first { $0["label"]?.asString == "Speaker 2" }
        #expect(one?["resolvedName"]?.asString == "Alice")
        #expect(two?["resolvedName"] == .null)
    }

    @Test @MainActor
    func setSpeakerNameMapsAndResolves() async throws {
        let store = try await makeStore()
        let id = await seedTranscribed(store, speakerName: nil)  // both labels unmapped
        let registry = makeRegistry(store)

        let result = await registry.call(name: "set_speaker_name", arguments: [
            "recordingId": .string(id.uuidString), "speakerLabel": "Speaker 1", "name": "Dinesh",
        ])
        #expect(result.isError == false)
        #expect(result.text.contains("new"))

        let json = try payload(await registry.call(
            name: "get_transcript", arguments: ["recordingId": .string(id.uuidString)]))
        #expect(json["text"]?.asString?.contains("Dinesh: Segment 0") == true)
        let roster = json["speakers"]?.asArray ?? []
        #expect(roster.first { $0["label"]?.asString == "Speaker 1" }?["resolvedName"]?.asString == "Dinesh")
    }

    @Test @MainActor
    func setSpeakerNameReusesExistingProfileCaseInsensitive() async throws {
        let store = try await makeStore()
        let id = await seedTranscribed(store)  // creates profile "Alice"
        let before = await store.fetchSpeakerProfiles().count

        let result = await makeRegistry(store).call(name: "set_speaker_name", arguments: [
            "recordingId": .string(id.uuidString), "speakerLabel": "Speaker 2", "name": "alice",
        ])
        #expect(result.isError == false)
        #expect(result.text.contains("existing"))
        let after = await store.fetchSpeakerProfiles().count
        #expect(after == before)  // no duplicate profile
    }

    @Test @MainActor
    func setSpeakerNameRejectsUnknownLabel() async throws {
        let store = try await makeStore()
        let id = await seedTranscribed(store)

        let result = await makeRegistry(store).call(name: "set_speaker_name", arguments: [
            "recordingId": .string(id.uuidString), "speakerLabel": "Speaker 9", "name": "Ghost",
        ])
        #expect(result.isError)
        #expect(result.text.contains("does not appear"))
        #expect(result.text.contains("Speaker 1"))  // lists what IS present
    }

    // MARK: - RecordingsStore.addTag (store-level)

    @Test @MainActor
    func addTagAppendsAndDedupes() async throws {
        let store = try await makeStore()
        let id = UUID()
        await store.createRecording(id: id, title: "R", startDate: Date(), segmentsDirURL: nil)

        #expect(await store.addTag(recordingID: id, tag: "alpha"))
        #expect(await store.addTag(recordingID: id, tag: "alpha"))  // dedupe, still true
        #expect(await store.addTag(recordingID: id, tag: "  beta  "))  // trimmed

        let detail = await store.fetchRecordingDetail(recordingID: id)
        #expect(detail?.tags == ["alpha", "beta"])
    }

    @Test @MainActor
    func addTagRejectsEmptyAndUnknown() async throws {
        let store = try await makeStore()
        let id = UUID()
        await store.createRecording(id: id, title: "R", startDate: Date(), segmentsDirURL: nil)

        #expect(await store.addTag(recordingID: id, tag: "   ") == false)
        #expect(await store.addTag(recordingID: UUID(), tag: "x") == false)
    }

    // MARK: - Global action items

    @Test @MainActor
    func listActionItemsReturnsSourceContextAndNormalizedDeadline() async throws {
        let store = try await makeStore()
        let id = await seedSummarized(store, title: "Budget source")
        let detail = try #require(await store.fetchRecordingDetail(recordingID: id))
        let itemID = try #require(detail.summary?.actionItems.first?.id)
        #expect(await store.applyActionItemUpdate(
            recordingID: id,
            actionItemID: itemID,
            input: ActionItemUpdateInput(deadline: .set("2026-08-15"), priority: .high)
        ) != nil)

        let result = try payload(await makeRegistry(store).call(name: "list_action_items", arguments: [
            "completion": "all",
            "priority": "high",
        ]))
        let item = try #require(result["actionItems"]?.asArray?.first)
        #expect(item["recordingId"]?.asString == id.uuidString)
        #expect(item["recordingTitle"]?.asString == "Budget source")
        #expect(item["deadline"]?.asString == "2026-08-15")
        #expect(item["deadlineDate"]?.asString != nil)
        #expect(item["createdAt"]?.asString != nil)
        #expect(item["updatedAt"]?.asString != nil)
    }

    @Test @MainActor
    func updateActionItemSetsAndClearsAllMutableFieldsIdempotently() async throws {
        let store = try await makeStore()
        let id = await seedSummarized(store)
        let itemID = try #require(
            await store.fetchRecordingDetail(recordingID: id)?.summary?.actionItems.first?.id
        )
        let registry = makeRegistry(store)
        let arguments: JSONValue = [
            "recordingId": .string(id.uuidString),
            "actionItemId": .string(itemID.uuidString),
            "task": "Publish the budget",
            "assignee": "Andy",
            "deadline": "2026-08-15",
            "priority": "high",
            "isCompleted": true,
        ]
        let first = await registry.call(name: "update_action_item", arguments: arguments)
        let replay = await registry.call(name: "update_action_item", arguments: arguments)
        #expect(!first.isError)
        #expect(!replay.isError)

        let clear = try payload(await registry.call(name: "update_action_item", arguments: [
            "recordingId": .string(id.uuidString),
            "actionItemId": .string(itemID.uuidString),
            "assignee": .null,
            "deadline": .null,
        ]))
        #expect(clear["assignee"] == .null)
        #expect(clear["deadline"] == .null)
        #expect(clear["isCompleted"]?.asBool == true)
        #expect(clear["task"]?.asString == "Publish the budget")
    }
}
