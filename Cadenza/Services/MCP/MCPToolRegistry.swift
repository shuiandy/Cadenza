import Foundation
import os

/// The MCP tools backed by `RecordingsStore`: 5 core read + 6 core write
/// (gated by `writesEnabled`), plus 2 meeting-context read tools (gated by
/// `meetingContextEnabled`) and 1 meeting-prep write tool (`write_artifact`,
/// gated by BOTH `writesEnabled` AND `meetingContextEnabled` — turning
/// meeting-context off closes the entire meeting-prep MCP surface, including
/// writes). Gated tools are hidden from tools/list AND rejected on direct
/// call when their switch is off (defense in depth).
struct MCPToolRegistry: MCPToolProviding {
    let store: RecordingsStore
    let writesEnabled: @Sendable () -> Bool
    let externalImportEnabled: @Sendable () -> Bool
    let externalImportService: ExternalRecordingImportService
    /// meeting-context 读域(日历+人际历史,敏感度高于 transcript)——独立开关,默认关。
    var meetingContextEnabled: @Sendable () -> Bool
    /// 临近会议快照(AppState 从 CalendarManager 注入;测试注入固定数组)。
    var upcomingEvents: @Sendable () async -> [MeetingEvent]
    /// False while Cadenza's calendar cache is still cold. The MCP listener now comes
    /// up at the very top of `AppState.setup()` (so clients launching alongside Cadenza
    /// can connect), which is before calendar monitoring starts — without this the
    /// meeting tools would report an empty calendar as fact. Defaults to true so tests
    /// and any non-calendar host stay unaffected.
    /// async because the real signal lives on the MainActor while tool calls run on the
    /// MCP actor — a synchronous `assumeIsolated` read here traps at runtime.
    var calendarIsReady: @Sendable () async -> Bool

    init(
        store: RecordingsStore,
        writesEnabled: @escaping @Sendable () -> Bool,
        externalImportEnabled: @escaping @Sendable () -> Bool = { false },
        meetingContextEnabled: @escaping @Sendable () -> Bool = { false },
        upcomingEvents: @escaping @Sendable () async -> [MeetingEvent] = { [] },
        calendarIsReady: @escaping @Sendable () async -> Bool = { true },
        externalImportService: ExternalRecordingImportService? = nil
    ) {
        self.store = store
        self.writesEnabled = writesEnabled
        self.externalImportEnabled = externalImportEnabled
        self.meetingContextEnabled = meetingContextEnabled
        self.upcomingEvents = upcomingEvents
        self.calendarIsReady = calendarIsReady
        self.externalImportService = externalImportService ?? ExternalRecordingImportService(store: store)
    }

    private static let calendarColdMessage =
        "Cadenza's calendar hasn't finished loading yet (it just started). Retry in a few seconds."

    private static let log = Logger(subsystem: "com.shuiandy.Cadenza", category: "mcp")

    // MARK: - Constants

    static let defaultMaxChars = 40_000
    static let maxCharsRange = 1_000...200_000
    static let searchLimitRange = 1...25
    static let listLimitRange = 1...50

    private enum RecordingListSort: String, Codable, CaseIterable, Sendable {
        case dateDescending = "date_desc"
        case dateAscending = "date_asc"
        case updatedDescending = "updated_desc"
        case updatedAscending = "updated_asc"

        var isAscending: Bool {
            self == .dateAscending || self == .updatedAscending
        }

        var usesUpdatedAt: Bool {
            self == .updatedDescending || self == .updatedAscending
        }
    }

    private enum RecordingListStatus: String, Codable, CaseIterable, Sendable {
        case active
        case empty
        case transcribed
        case ready
        case trashed
        case all
    }

    private enum RecordingListSource: String, Codable, CaseIterable, Sendable {
        case captured
        case importedAudio = "imported_audio"
        case external
        case unknown
    }

    private struct RecordingListFilter: Codable, Equatable, Sendable {
        let startDate: Date?
        let endDate: Date?
        let updatedAfter: Date?
        let folderID: UUID?
        let tagKey: String?
        let source: RecordingListSource?
        let status: RecordingListStatus
        let sort: RecordingListSort
    }

    private struct RecordingListCursor: Codable, Sendable {
        let version: Int
        let filter: RecordingListFilter
        let resultFingerprint: String
        let lastSortDate: Date
        let lastID: UUID
    }

    private enum ActionItemCompletionFilter: String, Codable, Sendable {
        case open
        case completed
        case all
    }

    private struct ActionItemListFilter: Codable, Equatable, Sendable {
        let recordingID: UUID?
        let folderID: UUID?
        let tagKey: String?
        let assigneeKey: String?
        let completion: ActionItemCompletionFilter
        let deadlineFrom: Date?
        let deadlineTo: Date?
        let updatedAfter: Date?
        let priority: ActionPriority?
    }

    private struct ActionItemListCursor: Codable, Sendable {
        let version: Int
        let filter: ActionItemListFilter
        let resultFingerprint: String
        let lastUpdatedAt: Date
        let lastID: UUID
    }

    // MARK: - MCPToolProviding

    func toolDefinitions(context: MCPRequestContext) async -> [JSONValue] {
        var defs: [MCPToolDefinition] = []
        if context.allows(.recordingRead) { defs += Self.readDefinitions }
        if meetingContextEnabled() && context.allows(.calendarContextRead) {
            defs += Self.meetingContextDefinitions
        }
        if writesEnabled() && context.allows(.recordingWrite) { defs += Self.writeDefinitions }
        if writesEnabled() && meetingContextEnabled()
            && context.allows(.calendarContextRead) && context.allows(.prepWrite) {
            defs += Self.meetingPrepWriteDefinitions
        }
        if externalImportEnabled() && context.allows(.externalImportWrite) {
            defs += Self.externalImportDefinitions
        }
        return defs.map(\.asJSONValue)
    }

    func call(name: String, arguments: JSONValue?, context: MCPRequestContext) async -> MCPToolResult {
        switch name {
        case "search_transcripts", "list_recordings", "list_tags", "list_action_items", "get_transcript", "get_summary", "get_person_meeting_context":
            guard context.allows(.recordingRead) else { return Self.scopeDenied(.recordingRead) }
            switch name {
            case "search_transcripts": return await searchTranscripts(arguments)
            case "list_recordings": return await listRecordings(arguments)
            case "list_tags": return await listTags(arguments)
            case "list_action_items": return await listActionItems(arguments)
            case "get_transcript": return await getTranscript(arguments)
            case "get_summary": return await getSummary(arguments)
            default: return await getPersonMeetingContext(arguments)
            }
        case "list_upcoming_meetings", "get_meeting_context", "find_people":
            guard context.allows(.calendarContextRead) else { return Self.scopeDenied(.calendarContextRead) }
            guard meetingContextEnabled() else {
                return .failure("Meeting-context tools are disabled. Enable them in Cadenza → Settings → Integrations → AI Access (MCP).")
            }
            if name == "list_upcoming_meetings" { return await listUpcomingMeetings(arguments) }
            if name == "find_people" { return await findPeople(arguments) }
            return await getMeetingContext(arguments)
        case "write_artifact":
            guard context.allows(.calendarContextRead) else { return Self.scopeDenied(.calendarContextRead) }
            guard context.allows(.prepWrite) else { return Self.scopeDenied(.prepWrite) }
            guard writesEnabled() else {
                return .failure("Write operations are disabled. Enable them in Cadenza → Settings → Integrations → AI Access (MCP).")
            }
            guard meetingContextEnabled() else {
                return .failure("Meeting-context tools are disabled. Enable them in Cadenza → Settings → Integrations → AI Access (MCP).")
            }
            return await writeArtifact(arguments)
        case "preview_external_recordings", "upload_external_transcript_chunk",
             "upsert_external_recording", "set_external_import_disposition":
            guard context.allows(.externalImportWrite) else { return Self.scopeDenied(.externalImportWrite) }
            guard externalImportEnabled() else {
                return .failure("External recording imports are disabled. Enable them in Cadenza → Settings → Integrations → AI Access (MCP).")
            }
            return await callExternalImportTool(name: name, arguments: arguments)
        case "rename_recording", "add_tag", "remove_tag", "add_action_item", "toggle_action_item", "update_action_item", "set_speaker_name":
            guard context.allows(.recordingWrite) else { return Self.scopeDenied(.recordingWrite) }
            guard writesEnabled() else {
                return .failure("Write operations are disabled. Enable them in Cadenza → Settings → Integrations → AI Access (MCP).")
            }
            return await callWriteTool(name: name, arguments: arguments)
        default:
            return .failure("Unknown tool: \(name)")
        }
    }

    private static func scopeDenied(_ scope: MCPPermissionScope) -> MCPToolResult {
        .failure("This client is not authorized for scope \(scope.rawValue). Reconnect it from Cadenza Settings with the required access.")
    }

    // MARK: - Read tools

    private func searchTranscripts(_ args: JSONValue?) async -> MCPToolResult {
        guard let query = args?["query"]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !query.isEmpty else {
            return .failure("'query' (non-empty string) is required")
        }
        let limit = (args?["limit"]?.asInt ?? 10).clamped(to: Self.searchLimitRange)

        let hits = await store.searchRecordingDTOs(query: query, sortKey: "dateNewest", folderID: nil, tagFilter: nil)
        var results: [JSONValue] = []
        for hit in hits.prefix(limit) {
            let snippet = await snippet(for: query, hit: hit)
            results.append(.object([
                "id": .string(hit.id.uuidString),
                "title": .string(hit.title),
                "date": .string(iso(hit.startDate)),
                "durationSeconds": .number(hit.duration.rounded()),
                "tags": .array(hit.tags.map { .string($0) }),
                "snippet": .string(snippet),
            ]))
        }
        return .ok(encodeJSON(.object([
            "query": .string(query),
            "totalMatches": .number(Double(hits.count)),
            "results": .array(results),
        ])))
    }

    private func listRecordings(_ args: JSONValue?) async -> MCPToolResult {
        var folderID: UUID?
        if let folderName = args?["folderName"]?.asString, !folderName.isEmpty {
            let folders = await store.fetchFolders()
            guard let match = folders.first(where: { $0.name.localizedCaseInsensitiveCompare(folderName) == .orderedSame }) else {
                let names = folders.map(\.name).joined(separator: ", ")
                return .failure("Folder not found: \(folderName). Available folders: \(names.isEmpty ? "(none)" : names)")
            }
            folderID = match.id
        }

        var lowerBound: Date?
        var upperBound: Date?  // exclusive
        if let raw = args?["startDate"]?.asString {
            guard let parsed = Self.parseDate(raw, endOfDay: false) else {
                return .failure("Could not parse startDate: \(raw). Use ISO 8601 (e.g. 2026-06-01 or 2026-06-01T09:00:00Z).")
            }
            lowerBound = parsed
        }
        if let raw = args?["endDate"]?.asString {
            guard let parsed = Self.parseDate(raw, endOfDay: true) else {
                return .failure("Could not parse endDate: \(raw). Use ISO 8601 (e.g. 2026-06-07 or 2026-06-07T18:00:00Z).")
            }
            upperBound = parsed
        }

        let tagKey = args?["tag"]?.asString.flatMap { raw -> String? in
            let normalized = TagNormalizer.formatKey(raw)
            return normalized.isEmpty ? nil : normalized
        }
        let limit = (args?["limit"]?.asInt ?? 20).clamped(to: Self.listLimitRange)

        var updatedAfter: Date?
        if let raw = args?["updatedAfter"]?.asString {
            guard let parsed = Self.parseDate(raw, endOfDay: false) else {
                return .failure("Could not parse updatedAfter: \(raw). Use ISO 8601.")
            }
            updatedAfter = parsed
        }

        let source: RecordingListSource?
        if let raw = args?["source"]?.asString {
            guard let parsed = RecordingListSource(rawValue: raw) else {
                return .failure("'source' must be captured, imported_audio, external, or unknown")
            }
            source = parsed
        } else {
            source = nil
        }

        let status: RecordingListStatus
        if let raw = args?["status"]?.asString {
            guard let parsed = RecordingListStatus(rawValue: raw) else {
                return .failure("'status' must be active, empty, transcribed, ready, trashed, or all")
            }
            status = parsed
        } else {
            status = .active
        }

        let sort: RecordingListSort
        if let raw = args?["sort"]?.asString {
            guard let parsed = RecordingListSort(rawValue: raw) else {
                return .failure("'sort' must be date_desc, date_asc, updated_desc, or updated_asc")
            }
            sort = parsed
        } else {
            sort = .dateDescending
        }

        let filter = RecordingListFilter(
            startDate: lowerBound,
            endDate: upperBound,
            updatedAfter: updatedAfter,
            folderID: folderID,
            tagKey: tagKey,
            source: source,
            status: status,
            sort: sort
        )

        let suppliedCursor: RecordingListCursor?
        if let raw = args?["cursor"]?.asString {
            guard let decoded = Self.decodeListCursor(raw), decoded.version == 1 else {
                return .failure("Invalid cursor. Restart list_recordings without cursor.")
            }
            guard decoded.filter == filter else {
                return .failure("Cursor does not match the current filters. Restart list_recordings without cursor.")
            }
            suppliedCursor = decoded
        } else {
            suppliedCursor = nil
        }

        // Tag filtering happens in-memory, NOT via the store's tagFilter
        // parameter: `tags.contains` inside a #Predicate compiles to a SQL
        // string search that segfaults on rows whose tags column is NULL
        // (empty arrays) — _NSCoreDataStringSearch / CFStringGetLength(NULL).
        let active = await store.fetchRecordingDTOs(sortKey: "dateNewest", folderID: folderID, tagFilter: nil)
        var all: [RecordingDTO]
        switch status {
        case .trashed:
            all = await store.fetchTrashedRecordings()
        case .all:
            all = active
            all += await store.fetchTrashedRecordings()
        default:
            all = active
        }

        let filtered = all.filter { dto in
            if let folderID, dto.folderID != folderID { return false }
            if let tagKey,
               !dto.tags.contains(where: { TagNormalizer.formatKey($0) == tagKey }) {
                return false
            }
            if let lowerBound, dto.startDate < lowerBound { return false }
            if let upperBound, dto.startDate >= upperBound { return false }
            let dtoUpdatedAt = Self.updatedAt(for: dto)
            if let updatedAfter, dtoUpdatedAt <= updatedAfter { return false }
            if let source, Self.source(for: dto) != source { return false }

            let dtoStatus = Self.status(for: dto)
            switch status {
            case .active, .all:
                break
            case .empty, .transcribed, .ready, .trashed:
                if dtoStatus.rawValue != status.rawValue { return false }
            }
            return true
        }

        let sorted = filtered.sorted { lhs, rhs in
            let lhsDate = Self.sortDate(for: lhs, sort: sort)
            let rhsDate = Self.sortDate(for: rhs, sort: sort)
            if lhsDate != rhsDate {
                return sort.isAscending ? lhsDate < rhsDate : lhsDate > rhsDate
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        let resultFingerprint = Self.listFingerprint(sorted)

        let pageStart: Int
        if let suppliedCursor {
            guard suppliedCursor.resultFingerprint == resultFingerprint else {
                return .failure("Cursor expired because matching recordings changed. Restart list_recordings without cursor.")
            }
            guard let cursorIndex = sorted.firstIndex(where: { dto in
                dto.id == suppliedCursor.lastID
                    && Self.sortDate(for: dto, sort: sort) == suppliedCursor.lastSortDate
            }) else {
                return .failure("Cursor expired because its last recording is no longer available. Restart list_recordings without cursor.")
            }
            pageStart = cursorIndex + 1
        } else {
            pageStart = 0
        }

        let page = Array(sorted.dropFirst(pageStart).prefix(limit))

        let items: [JSONValue] = page.map { dto in
            .object([
                "id": .string(dto.id.uuidString),
                "title": .string(dto.title),
                "date": .string(iso(dto.startDate)),
                "createdAt": .string(iso(Self.createdAt(for: dto))),
                "updatedAt": .string(iso(Self.updatedAt(for: dto))),
                "source": .string(Self.source(for: dto).rawValue),
                "status": .string(Self.status(for: dto).rawValue),
                "durationSeconds": .number(dto.duration.rounded()),
                "tags": .array(dto.tags.map { .string($0) }),
                "meetingApp": dto.meetingApp.map { .string($0) } ?? .null,
                "hasTranscript": .bool(dto.hasTranscript),
                "hasSummary": .bool(dto.hasSummary),
            ])
        }

        var nextCursor: JSONValue = .null
        if pageStart + page.count < sorted.count, let last = page.last {
            let cursor = RecordingListCursor(
                version: 1,
                filter: filter,
                resultFingerprint: resultFingerprint,
                lastSortDate: Self.sortDate(for: last, sort: sort),
                lastID: last.id
            )
            guard let encoded = Self.encodeListCursor(cursor) else {
                return .failure("Could not create pagination cursor")
            }
            nextCursor = .string(encoded)
        }

        return .ok(encodeJSON(.object([
            "totalMatches": .number(Double(sorted.count)),
            "nextCursor": nextCursor,
            "recordings": .array(items),
        ])))
    }

    private static func createdAt(for recording: RecordingDTO) -> Date {
        recording.createdAt ?? recording.startDate
    }

    private static func updatedAt(for recording: RecordingDTO) -> Date {
        recording.updatedAt ?? recording.startDate
    }

    private static func source(for recording: RecordingDTO) -> RecordingListSource {
        guard let raw = recording.source,
              let source = RecordingListSource(rawValue: raw) else { return .unknown }
        return source
    }

    private static func status(for recording: RecordingDTO) -> RecordingListStatus {
        if recording.trashedDate != nil { return .trashed }
        if recording.hasSummary { return .ready }
        if recording.hasTranscript { return .transcribed }
        return .empty
    }

    private static func sortDate(for recording: RecordingDTO, sort: RecordingListSort) -> Date {
        sort.usesUpdatedAt ? updatedAt(for: recording) : recording.startDate
    }

    private static func encodeListCursor(_ cursor: RecordingListCursor) -> String? {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(cursor) else { return nil }
        return data.base64EncodedString()
    }

    private static func decodeListCursor(_ value: String) -> RecordingListCursor? {
        guard let data = Data(base64Encoded: value) else { return nil }
        return try? JSONDecoder().decode(RecordingListCursor.self, from: data)
    }

    /// Deterministic change detector for cursor invalidation. This is not a
    /// security primitive; bearer authentication protects the endpoint.
    private static func listFingerprint(_ recordings: [RecordingDTO]) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        let prime: UInt64 = 1_099_511_628_211

        func mix(_ value: String) {
            for byte in value.utf8 {
                hash ^= UInt64(byte)
                hash &*= prime
            }
            hash ^= 0xFF
            hash &*= prime
        }

        for recording in recordings {
            mix(recording.id.uuidString)
            mix(recording.title)
            mix(String(recording.startDate.timeIntervalSinceReferenceDate.bitPattern))
            mix(String(updatedAt(for: recording).timeIntervalSinceReferenceDate.bitPattern))
            mix(String(recording.duration.bitPattern))
            mix(recording.tags.joined(separator: "\u{1F}"))
            mix(recording.meetingApp ?? "")
            mix(source(for: recording).rawValue)
            mix(status(for: recording).rawValue)
            mix(recording.hasTranscript ? "1" : "0")
            mix(recording.hasSummary ? "1" : "0")
        }
        return String(hash, radix: 16)
    }

    private func listTags(_ args: JSONValue?) async -> MCPToolResult {
        let tags = await store.distinctTags(language: nil)
        let items: [JSONValue] = tags.map { .object(["tag": .string($0.tag), "count": .number(Double($0.count))]) }
        return .ok(encodeJSON(.object([
            "total": .number(Double(tags.count)),
            "tags": .array(items),
        ])))
    }

    private func listActionItems(_ args: JSONValue?) async -> MCPToolResult {
        let recordingID: UUID?
        if let raw = args?["recordingId"]?.asString {
            guard let parsed = UUID(uuidString: raw) else {
                return .failure("'recordingId' must be a UUID string")
            }
            recordingID = parsed
        } else {
            recordingID = nil
        }

        var folderID: UUID?
        if let folderName = args?["folderName"]?.asString, !folderName.isEmpty {
            let folders = await store.fetchFolders()
            guard let folder = folders.first(where: {
                $0.name.localizedCaseInsensitiveCompare(folderName) == .orderedSame
            }) else {
                return .failure("Folder not found: \(folderName)")
            }
            folderID = folder.id
        }

        let tagKey = args?["tag"]?.asString.flatMap { value -> String? in
            let normalized = TagNormalizer.formatKey(value)
            return normalized.isEmpty ? nil : normalized
        }
        let normalizedAssignee = args?["assignee"]?.asString.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        let assigneeKey = normalizedAssignee?.isEmpty == false ? normalizedAssignee : nil

        let completion: ActionItemCompletionFilter
        if let raw = args?["completion"]?.asString {
            guard let parsed = ActionItemCompletionFilter(rawValue: raw) else {
                return .failure("'completion' must be open, completed, or all")
            }
            completion = parsed
        } else {
            completion = .open
        }

        func parsedDate(_ key: String, endOfDay: Bool = false) -> (date: Date?, error: String?) {
            guard let raw = args?[key]?.asString else { return (nil, nil) }
            guard let date = Self.parseDate(raw, endOfDay: endOfDay) else {
                return (nil, "Could not parse \(key): \(raw). Use ISO 8601.")
            }
            return (date, nil)
        }

        let parsedDeadlineFrom = parsedDate("deadlineFrom")
        if let error = parsedDeadlineFrom.error { return .failure(error) }
        let deadlineFrom = parsedDeadlineFrom.date
        let parsedDeadlineTo = parsedDate("deadlineTo", endOfDay: true)
        if let error = parsedDeadlineTo.error { return .failure(error) }
        let deadlineTo = parsedDeadlineTo.date
        let parsedUpdatedAfter = parsedDate("updatedAfter")
        if let error = parsedUpdatedAfter.error { return .failure(error) }
        let updatedAfter = parsedUpdatedAfter.date

        let priority: ActionPriority?
        if let raw = args?["priority"]?.asString {
            guard let parsed = ActionPriority(rawValue: raw) else {
                return .failure("'priority' must be high, medium, or low")
            }
            priority = parsed
        } else {
            priority = nil
        }

        let filter = ActionItemListFilter(
            recordingID: recordingID,
            folderID: folderID,
            tagKey: tagKey,
            assigneeKey: assigneeKey,
            completion: completion,
            deadlineFrom: deadlineFrom,
            deadlineTo: deadlineTo,
            updatedAfter: updatedAfter,
            priority: priority
        )

        let suppliedCursor: ActionItemListCursor?
        if let raw = args?["cursor"]?.asString {
            guard let data = Data(base64Encoded: raw),
                  let decoded = try? JSONDecoder().decode(ActionItemListCursor.self, from: data),
                  decoded.version == 1 else {
                return .failure("Invalid cursor. Restart list_action_items without cursor.")
            }
            guard decoded.filter == filter else {
                return .failure("Cursor does not match the current filters. Restart list_action_items without cursor.")
            }
            suppliedCursor = decoded
        } else {
            suppliedCursor = nil
        }

        let all = await store.fetchActionItemRecords()
        let filtered = all.filter { item in
            if let recordingID, item.recordingID != recordingID { return false }
            if let folderID, item.folderID != folderID { return false }
            if let tagKey, !item.tags.contains(where: { TagNormalizer.formatKey($0) == tagKey }) { return false }
            if let assigneeKey, item.assignee?.lowercased() != assigneeKey { return false }
            switch completion {
            case .open where item.isCompleted: return false
            case .completed where !item.isCompleted: return false
            default: break
            }
            if let deadlineFrom {
                guard let deadline = item.deadlineDate, deadline >= deadlineFrom else { return false }
            }
            if let deadlineTo {
                guard let deadline = item.deadlineDate, deadline < deadlineTo else { return false }
            }
            if let updatedAfter, item.updatedAt <= updatedAfter { return false }
            if let priority, item.priority != priority { return false }
            return true
        }.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id.uuidString < $1.id.uuidString
        }

        let fingerprint = Self.actionItemFingerprint(filtered)
        let pageStart: Int
        if let cursor = suppliedCursor {
            guard cursor.resultFingerprint == fingerprint else {
                return .failure("Cursor expired because matching action items changed. Restart list_action_items without cursor.")
            }
            guard let index = filtered.firstIndex(where: {
                $0.id == cursor.lastID && $0.updatedAt == cursor.lastUpdatedAt
            }) else {
                return .failure("Cursor expired because its last action item is unavailable.")
            }
            pageStart = index + 1
        } else {
            pageStart = 0
        }

        let limit = (args?["limit"]?.asInt ?? 20).clamped(to: Self.listLimitRange)
        let page = Array(filtered.dropFirst(pageStart).prefix(limit))
        let values = page.map(Self.actionItemJSON)

        var nextCursor: JSONValue = .null
        if pageStart + page.count < filtered.count, let last = page.last {
            let cursor = ActionItemListCursor(
                version: 1,
                filter: filter,
                resultFingerprint: fingerprint,
                lastUpdatedAt: last.updatedAt,
                lastID: last.id
            )
            if let data = try? JSONEncoder().encode(cursor) {
                nextCursor = .string(data.base64EncodedString())
            }
        }

        return .ok(encodeJSON(.object([
            "totalMatches": .number(Double(filtered.count)),
            "nextCursor": nextCursor,
            "actionItems": .array(values),
        ])))
    }

    private static func actionItemJSON(_ item: ActionItemRecordDTO) -> JSONValue {
        .object([
            "id": .string(item.id.uuidString),
            "recordingId": .string(item.recordingID.uuidString),
            "recordingTitle": .string(item.recordingTitle),
            "recordingDate": .string(item.recordingDate.formatted(.iso8601)),
            "folderName": item.folderName.map(JSONValue.string) ?? .null,
            "tags": .array(item.tags.map(JSONValue.string)),
            "task": .string(item.task),
            "assignee": item.assignee.map(JSONValue.string) ?? .null,
            "deadline": item.rawDeadline.map(JSONValue.string) ?? .null,
            "deadlineDate": item.deadlineDate.map { .string($0.formatted(.iso8601)) } ?? .null,
            "priority": .string(item.priority.rawValue),
            "isCompleted": .bool(item.isCompleted),
            "createdAt": .string(item.createdAt.formatted(.iso8601)),
            "updatedAt": .string(item.updatedAt.formatted(.iso8601)),
        ])
    }

    private static func actionItemFingerprint(_ items: [ActionItemRecordDTO]) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        let prime: UInt64 = 1_099_511_628_211

        func mix(_ value: String) {
            for byte in value.utf8 {
                hash ^= UInt64(byte)
                hash &*= prime
            }
            hash ^= 0xFF
            hash &*= prime
        }

        for item in items {
            mix(item.id.uuidString)
            mix(item.recordingID.uuidString)
            mix(item.recordingTitle)
            mix(String(item.recordingDate.timeIntervalSinceReferenceDate.bitPattern))
            mix(item.folderID?.uuidString ?? "")
            mix(item.folderName ?? "")
            mix(item.tags.joined(separator: "\u{1F}"))
            mix(item.task)
            mix(item.assignee ?? "")
            mix(item.rawDeadline ?? "")
            mix(item.deadlineDate.map { String($0.timeIntervalSinceReferenceDate.bitPattern) } ?? "")
            mix(item.priority.rawValue)
            mix(item.isCompleted ? "1" : "0")
            mix(String(item.createdAt.timeIntervalSinceReferenceDate.bitPattern))
            mix(String(item.updatedAt.timeIntervalSinceReferenceDate.bitPattern))
        }
        return String(hash, radix: 16)
    }

    private func findPeople(_ args: JSONValue?) async -> MCPToolResult {
        guard let query = args?["query"]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !query.isEmpty else {
            return .failure("'query' (name or email) is required")
        }
        guard await calendarIsReady() else { return .failure(Self.calendarColdMessage) }

        let normalized = query.lowercased()
        var candidates: [JSONValue] = []

        var seenEmails: Set<String> = []
        for attendee in await upcomingEvents().flatMap(\.attendees) where !attendee.isCurrentUser {
            let email = attendee.email.lowercased()
            guard seenEmails.insert(email).inserted else { continue }
            let name = attendee.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let confidence: Double?
            if email == normalized {
                confidence = 1.0
            } else if name.lowercased() == normalized {
                confidence = 0.95
            } else if email.contains(normalized) || name.lowercased().contains(normalized) {
                confidence = 0.72
            } else {
                confidence = nil
            }
            guard let confidence else { continue }
            candidates.append(.object([
                "personId": .string("email:\(email)"),
                "displayName": .string(name.isEmpty ? email : name),
                "email": .string(email),
                "confidence": .number(confidence),
                "evidence": .array([.string("upcoming_calendar_attendee")]),
                "historicalMeetingCount": .number(0),
            ]))
        }

        for evidence in await store.fetchPersonProfileEvidence() {
            let profile = evidence.profile
            let name = profile.displayName.lowercased()
            let aliases = profile.aliases.map { $0.lowercased() }
            let confidence: Double?
            if name == normalized {
                confidence = 0.92
            } else if aliases.contains(normalized) {
                confidence = 0.88
            } else if name.contains(normalized) || aliases.contains(where: { $0.contains(normalized) }) {
                confidence = 0.68
            } else {
                confidence = nil
            }
            guard let confidence else { continue }
            var evidenceKinds = ["speaker_profile"]
            if evidence.recordingCount > 0 { evidenceKinds.append("historical_meetings") }
            candidates.append(.object([
                "personId": .string("speaker:\(profile.id.uuidString)"),
                "displayName": .string(profile.displayName),
                "email": .null,
                "teamOrOrg": profile.teamOrOrg.map(JSONValue.string) ?? .null,
                "confidence": .number(confidence),
                "evidence": .array(evidenceKinds.map(JSONValue.string)),
                "historicalMeetingCount": .number(Double(evidence.recordingCount)),
                "recentMeetings": .array(evidence.recentMeetings.prefix(3).map(Self.personMeetingJSON)),
            ]))
        }

        candidates.sort { lhs, rhs in
            let lhsConfidence = lhs["confidence"]?.asDouble ?? 0
            let rhsConfidence = rhs["confidence"]?.asDouble ?? 0
            if lhsConfidence != rhsConfidence { return lhsConfidence > rhsConfidence }
            return (lhs["personId"]?.asString ?? "") < (rhs["personId"]?.asString ?? "")
        }
        let limit = (args?["limit"]?.asInt ?? 10).clamped(to: 1...25)
        let page = Array(candidates.prefix(limit))
        return .ok(encodeJSON(.object([
            "query": .string(query),
            "totalCandidates": .number(Double(candidates.count)),
            "requiresDisambiguation": .bool(candidates.count > 1),
            "candidates": .array(page),
            "guidance": .string(candidates.count > 1
                ? "Multiple candidates matched. Use the evidence and personId; Cadenza did not auto-map them."
                : "No automatic speaker mapping was changed."),
        ])))
    }

    private func getPersonMeetingContext(_ args: JSONValue?) async -> MCPToolResult {
        guard let personID = args?["personId"]?.asString else {
            return .failure("'personId' from find_people is required")
        }
        if personID.hasPrefix("email:") {
            return .ok(encodeJSON(.object([
                "personId": .string(personID),
                "meetings": .array([]),
                "reason": .string("Calendar attendee identities are not automatically linked to speaker profiles. Select an explicit speaker candidate to read recording history."),
            ])))
        }
        guard personID.hasPrefix("speaker:"),
              let profileID = UUID(uuidString: String(personID.dropFirst("speaker:".count))) else {
            return .failure("Invalid personId. Use an email: or speaker: candidate returned by find_people.")
        }
        let limit = (args?["limit"]?.asInt ?? 10).clamped(to: 1...50)
        guard let meetings = await store.fetchPersonMeetingContext(profileID: profileID, limit: limit) else {
            return .failure("Speaker profile not found")
        }
        return .ok(encodeJSON(.object([
            "personId": .string(personID),
            "meetings": .array(meetings.map(Self.personMeetingJSON)),
        ])))
    }

    private static func personMeetingJSON(_ meeting: PersonMeetingContextDTO) -> JSONValue {
        .object([
            "recordingId": .string(meeting.recordingID.uuidString),
            "title": .string(meeting.title),
            "date": .string(meeting.date.formatted(.iso8601)),
            "overview": meeting.overview.map(JSONValue.string) ?? .null,
            "decisions": .array(meeting.decisions.map(JSONValue.string)),
            "openActionItems": .array(meeting.openActionItems.map(JSONValue.string)),
        ])
    }

    private func getTranscript(_ args: JSONValue?) async -> MCPToolResult {
        guard let id = recordingID(from: args) else {
            return .failure("'recordingId' (UUID string) is required")
        }
        guard let detail = await fetchActiveDetail(id) else {
            return .failure("Recording not found: \(id.uuidString)")
        }
        guard let transcript = detail.transcript,
              !(transcript.segments.isEmpty && transcript.fullText.isEmpty) else {
            return .failure("This recording has no transcript yet.")
        }

        let format = args?["format"]?.asString ?? "text"
        guard format == "text" || format == "segments" else {
            return .failure("'format' must be \"text\" or \"segments\"")
        }
        let maxChars = (args?["maxChars"]?.asInt ?? Self.defaultMaxChars).clamped(to: Self.maxCharsRange)
        let windowStart = args?["startTime"]?.asDouble
        let windowEnd = args?["endTime"]?.asDouble

        var payload: [String: JSONValue] = [
            "recordingId": .string(id.uuidString),
            "title": .string(detail.title),
            "date": .string(iso(detail.startDate)),
            "format": .string(format),
        ]

        if transcript.segments.isEmpty {
            // Segment-less transcript: paginate raw fullText by character offset.
            let full = transcript.fullText
            var offset = 0
            if let cursor = args?["cursor"]?.asString {
                guard cursor.hasPrefix("c:"), let parsed = Int(cursor.dropFirst(2)), parsed >= 0, parsed < full.count else {
                    return .failure("Invalid cursor: \(cursor)")
                }
                offset = parsed
            }
            let start = full.index(full.startIndex, offsetBy: offset)
            let end = full.index(start, offsetBy: maxChars, limitedBy: full.endIndex) ?? full.endIndex
            payload["text"] = .string(String(full[start..<end]))
            if end < full.endIndex {
                payload["nextCursor"] = .string("c:\(offset + full.distance(from: start, to: end))")
            }
            return .ok(encodeJSON(.object(payload)))
        }

        // Segment path. Cursor is a GLOBAL index into the full segments array;
        // the time window only filters, it never renumbers — so a client can
        // change the window between calls without invalidating its cursor.
        let segments = transcript.segments
        var startIndex = 0
        if let cursor = args?["cursor"]?.asString {
            guard cursor.hasPrefix("s:"), let parsed = Int(cursor.dropFirst(2)), parsed >= 0, parsed < segments.count else {
                return .failure("Invalid cursor: \(cursor)")
            }
            startIndex = parsed
        }

        let speakerNames = Dictionary(detail.speakerMappings.map { ($0.rawLabel, $0.profileName) },
                                      uniquingKeysWith: { first, _ in first })

        // Roster over the FULL transcript (not just this page): tells the
        // client which labels are placeholders (resolvedName null) vs known
        // people, so it never mistakes "Speaker 1" for a real name.
        var seenLabels = Set<String>()
        var roster: [JSONValue] = []
        for segment in segments {
            guard let label = segment.speaker, seenLabels.insert(label).inserted else { continue }
            roster.append(.object([
                "label": .string(label),
                "resolvedName": speakerNames[label].map { .string($0) } ?? .null,
            ]))
        }
        payload["speakers"] = .array(roster)

        var textLines: [String] = []
        var segmentObjects: [JSONValue] = []
        var usedChars = 0
        var nextCursor: String?

        for index in startIndex..<segments.count {
            let segment = segments[index]
            if let windowEnd, segment.startTime > windowEnd { break }
            if let windowStart, segment.endTime < windowStart { continue }

            let speaker = segment.speaker.map { speakerNames[$0] ?? $0 }
            let line = speaker.map { "\($0): \(segment.text)" } ?? segment.text

            // Always include at least one segment per page so a single
            // oversized segment can't stall the cursor (bounded overshoot).
            if usedChars > 0, usedChars + line.count > maxChars {
                nextCursor = "s:\(index)"
                break
            }
            usedChars += line.count
            if format == "text" {
                textLines.append(line)
            } else {
                segmentObjects.append(.object([
                    "start": .number(segment.startTime),
                    "end": .number(segment.endTime),
                    "speaker": speaker.map { .string($0) } ?? .null,
                    "text": .string(segment.text),
                ]))
            }
        }

        payload["totalSegments"] = .number(Double(segments.count))
        if format == "text" {
            payload["text"] = .string(textLines.joined(separator: "\n"))
        } else {
            payload["segments"] = .array(segmentObjects)
        }
        if let nextCursor { payload["nextCursor"] = .string(nextCursor) }
        return .ok(encodeJSON(.object(payload)))
    }

    private func getSummary(_ args: JSONValue?) async -> MCPToolResult {
        guard let id = recordingID(from: args) else {
            return .failure("'recordingId' (UUID string) is required")
        }
        guard let detail = await fetchActiveDetail(id) else {
            return .failure("Recording not found: \(id.uuidString)")
        }
        guard let summary = detail.summary else {
            return .failure("This recording has no summary yet.")
        }

        let actionItems: [JSONValue] = summary.actionItems.map { item in
            .object([
                "id": .string(item.id.uuidString),
                "task": .string(item.task),
                "assignee": item.assignee.map { .string($0) } ?? .null,
                "deadline": item.deadline.map { .string($0) } ?? .null,
                "isCompleted": .bool(item.isCompleted),
                "priority": .string(item.priority),
            ])
        }
        let chapters: [JSONValue] = summary.chapters.map { chapter in
            .object([
                "title": .string(chapter.title),
                "startSeconds": .number(chapter.startSeconds),
                "summary": .string(chapter.summary),
            ])
        }
        return .ok(encodeJSON(.object([
            "recordingId": .string(id.uuidString),
            "title": .string(detail.title),
            "date": .string(iso(detail.startDate)),
            "tags": .array(detail.tags.map { .string($0) }),
            "meetingType": detail.meetingType.map { .string($0) } ?? .null,
            "summaryId": .string(summary.id.uuidString),
            "reviewStage": summary.generationMetadata.map { .string($0.stage.rawValue) } ?? .null,
            "sourceChanged": summary.generationMetadata.map { .bool($0.sourceChanged) } ?? .null,
            "overview": .string(summary.overview),
            "keyPoints": .array(summary.keyPoints.map { .string($0) }),
            "decisions": .array(summary.decisions.map { .string($0) }),
            "followUps": .array(summary.followUps.map { .string($0) }),
            "yourTasks": .array(summary.yourTasks.map { .string($0) }),
            "actionItems": .array(actionItems),
            "chapters": .array(chapters),
        ])))
    }

    // MARK: - Meeting-prep tools (Phase 5)

    static let withinHoursRange = 1...168

    private func listUpcomingMeetings(_ args: JSONValue?) async -> MCPToolResult {
        let withinHours = (args?["withinHours"]?.asInt ?? 24).clamped(to: Self.withinHoursRange)
        let now = Date()
        let cutoff = now.addingTimeInterval(Double(withinHours) * 3600)
        guard await calendarIsReady() else { return .failure(Self.calendarColdMessage) }
        let events = await upcomingEvents()
            .filter { $0.endDate > now && $0.startDate < cutoff }
            .sorted { $0.startDate < $1.startDate }

        var meetings: [JSONValue] = []
        for event in events {
            let slot = ArtifactTargetKey.slotKey(kind: "meetingPrep", targetType: "calendarEvent",
                                                 targetKey: event.artifactTargetKey)
            let artifact = await store.fetchArtifact(slotKey: slot)
            let attendees: [JSONValue] = event.attendees.map {
                .object(["name": .string($0.name), "email": .string($0.email),
                         "isOrganizer": .bool($0.isOrganizer), "status": .string($0.status.rawValue),
                         "isCurrentUser": .bool($0.isCurrentUser)])
            }
            meetings.append(.object([
                "occurrenceKey": .string(event.artifactTargetKey),
                "title": .string(event.title),
                "start": .string(iso(event.startDate)),
                "end": .string(iso(event.endDate)),
                "attendees": .array(attendees),
                "hasPrep": .bool(artifact != nil),
                "prepSource": artifact.map { .string($0.provenanceSource) } ?? .null,
                "prepStatus": artifact.map { .string($0.status) } ?? .null,
                "stale": .bool(artifact?.staleReason != nil),
            ]))
        }
        return .ok(encodeJSON(.object([
            "now": .string(iso(now)),
            "meetings": .array(meetings),
        ])))
    }

    private func getMeetingContext(_ args: JSONValue?) async -> MCPToolResult {
        guard let key = args?["occurrenceKey"]?.asString, !key.isEmpty else {
            return .failure("'occurrenceKey' (from list_upcoming_meetings) is required")
        }
        guard await calendarIsReady() else { return .failure(Self.calendarColdMessage) }
        let events = await upcomingEvents()
        guard let event = events.first(where: { $0.artifactTargetKey == key }) else {
            return .failure("No upcoming meeting matches that occurrenceKey (\(events.count) upcoming). Call list_upcoming_meetings for current keys.")
        }
        let maxChars = (args?["maxChars"]?.asInt ?? Self.defaultMaxChars).clamped(to: Self.maxCharsRange)
        var context = await MeetingPrepContextBuilder.assemble(event: event, store: store)
        var truncated = false
        if context.count > maxChars {
            context = String(context.prefix(maxChars))
            truncated = true
        }
        return .ok(encodeJSON(.object([
            "occurrenceKey": .string(key),
            "title": .string(event.title),
            "context": .string(context),
            "truncated": .bool(truncated),
            "suggestedStructure": .string("## TL;DR / ## Where we left off / ## Open items to follow up / ## Attendees / ## Suggested agenda & questions to ask / ## Links"),
        ])))
    }

    // MARK: - Write tools

    /// Saves an externally-authored prep brief. provenance/status are HARD-CODED
    /// to external/mcp/ready — never read from caller input — so an agent can
    /// never write a slot as builtin/generating/failed (spec §4/§8, review R1 #3).
    private func writeArtifact(_ args: JSONValue?) async -> MCPToolResult {
        if let kind = args?["kind"]?.asString, kind != "meetingPrep" {
            return .failure("Unsupported kind: \(kind). Only 'meetingPrep' is supported.")
        }
        if let targetType = args?["targetType"]?.asString, targetType != "calendarEvent" {
            return .failure("Unsupported targetType: \(targetType). Only 'calendarEvent' is supported.")
        }
        guard let key = args?["occurrenceKey"]?.asString, !key.isEmpty else {
            return .failure("'occurrenceKey' (from list_upcoming_meetings) is required")
        }
        guard let body = args?["bodyMarkdown"]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !body.isEmpty else {
            return .failure("'bodyMarkdown' (non-empty Markdown string) is required")
        }
        guard await calendarIsReady() else { return .failure(Self.calendarColdMessage) }
        let events = await upcomingEvents()
        guard let event = events.first(where: { $0.artifactTargetKey == key }) else {
            return .failure("No upcoming meeting matches that occurrenceKey (\(events.count) upcoming). Call list_upcoming_meetings for current keys.")
        }

        // provenance/status 固定为 external:mcp/ready —— 外部写无条件覆盖(spec §4),
        // 调用方不能指定 provenance,防止把槽位写成 builtin/generating/failed。
        let candidate = ArtifactCandidate(
            kind: .meetingPrep, targetType: .calendarEvent, targetKey: event.artifactTargetKey,
            bodyMarkdown: body, provenanceSource: .external, provenanceDetail: "mcp",
            status: .ready, generationID: nil, generatingStartedAt: nil,
            errorClass: nil, errorMessage: nil,
            targetStartDate: event.startDate, targetEndDate: event.endDate,
            targetFingerprint: MeetingPrepFingerprint.compute(event),
            contextBuiltAt: Date(), staleReason: nil)
        guard await store.writeExternalArtifact(candidate) else {
            return .failure("Failed to save the prep brief (store write failed).")
        }
        Self.log.info("MCP write_artifact: prep saved for \(event.title, privacy: .private(mask: .hash))")
        NotificationCenter.default.post(name: .cadenzaArtifactsChanged, object: nil)
        return .ok(encodeJSON(.object([
            "saved": .bool(true),
            "occurrenceKey": .string(key),
            "provenance": .string("external:mcp"),
        ])))
    }

    private func callWriteTool(name: String, arguments args: JSONValue?) async -> MCPToolResult {
        guard let id = recordingID(from: args) else {
            return .failure("'recordingId' (UUID string) is required")
        }
        guard let detail = await fetchActiveDetail(id) else {
            return .failure("Recording not found: \(id.uuidString)")
        }

        switch name {
        case "rename_recording":
            guard let title = args?["title"]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty else {
                return .failure("'title' (non-empty string) is required")
            }
            guard await store.updateTitle(recordingID: id, title: title) else {
                return .failure("Rename failed")
            }
            Self.log.notice("mcp write rename_recording recording=\(id.uuidString, privacy: .public)")
            return .ok("Renamed recording to \"\(title)\"")

        case "add_tag":
            guard let tag = args?["tag"]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !tag.isEmpty else {
                return .failure("'tag' (non-empty string) is required")
            }
            let allowNew = args?["allowNew"]?.asBool ?? false
            switch await store.addTag(recordingID: id, tag: tag, allowNew: allowNew) {
            case .added(let canonical, let isNew):
                Self.log.notice("mcp write add_tag recording=\(id.uuidString, privacy: .public) tag=\(canonical, privacy: .public) new=\(isNew)")
                return .ok(isNew ? "Added tag \"\(canonical)\" (new category created)" : "Added tag \"\(canonical)\"")
            case .rejectedUnknown(let canonical):
                return .failure("\"\(canonical)\" is not an existing tag. Pick one from list_tags, or pass allowNew:true to create it as a new category.")
            case .alreadyPresent(let canonical):
                return .ok("Recording already has tag \"\(canonical)\"")
            case .invalid:
                return .failure("Not a valid tag (it may be blocked, empty, or contain only unsupported characters).")
            case .recordingNotFound:
                return .failure("Recording not found: \(id.uuidString)")
            case .persistenceFailed:
                return .failure("Adding tag failed because the change could not be saved. No tag was added.")
            }

        case "remove_tag":
            guard let tag = args?["tag"]?.asString, !tag.isEmpty else {
                return .failure("'tag' (non-empty string) is required")
            }
            guard await store.removeTag(recordingID: id, tag: tag) else {
                return .failure("Removing tag failed")
            }
            Self.log.notice("mcp write remove_tag recording=\(id.uuidString, privacy: .public) tag=\(tag, privacy: .public)")
            return .ok("Removed tag \"\(tag)\"")

        case "add_action_item":
            guard let task = args?["task"]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !task.isEmpty else {
                return .failure("'task' (non-empty string) is required")
            }
            guard await store.addActionItem(recordingID: id, task: task) else {
                return .failure("This recording has no summary yet — action items live on the summary.")
            }
            Self.log.notice("mcp write add_action_item recording=\(id.uuidString, privacy: .public)")
            return .ok("Added action item \"\(task)\"")

        case "toggle_action_item":
            guard let itemIDString = args?["actionItemId"]?.asString, let itemID = UUID(uuidString: itemIDString) else {
                return .failure("'actionItemId' (UUID string) is required")
            }
            guard await store.toggleActionItem(recordingID: id, actionItemID: itemID) else {
                return .failure("Action item not found: \(itemIDString)")
            }
            Self.log.notice("mcp write toggle_action_item recording=\(id.uuidString, privacy: .public) item=\(itemIDString, privacy: .public)")
            let nowCompleted = await fetchActiveDetail(id)?.summary?.actionItems
                .first(where: { $0.id == itemID })?.isCompleted
            let state = nowCompleted.map { $0 ? "completed" : "open" } ?? "unknown"
            return .ok("Action item toggled; it is now \(state).")

        case "update_action_item":
            guard let itemIDString = args?["actionItemId"]?.asString,
                  let itemID = UUID(uuidString: itemIDString) else {
                return .failure("'actionItemId' (UUID string) is required")
            }

            var input = ActionItemUpdateInput()
            var hasUpdate = false
            if let taskValue = args?["task"] {
                guard let task = taskValue.asString?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !task.isEmpty else {
                    return .failure("'task' must be a non-empty string")
                }
                input.task = task
                hasUpdate = true
            }
            if let assigneeValue = args?["assignee"] {
                if assigneeValue == .null {
                    input.assignee = .set(nil)
                } else if let assignee = assigneeValue.asString {
                    input.assignee = .set(assignee)
                } else {
                    return .failure("'assignee' must be a string or null")
                }
                hasUpdate = true
            }
            if let deadlineValue = args?["deadline"] {
                if deadlineValue == .null {
                    input.deadline = .set(nil)
                } else if let deadline = deadlineValue.asString {
                    input.deadline = .set(deadline)
                } else {
                    return .failure("'deadline' must be a string or null")
                }
                hasUpdate = true
            }
            if let rawPriority = args?["priority"]?.asString {
                guard let priority = ActionPriority(rawValue: rawPriority) else {
                    return .failure("'priority' must be high, medium, or low")
                }
                input.priority = priority
                hasUpdate = true
            }
            if let completionValue = args?["isCompleted"] {
                guard let isCompleted = completionValue.asBool else {
                    return .failure("'isCompleted' must be a boolean")
                }
                input.isCompleted = isCompleted
                hasUpdate = true
            }
            guard hasUpdate else {
                return .failure("Provide at least one field to update")
            }

            guard let updated = await store.applyActionItemUpdate(
                recordingID: id,
                actionItemID: itemID,
                input: input
            ) else {
                return .failure("Action item not found or update could not be saved: \(itemIDString)")
            }
            Self.log.notice("mcp write update_action_item recording=\(id.uuidString, privacy: .public) item=\(itemIDString, privacy: .public)")
            return .ok(encodeJSON(Self.actionItemJSON(updated)))

        case "set_speaker_name":
            guard let rawLabel = args?["speakerLabel"]?.asString, !rawLabel.isEmpty else {
                return .failure("'speakerLabel' (e.g. \"Speaker 1\") is required")
            }
            guard let name = args?["name"]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else {
                return .failure("'name' (non-empty string) is required")
            }
            // The label must actually occur in this transcript — keeps a
            // hallucinated label from minting junk mappings.
            let presentLabels = Set(detail.transcript?.segments.compactMap(\.speaker) ?? [])
            guard presentLabels.contains(rawLabel) else {
                let listing = presentLabels.isEmpty ? "(none)" : presentLabels.sorted().joined(separator: ", ")
                return .failure("Speaker label '\(rawLabel)' does not appear in this transcript. Labels present: \(listing)")
            }
            // Find-or-create + mapping happen atomically inside the store
            // actor — concurrent calls can't mint duplicate profiles, and a
            // failed save surfaces as nil instead of a fake success.
            guard let outcome = await store.setSpeakerName(recordingID: id, rawLabel: rawLabel, profileNamed: name) else {
                return .failure("Could not persist the speaker mapping for '\(name)'")
            }
            // Participant names are sensitive — keep them out of the unified log.
            Self.log.notice("mcp write set_speaker_name recording=\(id.uuidString, privacy: .public) label=\(rawLabel, privacy: .public) -> \(outcome.profileName, privacy: .private)")
            return .ok("Mapped '\(rawLabel)' to '\(outcome.profileName)' (\(outcome.reusedExisting ? "existing" : "new") speaker profile). Transcript fetches now show this name.")

        default:
            return .failure("Unknown tool: \(name)")
        }
    }

    // MARK: - External import tools

    private enum ExternalToolError: Error, LocalizedError {
        case invalid(String)

        var errorDescription: String? {
            switch self {
            case .invalid(let message): message
            }
        }
    }

    private func callExternalImportTool(name: String, arguments args: JSONValue?) async -> MCPToolResult {
        do {
            switch name {
            case "preview_external_recordings":
                guard let values = args?["recordings"]?.asArray else {
                    throw ExternalToolError.invalid("'recordings' (array) is required")
                }
                guard values.count <= ExternalRecordingImportService.maxPreviewBatch else {
                    throw ExternalToolError.invalid("At most \(ExternalRecordingImportService.maxPreviewBatch) recordings can be previewed at once.")
                }
                let inputs = try values.enumerated().map { index, value in
                    try parseExternalPreviewInput(value, context: "recordings[\(index)]")
                }
                let results = await externalImportService.preview(inputs)
                return .ok(encodeJSON(.object([
                    "results": .array(results.map(externalPreviewJSON)),
                ])))

            case "upload_external_transcript_chunk":
                let input = try parseTranscriptChunk(args)
                let result = await externalImportService.stageTranscriptChunk(input)
                return .ok(encodeJSON(externalChunkJSON(result)))

            case "upsert_external_recording":
                let (input, uploadID) = try parseExternalUpsertInput(args)
                let result = await externalImportService.upsert(input, transcriptUploadID: uploadID)
                let json = externalUpsertJSON(result)
                return result.status == .failed || result.status == .incompleteUpload
                    ? .failure(result.reason ?? "External recording upsert failed.")
                    : .ok(encodeJSON(json))

            case "set_external_import_disposition":
                guard let rawDisposition = args?["disposition"]?.asString else {
                    throw ExternalToolError.invalid("'disposition' must be ignore or reconsider")
                }
                let disposition: ExternalImportDisposition
                switch rawDisposition {
                case "ignore": disposition = .ignored
                case "reconsider": disposition = .pending
                default: throw ExternalToolError.invalid("'disposition' must be ignore or reconsider")
                }
                let previewInput = try parseExternalPreviewInput(args ?? .object([:]), context: "arguments")
                let result = await externalImportService.setDisposition(
                    previewInput: previewInput,
                    disposition: disposition,
                    reason: args?["reason"]?.asString
                )
                if result.status == .conflict {
                    return .failure(result.reason ?? "Could not set external import disposition.")
                }
                return .ok(encodeJSON(.object([
                    "status": .string(result.status.rawValue),
                    "externalKey": result.externalKey.map(JSONValue.string) ?? .null,
                    "recordingId": result.recordingID.map { .string($0.uuidString) } ?? .null,
                    "reason": result.reason.map(JSONValue.string) ?? .null,
                ])))

            default:
                return .failure("Unknown tool: \(name)")
            }
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private func parseExternalPreviewInput(
        _ value: JSONValue,
        context: String
    ) throws -> ExternalRecordingPreviewInput {
        let provider = try requiredString("provider", from: value, context: context)
        let externalID = try requiredString("externalId", from: value, context: context)
        let title = try requiredString("title", from: value, context: context)
        let startDate = try requiredDate("startDate", from: value, context: context)
        let sourceUpdatedAt = try requiredDate("sourceUpdatedAt", from: value, context: context)
        let sourceCreatedAt = try optionalDate("sourceCreatedAt", from: value, context: context)
        let duration = value["durationSeconds"]?.asDouble ?? 0
        guard duration >= 0 else {
            throw ExternalToolError.invalid("\(context).durationSeconds must be non-negative")
        }
        let transcriptCharacterCount = value["transcriptCharacterCount"]?.asInt ?? 0
        let transcriptSegmentCount = value["transcriptSegmentCount"]?.asInt ?? 0
        let actionItemCount = value["actionItemCount"]?.asInt ?? 0
        guard transcriptCharacterCount >= 0, transcriptSegmentCount >= 0, actionItemCount >= 0 else {
            throw ExternalToolError.invalid("\(context) content counts must be non-negative")
        }
        let transcriptFingerprint: String?
        if let rawFingerprint = value["transcriptFingerprint"]?.asString {
            guard let normalized = ExternalRecordingFingerprint.normalizedSHA256(rawFingerprint) else {
                throw ExternalToolError.invalid("\(context).transcriptFingerprint must contain 64 hexadecimal characters")
            }
            transcriptFingerprint = normalized
        } else {
            transcriptFingerprint = nil
        }
        return ExternalRecordingPreviewInput(
            provider: provider,
            externalID: externalID,
            title: title,
            startDate: startDate,
            duration: duration,
            calendarEventID: value["calendarEventId"]?.asString,
            sourceCreatedAt: sourceCreatedAt,
            sourceUpdatedAt: sourceUpdatedAt,
            transcriptCharacterCount: transcriptCharacterCount,
            transcriptSegmentCount: transcriptSegmentCount,
            hasSummary: value["hasSummary"]?.asBool ?? false,
            actionItemCount: actionItemCount,
            transcriptFingerprint: transcriptFingerprint
        )
    }

    private func parseTranscriptChunk(_ args: JSONValue?) throws -> ExternalTranscriptChunkInput {
        guard let args else { throw ExternalToolError.invalid("Arguments are required") }
        guard let uploadIDString = args["uploadId"]?.asString,
              let uploadID = UUID(uuidString: uploadIDString) else {
            throw ExternalToolError.invalid("'uploadId' must be a UUID string")
        }
        guard let index = args["index"]?.asInt,
              let totalChunks = args["totalChunks"]?.asInt,
              let text = args["text"]?.asString else {
            throw ExternalToolError.invalid("'index', 'totalChunks' and 'text' are required")
        }
        return ExternalTranscriptChunkInput(
            uploadID: uploadID,
            index: index,
            totalChunks: totalChunks,
            text: text,
            chunkSHA256: args["chunkSHA256"]?.asString,
            transcriptSHA256: args["transcriptSHA256"]?.asString
        )
    }

    private func parseExternalUpsertInput(
        _ args: JSONValue?
    ) throws -> (ExternalRecordingUpsertInput, UUID?) {
        guard let args else { throw ExternalToolError.invalid("Arguments are required") }
        let provider = try requiredString("provider", from: args, context: "arguments")
        let externalID = try requiredString("externalId", from: args, context: "arguments")
        let title = try requiredString("title", from: args, context: "arguments")
        let startDate = try requiredDate("startDate", from: args, context: "arguments")
        let sourceUpdatedAt = try requiredDate("sourceUpdatedAt", from: args, context: "arguments")
        let sourceCreatedAt = try optionalDate("sourceCreatedAt", from: args, context: "arguments")
        let endDate = try optionalDate("endDate", from: args, context: "arguments")
        let duration = args["durationSeconds"]?.asDouble ?? 0
        guard duration >= 0 else {
            throw ExternalToolError.invalid("durationSeconds must be non-negative")
        }
        let language = args["language"]?.asString ?? "auto"
        let tags = try stringArray(args["tags"], field: "tags")
        let transcript = try parseExternalTranscript(args["transcript"])
        let summary = try parseExternalSummary(args["summary"], defaultLanguage: language)
        let uploadID: UUID?
        if let rawUploadID = args["transcriptUploadId"]?.asString {
            guard let parsed = UUID(uuidString: rawUploadID) else {
                throw ExternalToolError.invalid("transcriptUploadId must be a UUID string")
            }
            uploadID = parsed
        } else {
            uploadID = nil
        }
        return (
            ExternalRecordingUpsertInput(
                provider: provider,
                externalID: externalID,
                title: title,
                startDate: startDate,
                endDate: endDate,
                duration: duration,
                language: language,
                meetingApp: args["meetingApp"]?.asString,
                meetingURL: args["meetingURL"]?.asString,
                calendarEventID: args["calendarEventId"]?.asString,
                sourceCreatedAt: sourceCreatedAt,
                sourceUpdatedAt: sourceUpdatedAt,
                tags: tags,
                transcript: transcript,
                summary: summary
            ),
            uploadID
        )
    }

    private func parseExternalTranscript(_ value: JSONValue?) throws -> ExternalTranscriptInput? {
        guard let value, value != .null else { return nil }
        guard let fullText = value["fullText"]?.asString else {
            throw ExternalToolError.invalid("transcript.fullText must be a string")
        }
        var segments: [ExternalTranscriptSegmentInput] = []
        if let values = value["segments"]?.asArray {
            segments.reserveCapacity(values.count)
            for (index, segment) in values.enumerated() {
                guard let startTime = segment["startTime"]?.asDouble,
                      let endTime = segment["endTime"]?.asDouble,
                      let text = segment["text"]?.asString,
                      startTime >= 0,
                      endTime >= startTime else {
                    throw ExternalToolError.invalid("transcript.segments[\(index)] has invalid times or text")
                }
                segments.append(ExternalTranscriptSegmentInput(
                    startTime: startTime,
                    endTime: endTime,
                    text: text,
                    speaker: segment["speaker"]?.asString
                ))
            }
        }
        return ExternalTranscriptInput(
            fullText: fullText,
            segments: segments,
            detectedLanguage: value["detectedLanguage"]?.asString
        )
    }

    private func parseExternalSummary(
        _ value: JSONValue?,
        defaultLanguage: String
    ) throws -> ExternalSummaryInput? {
        guard let value, value != .null else { return nil }
        let actionValues = value["actionItems"]?.asArray ?? []
        var actionItems: [ExternalActionItemInput] = []
        actionItems.reserveCapacity(actionValues.count)
        for (index, item) in actionValues.enumerated() {
            guard let task = item["task"]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !task.isEmpty else {
                throw ExternalToolError.invalid("summary.actionItems[\(index)].task is required")
            }
            let priority: ActionPriority
            if let rawPriority = item["priority"]?.asString {
                guard let parsed = ActionPriority(rawValue: rawPriority) else {
                    throw ExternalToolError.invalid("summary.actionItems[\(index)].priority must be high, medium or low")
                }
                priority = parsed
            } else {
                priority = .medium
            }
            actionItems.append(ExternalActionItemInput(
                assignee: item["assignee"]?.asString,
                task: task,
                deadline: item["deadline"]?.asString,
                isCompleted: item["isCompleted"]?.asBool ?? false,
                priority: priority
            ))
        }
        return ExternalSummaryInput(
            overview: value["overview"]?.asString ?? "",
            keyPoints: try stringArray(value["keyPoints"], field: "summary.keyPoints"),
            actionItems: actionItems,
            decisions: try stringArray(value["decisions"], field: "summary.decisions"),
            followUps: try stringArray(value["followUps"], field: "summary.followUps"),
            yourTasks: try stringArray(value["yourTasks"], field: "summary.yourTasks"),
            language: value["language"]?.asString ?? defaultLanguage
        )
    }

    private func requiredString(
        _ field: String,
        from value: JSONValue,
        context: String
    ) throws -> String {
        guard let string = value[field]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !string.isEmpty else {
            throw ExternalToolError.invalid("\(context).\(field) (non-empty string) is required")
        }
        return string
    }

    private func requiredDate(
        _ field: String,
        from value: JSONValue,
        context: String
    ) throws -> Date {
        guard let raw = value[field]?.asString,
              let date = Self.parseDate(raw, endOfDay: false) else {
            throw ExternalToolError.invalid("\(context).\(field) must be ISO 8601")
        }
        return date
    }

    private func optionalDate(
        _ field: String,
        from value: JSONValue,
        context: String
    ) throws -> Date? {
        guard let raw = value[field] else { return nil }
        if raw == .null { return nil }
        guard let string = raw.asString,
              let date = Self.parseDate(string, endOfDay: false) else {
            throw ExternalToolError.invalid("\(context).\(field) must be ISO 8601")
        }
        return date
    }

    private func stringArray(_ value: JSONValue?, field: String) throws -> [String] {
        guard let value, value != .null else { return [] }
        guard let array = value.asArray else {
            throw ExternalToolError.invalid("\(field) must be an array of strings")
        }
        var strings: [String] = []
        strings.reserveCapacity(array.count)
        for item in array {
            guard let string = item.asString else {
                throw ExternalToolError.invalid("\(field) must contain only strings")
            }
            strings.append(string)
        }
        return strings
    }

    private func externalPreviewJSON(_ result: ExternalRecordingPreviewResult) -> JSONValue {
        .object([
            "provider": .string(result.provider),
            "externalId": .string(result.externalID),
            "externalKey": .string(result.externalKey),
            "status": .string(result.status.rawValue),
            "recordingId": result.recordingID.map { .string($0.uuidString) } ?? .null,
            "matchedRecordingId": result.matchedRecordingID.map { .string($0.uuidString) } ?? .null,
            "reason": result.reason.map(JSONValue.string) ?? .null,
            "qualitySignals": .array(result.qualitySignals.map { .string($0.rawValue) }),
        ])
    }

    private func externalChunkJSON(_ result: ExternalTranscriptChunkResult) -> JSONValue {
        .object([
            "status": .string(result.status.rawValue),
            "uploadId": .string(result.uploadID.uuidString),
            "receivedChunks": .number(Double(result.receivedChunks)),
            "totalChunks": .number(Double(result.totalChunks)),
            "receivedBytes": .number(Double(result.receivedBytes)),
            "reason": result.reason.map(JSONValue.string) ?? .null,
        ])
    }

    private func externalUpsertJSON(_ result: ExternalRecordingUpsertResult) -> JSONValue {
        .object([
            "status": .string(result.status.rawValue),
            "externalKey": result.externalKey.map(JSONValue.string) ?? .null,
            "recordingId": result.recordingID.map { .string($0.uuidString) } ?? .null,
            "matchedRecordingId": result.matchedRecordingID.map { .string($0.uuidString) } ?? .null,
            "reason": result.reason.map(JSONValue.string) ?? .null,
            "qualitySignals": .array(result.qualitySignals.map { .string($0.rawValue) }),
        ])
    }

    // MARK: - Helpers

    private func recordingID(from args: JSONValue?) -> UUID? {
        args?["recordingId"]?.asString.flatMap(UUID.init(uuidString:))
    }

    /// Detail fetch that refuses trashed recordings (fetchRecordingDetail
    /// itself resolves by id regardless of trash status).
    private func fetchActiveDetail(_ id: UUID) async -> RecordingDetailDTO? {
        guard let trashed = await store.isRecordingTrashed(recordingID: id), !trashed else { return nil }
        return await store.fetchRecordingDetail(recordingID: id)
    }

    /// Search-hit excerpt: ±80 chars around the first transcript match,
    /// else summary overview prefix, else stored previews.
    private func snippet(for query: String, hit: RecordingDTO) async -> String {
        if let detail = await store.fetchRecordingDetail(recordingID: hit.id) {
            if let full = detail.transcript?.fullText,
               let range = full.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) {
                let lower = full.index(range.lowerBound, offsetBy: -80, limitedBy: full.startIndex) ?? full.startIndex
                let upper = full.index(range.upperBound, offsetBy: 80, limitedBy: full.endIndex) ?? full.endIndex
                let prefix = lower > full.startIndex ? "…" : ""
                let suffix = upper < full.endIndex ? "…" : ""
                return prefix + full[lower..<upper].replacingOccurrences(of: "\n", with: " ") + suffix
            }
            if let overview = detail.summary?.overview, !overview.isEmpty {
                return String(overview.prefix(160))
            }
        }
        return hit.transcriptPreview ?? hit.summaryPreview ?? ""
    }

    private func iso(_ date: Date) -> String {
        date.formatted(.iso8601)
    }

    private func encodeJSON(_ value: JSONValue) -> String {
        String(data: JSONRPC.encode(value), encoding: .utf8) ?? "{}"
    }

    /// ISO 8601 datetime, or date-only `YYYY-MM-DD` interpreted in the local
    /// timezone. `endOfDay` advances a date-only value to the NEXT midnight so
    /// callers can use it as an exclusive upper bound (inclusive whole day).
    static func parseDate(_ string: String, endOfDay: Bool) -> Date? {
        if let date = try? Date(string, strategy: .iso8601) {
            return date
        }
        let parts = string.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              let start = Calendar.current.date(from: DateComponents(year: year, month: month, day: day)) else {
            return nil
        }
        return endOfDay ? Calendar.current.date(byAdding: .day, value: 1, to: start) : start
    }

    // MARK: - Tool definitions

    private struct ToolMetadata: Sendable {
        let title: String
        let annotations: MCPToolAnnotations
    }

    private static func typedDefinitions(
        _ rawDefinitions: [JSONValue],
        metadata: [String: ToolMetadata]
    ) -> [MCPToolDefinition] {
        rawDefinitions.map { raw in
            guard let name = raw["name"]?.asString,
                  let description = raw["description"]?.asString,
                  let inputSchema = raw["inputSchema"],
                  let toolMetadata = metadata[name] else {
                preconditionFailure("Invalid MCP tool definition metadata")
            }
            return MCPToolDefinition(
                name: name,
                title: toolMetadata.title,
                description: description,
                inputSchema: inputSchema,
                annotations: toolMetadata.annotations
            )
        }
    }

    static let readDefinitions = typedDefinitions(rawReadDefinitions, metadata: [
        "search_transcripts": ToolMetadata(title: "Search Transcripts", annotations: .readOnly),
        "list_recordings": ToolMetadata(title: "List Recordings", annotations: .readOnly),
        "list_tags": ToolMetadata(title: "List Tags", annotations: .readOnly),
        "list_action_items": ToolMetadata(title: "List Action Items", annotations: .readOnly),
        "get_transcript": ToolMetadata(title: "Get Transcript", annotations: .readOnly),
        "get_summary": ToolMetadata(title: "Get Summary", annotations: .readOnly),
        "get_person_meeting_context": ToolMetadata(title: "Get Person Meeting Context", annotations: .readOnly),
    ])

    static let meetingContextDefinitions = typedDefinitions(rawMeetingContextDefinitions, metadata: [
        "list_upcoming_meetings": ToolMetadata(title: "List Upcoming Meetings", annotations: .readOnly),
        "get_meeting_context": ToolMetadata(title: "Get Meeting Context", annotations: .readOnly),
        "find_people": ToolMetadata(title: "Find People", annotations: .readOnly),
    ])

    static let writeDefinitions = typedDefinitions(rawWriteDefinitions, metadata: [
        "rename_recording": ToolMetadata(
            title: "Rename Recording",
            annotations: .write(idempotent: true)
        ),
        "add_tag": ToolMetadata(title: "Add Tag", annotations: .write(idempotent: true)),
        "remove_tag": ToolMetadata(
            title: "Remove Tag",
            annotations: .write(destructive: true, idempotent: true)
        ),
        "add_action_item": ToolMetadata(title: "Add Action Item", annotations: .write(idempotent: false)),
        "toggle_action_item": ToolMetadata(
            title: "Toggle Action Item",
            annotations: .write(idempotent: false)
        ),
        "update_action_item": ToolMetadata(
            title: "Update Action Item",
            annotations: .write(idempotent: true)
        ),
        "set_speaker_name": ToolMetadata(title: "Set Speaker Name", annotations: .write(idempotent: true)),
    ])

    static let meetingPrepWriteDefinitions = typedDefinitions(rawMeetingPrepWriteDefinitions, metadata: [
        "write_artifact": ToolMetadata(
            title: "Write Meeting Artifact",
            annotations: .write(destructive: true, idempotent: true)
        ),
    ])

    static let externalImportDefinitions = typedDefinitions(rawExternalImportDefinitions, metadata: [
        "preview_external_recordings": ToolMetadata(
            title: "Preview External Recordings",
            annotations: .readOnly
        ),
        "upload_external_transcript_chunk": ToolMetadata(
            title: "Upload External Transcript Chunk",
            annotations: .write(idempotent: true)
        ),
        "upsert_external_recording": ToolMetadata(
            title: "Upsert External Recording",
            annotations: .write(idempotent: true)
        ),
        "set_external_import_disposition": ToolMetadata(
            title: "Set External Import Disposition",
            annotations: .write(idempotent: true)
        ),
    ])

    private static let recordingIDProperty: JSONValue = [
        "type": "string",
        "description": "Recording id (UUID) from search_transcripts or list_recordings",
    ]

    private static let rawReadDefinitions: [JSONValue] = [
        [
            "name": "search_transcripts",
            "description": "Full-text search across meeting transcripts, summaries, titles and tags. Returns matching recordings with a snippet around the first match. Use this first to find the relevant recording id.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "Search text (case-insensitive)"],
                    "limit": ["type": "integer", "description": "Max results, 1-25 (default 10)"],
                ],
                "required": ["query"],
            ],
        ],
        [
            "name": "list_recordings",
            "description": "List recordings with stable cursor pagination. Filter by meeting date, update time, folder, tag, source, or content status. A cursor expires explicitly if matching recordings change between pages.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "startDate": ["type": "string", "description": "ISO 8601; date-only (2026-06-01) starts at local midnight"],
                    "endDate": ["type": "string", "description": "ISO 8601; date-only means through the end of that day"],
                    "updatedAfter": ["type": "string", "description": "Only recordings updated strictly after this ISO 8601 timestamp"],
                    "folderName": ["type": "string", "description": "Filter by folder name (case-insensitive)"],
                    "tag": ["type": "string", "description": "Filter by exact tag"],
                    "source": [
                        "type": "string",
                        "enum": ["captured", "imported_audio", "external", "unknown"],
                        "description": "Recording origin. Legacy rows created before source tracking are unknown.",
                    ],
                    "status": [
                        "type": "string",
                        "enum": ["active", "empty", "transcribed", "ready", "trashed", "all"],
                        "description": "Content availability or trash state. active (default) includes all non-trashed recordings.",
                    ],
                    "sort": [
                        "type": "string",
                        "enum": ["date_desc", "date_asc", "updated_desc", "updated_asc"],
                        "description": "Stable ordering (default date_desc).",
                    ],
                    "limit": ["type": "integer", "description": "Max results, 1-50 (default 20)"],
                    "cursor": ["type": "string", "description": "Opaque cursor from the previous page; reuse the same filters and sort"],
                ],
            ],
        ],
        [
            "name": "list_tags",
            "description": "The controlled tag vocabulary with per-tag usage counts (most-used first). These are the existing categories — prefer them when tagging, and use them as the `tag` filter for list_recordings. add_tag only accepts tags from this list unless you pass allowNew.",
            "inputSchema": ["type": "object", "properties": [:]],
        ],
        [
            "name": "list_action_items",
            "description": "List action items across recording summaries with stable cursor pagination. Returns raw and normalized deadlines plus source recording context.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "recordingId": recordingIDProperty,
                    "folderName": ["type": "string"],
                    "tag": ["type": "string"],
                    "assignee": ["type": "string", "description": "Exact assignee name, case-insensitive"],
                    "completion": ["type": "string", "enum": ["open", "completed", "all"], "description": "Default open"],
                    "deadlineFrom": ["type": "string", "description": "ISO 8601 lower deadline bound"],
                    "deadlineTo": ["type": "string", "description": "ISO 8601 inclusive date upper bound"],
                    "updatedAfter": ["type": "string", "description": "Only items updated strictly after this ISO 8601 timestamp"],
                    "priority": ["type": "string", "enum": ["high", "medium", "low"]],
                    "limit": ["type": "integer", "description": "Max results, 1-50 (default 20)"],
                    "cursor": ["type": "string", "description": "Opaque cursor from the previous page"],
                ],
            ],
        ],
        [
            "name": "get_transcript",
            "description": "Get a recording's transcript. Long transcripts are paginated: pass the returned nextCursor to continue. Optional startTime/endTime (seconds) restrict to a time window. The response includes a 'speakers' roster; entries with resolvedName null are unidentified placeholders (e.g. \"Speaker 1\") — if the conversation reveals who they are, you can persist the mapping with set_speaker_name.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "recordingId": recordingIDProperty,
                    "format": ["type": "string", "enum": ["text", "segments"], "description": "text (default) or segments with timestamps"],
                    "maxChars": ["type": "integer", "description": "Page size in characters (default 40000)"],
                    "cursor": ["type": "string", "description": "Opaque cursor from a previous call's nextCursor"],
                    "startTime": ["type": "number", "description": "Window start in seconds from recording start"],
                    "endTime": ["type": "number", "description": "Window end in seconds"],
                ],
                "required": ["recordingId"],
            ],
        ],
        [
            "name": "get_summary",
            "description": "Get a recording's AI summary: overview, key points, decisions, follow-ups and action items (with ids for toggle_action_item).",
            "inputSchema": [
                "type": "object",
                "properties": ["recordingId": recordingIDProperty],
                "required": ["recordingId"],
            ],
        ],
        [
            "name": "get_person_meeting_context",
            "description": "Read prior Cadenza recording context for one explicit speaker-profile candidate returned by find_people. Calendar attendee identities are never auto-linked.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "personId": ["type": "string", "description": "Candidate personId from find_people"],
                    "limit": ["type": "integer", "description": "Max historical meetings, 1-50 (default 10)"],
                ],
                "required": ["personId"],
            ],
        ],
    ]

    private static let rawMeetingContextDefinitions: [JSONValue] = [
        [
            "name": "list_upcoming_meetings",
            "description": "List upcoming calendar meetings (within a time window) with their prep-brief status. Each meeting has an occurrenceKey — use it with get_meeting_context to fetch preparation context and write_artifact to save a prep brief. hasPrep/prepSource/prepStatus tell you whether a prep already exists and who authored it (skip regenerating when prepSource is external and prepStatus is ready, unless stale is true).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "withinHours": ["type": "integer", "description": "Look-ahead window in hours, 1-168 (default 24; calendar cache typically covers ~24h)"],
                ],
            ],
        ],
        [
            "name": "get_meeting_context",
            "description": "Fetch preparation context for one upcoming meeting (event details, attendees, related meeting history, open action items — already privacy-scoped to relevant recordings). Use the returned context plus your own knowledge/tools to write a pre-meeting prep brief in Markdown, then save it with write_artifact. suggestedStructure lists the section headings the built-in generator uses.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "occurrenceKey": ["type": "string", "description": "From list_upcoming_meetings"],
                    "maxChars": ["type": "integer", "description": "Truncate context to this many characters, 1000-200000 (default 40000)"],
                ],
                "required": ["occurrenceKey"],
            ],
        ],
        [
            "name": "find_people",
            "description": "Find possible people using upcoming calendar attendees, speaker profiles, and historical meeting evidence. Ambiguous matches stay separate and are never auto-mapped.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "Name, alias, or email"],
                    "limit": ["type": "integer", "description": "Max candidates, 1-25 (default 10)"],
                ],
                "required": ["query"],
            ],
        ],
    ]

    private static let rawWriteDefinitions: [JSONValue] = [
        [
            "name": "rename_recording",
            "description": "Rename a recording.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "recordingId": recordingIDProperty,
                    "title": ["type": "string", "description": "New title"],
                ],
                "required": ["recordingId", "title"],
            ],
        ],
        [
            "name": "add_tag",
            "description": "Tag a recording. By default only existing tags (see list_tags) are accepted — this keeps tags a stable classification rather than free-form. The tag is normalized (case/spacing/synonyms) to match the vocabulary. To deliberately create a genuinely new category, pass allowNew:true. No-op if already present.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "recordingId": recordingIDProperty,
                    "tag": ["type": "string", "description": "A tag from list_tags (preferred), or a new one with allowNew:true"],
                    "allowNew": ["type": "boolean", "description": "Allow creating a tag not yet in the vocabulary (default false)"],
                ],
                "required": ["recordingId", "tag"],
            ],
        ],
        [
            "name": "remove_tag",
            "description": "Remove a tag from a recording.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "recordingId": recordingIDProperty,
                    "tag": ["type": "string"],
                ],
                "required": ["recordingId", "tag"],
            ],
        ],
        [
            "name": "add_action_item",
            "description": "Add an action item to a recording's summary.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "recordingId": recordingIDProperty,
                    "task": ["type": "string", "description": "Action item text"],
                ],
                "required": ["recordingId", "task"],
            ],
        ],
        [
            "name": "toggle_action_item",
            "description": "Toggle an action item between open and completed. Get action item ids from get_summary.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "recordingId": recordingIDProperty,
                    "actionItemId": ["type": "string", "description": "Action item id (UUID) from get_summary"],
                ],
                "required": ["recordingId", "actionItemId"],
            ],
        ],
        [
            "name": "update_action_item",
            "description": "Update an action item's task, assignee, raw deadline, priority, or completion state. Pass null to clear assignee or deadline.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "recordingId": recordingIDProperty,
                    "actionItemId": ["type": "string", "description": "Action item id (UUID) from list_action_items or get_summary"],
                    "task": ["type": "string"],
                    "assignee": ["type": ["string", "null"]],
                    "deadline": ["type": ["string", "null"], "description": "Raw deadline text; normalized date is returned when parseable"],
                    "priority": ["type": "string", "enum": ["high", "medium", "low"]],
                    "isCompleted": ["type": "boolean"],
                ],
                "required": ["recordingId", "actionItemId"],
            ],
        ],
        [
            "name": "set_speaker_name",
            "description": "Permanently map an unidentified speaker label (e.g. \"Speaker 1\") to a real person's name, for this recording. Use when the transcript reveals who a speaker is (self-introduction, being addressed by name). Reuses an existing speaker profile with the same name, otherwise creates one.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "recordingId": recordingIDProperty,
                    "speakerLabel": ["type": "string", "description": "Raw label as it appears in the transcript, e.g. \"Speaker 1\""],
                    "name": ["type": "string", "description": "The person's real name, e.g. \"Dinesh\""],
                ],
                "required": ["recordingId", "speakerLabel", "name"],
            ],
        ],
    ]

    /// `write_artifact` — gated by BOTH `writesEnabled` AND `meetingContextEnabled`
    /// (see `toolDefinitions()`), so it's listed only when both switches are on.
    private static let rawMeetingPrepWriteDefinitions: [JSONValue] = [
        [
            "name": "write_artifact",
            "description": "Save a pre-meeting prep brief (Markdown) for an upcoming meeting. External briefs take priority: this overwrites any built-in generated prep, and Cadenza's automatic generator will not overwrite yours. Check list_upcoming_meetings first — if prepSource is already 'external' and not stale, prefer updating only when you have newer information.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "occurrenceKey": ["type": "string", "description": "From list_upcoming_meetings"],
                    "bodyMarkdown": ["type": "string", "description": "The prep brief in Markdown (see get_meeting_context's suggestedStructure)"],
                    "kind": ["type": "string", "description": "Artifact kind; only 'meetingPrep' (default) is supported"],
                    "targetType": ["type": "string", "description": "Only 'calendarEvent' (default) is supported"],
                ],
                "required": ["occurrenceKey", "bodyMarkdown"],
            ],
        ],
    ]

    private static let externalPreviewProperties: JSONValue = [
        "provider": ["type": "string", "description": "Stable lowercase identifier for the source provider"],
        "externalId": ["type": "string", "description": "Stable provider-scoped note id"],
        "title": ["type": "string"],
        "startDate": ["type": "string", "description": "ISO 8601 meeting start"],
        "durationSeconds": ["type": "number", "minimum": 0],
        "calendarEventId": ["type": "string"],
        "sourceCreatedAt": ["type": "string", "description": "ISO 8601 source creation time"],
        "sourceUpdatedAt": ["type": "string", "description": "ISO 8601 source update version"],
        "transcriptCharacterCount": ["type": "integer", "minimum": 0],
        "transcriptSegmentCount": ["type": "integer", "minimum": 0],
        "hasSummary": ["type": "boolean"],
        "actionItemCount": ["type": "integer", "minimum": 0],
        "transcriptFingerprint": ["type": "string", "description": "Optional SHA-256 from previously fetched content"],
    ]

    private static let externalDispositionProperties: JSONValue = {
        var properties = externalPreviewProperties.asObject ?? [:]
        properties["disposition"] = ["type": "string", "enum": ["ignore", "reconsider"]]
        properties["reason"] = ["type": "string"]
        return .object(properties)
    }()

    private static let rawExternalImportDefinitions: [JSONValue] = [
        [
            "name": "preview_external_recordings",
            "description": "Dry-run up to 100 external meeting notes using lightweight metadata. Returns new, unchanged, updated, ignored, possible_duplicate or conflict plus explainable empty/test signals. Never writes or silently merges fuzzy matches.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "recordings": [
                        "type": "array",
                        "maxItems": 100,
                        "items": [
                            "type": "object",
                            "properties": externalPreviewProperties,
                            "required": ["provider", "externalId", "title", "startDate", "sourceUpdatedAt"],
                        ],
                    ],
                ],
                "required": ["recordings"],
            ],
        ],
        [
            "name": "upload_external_transcript_chunk",
            "description": "Stage one ordered transcript text chunk below the 1 MiB HTTP limit. Replaying identical chunks is safe; changing an existing index is rejected. upsert_external_recording commits only after every chunk is present.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "uploadId": ["type": "string", "description": "Caller-generated UUID reused for all chunks"],
                    "index": ["type": "integer", "minimum": 0],
                    "totalChunks": ["type": "integer", "minimum": 1, "maximum": 256],
                    "text": ["type": "string", "description": "At most 196608 UTF-8 bytes"],
                    "chunkSHA256": ["type": "string"],
                    "transcriptSHA256": ["type": "string"],
                ],
                "required": ["uploadId", "index", "totalChunks", "text"],
            ],
        ],
        [
            "name": "upsert_external_recording",
            "description": "Idempotently create or update one provider-neutral external meeting note. Allows transcript/summary without audio. Source updates fail closed if the local Cadenza content changed; possible duplicates are reported without merging.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "provider": ["type": "string"],
                    "externalId": ["type": "string"],
                    "title": ["type": "string"],
                    "startDate": ["type": "string"],
                    "endDate": ["type": "string"],
                    "durationSeconds": ["type": "number", "minimum": 0],
                    "language": ["type": "string"],
                    "meetingApp": ["type": "string"],
                    "meetingURL": ["type": "string"],
                    "calendarEventId": ["type": "string"],
                    "sourceCreatedAt": ["type": "string"],
                    "sourceUpdatedAt": ["type": "string"],
                    "tags": ["type": "array", "items": ["type": "string"]],
                    "transcriptUploadId": ["type": "string", "description": "Completed upload UUID for a large transcript"],
                    "transcript": [
                        "type": "object",
                        "properties": [
                            "fullText": ["type": "string"],
                            "detectedLanguage": ["type": "string"],
                            "segments": [
                                "type": "array",
                                "items": [
                                    "type": "object",
                                    "properties": [
                                        "startTime": ["type": "number"],
                                        "endTime": ["type": "number"],
                                        "text": ["type": "string"],
                                        "speaker": ["type": "string"],
                                    ],
                                    "required": ["startTime", "endTime", "text"],
                                ],
                            ],
                        ],
                        "required": ["fullText"],
                    ],
                    "summary": [
                        "type": "object",
                        "properties": [
                            "overview": ["type": "string"],
                            "keyPoints": ["type": "array", "items": ["type": "string"]],
                            "decisions": ["type": "array", "items": ["type": "string"]],
                            "followUps": ["type": "array", "items": ["type": "string"]],
                            "yourTasks": ["type": "array", "items": ["type": "string"]],
                            "language": ["type": "string"],
                            "actionItems": [
                                "type": "array",
                                "items": [
                                    "type": "object",
                                    "properties": [
                                        "task": ["type": "string"],
                                        "assignee": ["type": "string"],
                                        "deadline": ["type": "string"],
                                        "isCompleted": ["type": "boolean"],
                                        "priority": ["type": "string", "enum": ["high", "medium", "low"]],
                                    ],
                                    "required": ["task"],
                                ],
                            ],
                        ],
                    ],
                ],
                "required": ["provider", "externalId", "title", "startDate", "sourceUpdatedAt"],
            ],
        ],
        [
            "name": "set_external_import_disposition",
            "description": "Audit an explicit ignore or reconsider decision for an external note. Ignore does not delete a Recording; reconsider preserves the ledger and returns the note to preview/upsert consideration.",
            "inputSchema": [
                "type": "object",
                "properties": externalDispositionProperties,
                "required": ["provider", "externalId", "title", "startDate", "sourceUpdatedAt", "disposition"],
            ],
        ],
    ]
}

// MARK: - Int clamping

private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
