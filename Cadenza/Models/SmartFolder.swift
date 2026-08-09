import Foundation

enum SmartFolderID: String, CaseIterable, Sendable {
    case oneOnOnes
    case teamMeetings
    case clientMeetings
    case interviews
}

struct SmartFolderDTO: Codable, Hashable, Identifiable, Sendable {
    let id: String
    var title: String
    var subtitle: String?
    var icon: String
    var iconColor: String
    var recordingIDs: [UUID]

    var recordingCount: Int { recordingIDs.count }
}

struct SmartFolderOverrides: Codable, Equatable, Sendable {
    var pinned: [String: [UUID]]
    var excluded: [String: [UUID]]

    static let empty = SmartFolderOverrides(pinned: [:], excluded: [:])

    func pinnedIDs(for folderID: String) -> Set<UUID> {
        Set(pinned[folderID] ?? [])
    }

    func excludedIDs(for folderID: String) -> Set<UUID> {
        Set(excluded[folderID] ?? [])
    }
}

/// Deterministic work counters used by the scale regression test. These avoid
/// timing thresholds, which are too dependent on the host running the suite.
struct SmartFolderPersonClassificationMetrics: Equatable, Sendable {
    let inputRecordingCount: Int
    let inputSortComparisonCount: Int
    let groupedRecordingCount: Int
    let overrideIDCount: Int
    let recordingOrderLookupCount: Int
    let recordingOrderComparisonCount: Int
    let folderSortComparisonCount: Int
    let personFolderCount: Int

    var measuredWorkCount: Int {
        inputRecordingCount
            + inputSortComparisonCount
            + groupedRecordingCount
            + overrideIDCount
            + recordingOrderLookupCount
            + recordingOrderComparisonCount
            + folderSortComparisonCount
    }
}

/// Snapshot cache for smart-folder classification. AppState rebuilds this only
/// when the recording list or manual overrides change, avoiding repeated
/// whole-library classification during SwiftUI view evaluation.
struct SmartFolderCache: Sendable {
    private(set) var folders: [SmartFolderDTO] = []
    private(set) var sidebarFolders: [SmartFolderDTO] = []
    private(set) var targets: [SmartFolderDTO] = SmartFolderResolver.builtInTargets
    private var recordingsByID: [UUID: RecordingDTO] = [:]

    mutating func rebuild(
        recordings: [RecordingDTO],
        overrides: SmartFolderOverrides,
        userName: String = ""
    ) {
        let resolvedFolders = SmartFolderResolver.smartFolders(
            for: recordings,
            overrides: overrides,
            userName: userName
        )

        folders = resolvedFolders
        sidebarFolders = SmartFolderResolver.sidebarFolders(from: resolvedFolders)
        targets = SmartFolderResolver.builtInTargets
        recordingsByID = Dictionary(uniqueKeysWithValues: recordings.map { ($0.id, $0) })
    }

    func folder(id: String) -> SmartFolderDTO? {
        folders.first { $0.id == id }
    }

    func recordings(in folderID: String) -> [RecordingDTO] {
        guard let folder = folder(id: folderID) else { return [] }
        return folder.recordingIDs.compactMap { recordingsByID[$0] }
    }
}

enum SmartFolderResolver {
    static var builtInTargets: [SmartFolderDTO] {
        builtInDefinitions.map { definition in
            SmartFolderDTO(
                id: definition.id,
                title: definition.title,
                subtitle: definition.subtitle,
                icon: definition.icon,
                iconColor: definition.iconColor,
                recordingIDs: []
            )
        }
    }

    static func smartFolders(
        for recordings: [RecordingDTO],
        overrides: SmartFolderOverrides,
        userName: String = ""
    ) -> [SmartFolderDTO] {
        resolveSmartFolders(
            for: recordings,
            overrides: overrides,
            userName: userName,
            collectMetrics: false
        ).folders
    }

    static func personClassificationMetrics(
        for recordings: [RecordingDTO],
        overrides: SmartFolderOverrides,
        userName: String = ""
    ) -> SmartFolderPersonClassificationMetrics {
        resolveSmartFolders(
            for: recordings,
            overrides: overrides,
            userName: userName,
            collectMetrics: true
        ).personMetrics
    }

    private struct Resolution {
        let folders: [SmartFolderDTO]
        let personMetrics: SmartFolderPersonClassificationMetrics
    }

    private static func resolveSmartFolders(
        for recordings: [RecordingDTO],
        overrides: SmartFolderOverrides,
        userName: String,
        collectMetrics: Bool
    ) -> Resolution {
        var inputSortComparisonCount = 0
        let sortedRecordings: [RecordingDTO]
        if collectMetrics {
            sortedRecordings = recordings.sorted { lhs, rhs in
                inputSortComparisonCount += 1
                return sortNewestFirst(lhs, rhs)
            }
        } else {
            sortedRecordings = recordings.sorted(by: sortNewestFirst)
        }
        let builtInFolders = builtInDefinitions.compactMap { definition in
            makeFolder(
                id: definition.id,
                title: definition.title,
                subtitle: definition.subtitle,
                icon: definition.icon,
                iconColor: definition.iconColor,
                recordings: sortedRecordings,
                overrides: overrides,
                matches: definition.matches
            )
        }

        let personResolution = oneOnOnePersonFolders(
            for: sortedRecordings,
            overrides: overrides,
            userName: userName,
            inputSortComparisonCount: inputSortComparisonCount,
            collectMetrics: collectMetrics
        )

        return Resolution(
            folders: builtInFolders + personResolution.folders,
            personMetrics: personResolution.metrics
        )
    }

    static func recordingIDs(
        in folderID: String,
        recordings: [RecordingDTO],
        overrides: SmartFolderOverrides,
        userName: String = ""
    ) -> [UUID] {
        smartFolders(for: recordings, overrides: overrides, userName: userName)
            .first { $0.id == folderID }?
            .recordingIDs ?? []
    }

    static func sidebarFolders(from folders: [SmartFolderDTO]) -> [SmartFolderDTO] {
        folders.filter { SmartFolderID(rawValue: $0.id) != nil }
    }

    // MARK: - Built-in Definitions

    private struct Definition {
        let id: String
        let title: String
        let subtitle: String?
        let icon: String
        let iconColor: String
        let matches: @Sendable (RecordingDTO) -> Bool
    }

    private static var builtInDefinitions: [Definition] {
        [
            Definition(
                id: SmartFolderID.oneOnOnes.rawValue,
                title: String(localized: "1:1s"),
                subtitle: String(localized: "Automatically grouped one-on-one meetings"),
                icon: "person.2",
                iconColor: "purple",
                matches: isOneOnOne
            ),
            Definition(
                id: SmartFolderID.teamMeetings.rawValue,
                title: String(localized: "Team Meetings"),
                subtitle: String(localized: "Standups, planning, retros, and design reviews"),
                icon: "person.3",
                iconColor: "blue",
                matches: isTeamMeeting
            ),
            Definition(
                id: SmartFolderID.clientMeetings.rawValue,
                title: String(localized: "Client Meetings"),
                subtitle: String(localized: "Customer, client, and QBR conversations"),
                icon: "briefcase",
                iconColor: "orange",
                matches: isClientMeeting
            ),
            Definition(
                id: SmartFolderID.interviews.rawValue,
                title: String(localized: "Interviews"),
                subtitle: String(localized: "Candidate and hiring conversations"),
                icon: "person.crop.circle.badge.questionmark",
                iconColor: "green",
                matches: isInterview
            )
        ]
    }

    // MARK: - Matching

    private static func makeFolder(
        id: String,
        title: String,
        subtitle: String?,
        icon: String,
        iconColor: String,
        recordings: [RecordingDTO],
        overrides: SmartFolderOverrides,
        matches: (RecordingDTO) -> Bool
    ) -> SmartFolderDTO? {
        let pinned = overrides.pinnedIDs(for: id)
        let excluded = overrides.excludedIDs(for: id)
        let ids = recordings
            .filter { (matches($0) || pinned.contains($0.id)) && !excluded.contains($0.id) }
            .map(\.id)

        guard !ids.isEmpty else { return nil }
        return SmartFolderDTO(
            id: id,
            title: title,
            subtitle: subtitle,
            icon: icon,
            iconColor: iconColor,
            recordingIDs: ids
        )
    }

    private static func isOneOnOne(_ recording: RecordingDTO) -> Bool {
        meetingType(for: recording) == .oneOnOne
            || titleContains(recording.title, [
                "1:1", "1 on 1", "1-on-1", "one on one", "one-on-one", "skip level", "skip-level"
            ])
    }

    private static func isTeamMeeting(_ recording: RecordingDTO) -> Bool {
        if let type = meetingType(for: recording),
           [.standup, .allHands, .sprintPlanning, .retrospective, .designReview].contains(type) {
            return true
        }
        return titleContains(recording.title, [
            "standup", "daily sync", "weekly sync", "team sync", "team meeting",
            "sprint planning", "planning", "retrospective", "retro", "design review", "all hands", "town hall"
        ])
    }

    private static func isClientMeeting(_ recording: RecordingDTO) -> Bool {
        meetingType(for: recording) == .clientMeeting
            || titleContains(recording.title, ["client", "customer", "qbr", "account review"])
    }

    private static func isInterview(_ recording: RecordingDTO) -> Bool {
        meetingType(for: recording) == .interview
            || titleContains(recording.title, ["interview", "candidate", "hiring screen", "phone screen"])
    }

    private static func titleContains(_ title: String, _ needles: [String]) -> Bool {
        let normalized = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        return needles.contains { normalized.contains($0) }
    }

    private static func meetingType(for recording: RecordingDTO) -> MeetingType? {
        guard let rawValue = recording.meetingType else { return nil }
        return MeetingType(rawValue: rawValue)
    }

    // MARK: - 1:1 Person Folders

    private struct PersonGroup {
        let displayName: String
        var recordingIDs: [UUID]
    }

    private struct PersonFolderResolution {
        let folders: [SmartFolderDTO]
        let metrics: SmartFolderPersonClassificationMetrics
    }

    private static func oneOnOnePersonFolders(
        for recordings: [RecordingDTO],
        overrides: SmartFolderOverrides,
        userName: String,
        inputSortComparisonCount: Int,
        collectMetrics: Bool
    ) -> PersonFolderResolution {
        var groups: [String: PersonGroup] = [:]
        var recordingOrderByID: [UUID: Int] = [:]
        var groupedRecordingCount = 0

        // Build membership and global sort positions in one pass. Folder
        // assembly below then touches only that folder's IDs and overrides.
        for (index, recording) in recordings.enumerated() {
            if recordingOrderByID[recording.id] == nil {
                recordingOrderByID[recording.id] = index
            }
            guard isOneOnOne(recording),
                  let displayName = personName(from: recording.title, userName: userName)
            else { continue }
            let slug = slugify(displayName)
            guard !slug.isEmpty else { continue }
            groups[slug, default: PersonGroup(displayName: displayName, recordingIDs: [])]
                .recordingIDs.append(recording.id)
            if collectMetrics {
                groupedRecordingCount += 1
            }
        }

        var overrideIDCount = 0
        var recordingOrderLookupCount = 0
        var recordingOrderComparisonCount = 0
        var folders: [SmartFolderDTO] = []
        folders.reserveCapacity(groups.count)

        for (slug, group) in groups {
            let folderID = "oneOnOne.person.\(slug)"
            let pinned = overrides.pinnedIDs(for: folderID)
            let excluded = overrides.excludedIDs(for: folderID)
            if collectMetrics {
                overrideIDCount += pinned.count + excluded.count
            }

            var includedIDs = Set(group.recordingIDs)
            includedIDs.formUnion(pinned)
            includedIDs.subtract(excluded)
            if collectMetrics {
                recordingOrderLookupCount += includedIDs.count
            }

            var rankedIDs = includedIDs.compactMap { recordingID -> (id: UUID, order: Int)? in
                guard let order = recordingOrderByID[recordingID] else { return nil }
                return (recordingID, order)
            }
            if collectMetrics {
                rankedIDs.sort { lhs, rhs in
                    recordingOrderComparisonCount += 1
                    return lhs.order < rhs.order
                }
            } else {
                rankedIDs.sort { $0.order < $1.order }
            }
            guard !rankedIDs.isEmpty else { continue }

            folders.append(
                SmartFolderDTO(
                    id: folderID,
                    title: String(localized: "1:1 / \(group.displayName)"),
                    subtitle: String(localized: "Recurring one-on-one conversations"),
                    icon: "person.crop.circle",
                    iconColor: "purple",
                    recordingIDs: rankedIDs.map(\.id)
                )
            )
        }

        var folderSortComparisonCount = 0
        if collectMetrics {
            folders.sort { lhs, rhs in
                folderSortComparisonCount += 1
                return personFolderSortsBefore(lhs, rhs)
            }
        } else {
            folders.sort(by: personFolderSortsBefore)
        }

        return PersonFolderResolution(
            folders: folders,
            metrics: SmartFolderPersonClassificationMetrics(
                inputRecordingCount: recordings.count,
                inputSortComparisonCount: inputSortComparisonCount,
                groupedRecordingCount: groupedRecordingCount,
                overrideIDCount: overrideIDCount,
                recordingOrderLookupCount: recordingOrderLookupCount,
                recordingOrderComparisonCount: recordingOrderComparisonCount,
                folderSortComparisonCount: folderSortComparisonCount,
                personFolderCount: folders.count
            )
        )
    }

    private static func personFolderSortsBefore(
        _ lhs: SmartFolderDTO,
        _ rhs: SmartFolderDTO
    ) -> Bool {
        if lhs.recordingCount == rhs.recordingCount {
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
        return lhs.recordingCount > rhs.recordingCount
    }

    private static func personName(from title: String, userName: String) -> String? {
        let userTokens = Set(tokens(from: userName).map { $0.lowercased() })
        return tokens(from: title)
            .first { token in
                let lowercased = token.lowercased()
                guard token.rangeOfCharacter(from: .letters) != nil else { return false }
                guard lowercased.count >= 2 else { return false }
                guard !userTokens.contains(lowercased) else { return false }
                return !oneOnOneFillerWords.contains(lowercased)
            }
            .map(displayName)
    }

    private static func tokens(from value: String) -> [String] {
        value
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func displayName(from token: String) -> String {
        if token == token.uppercased(), token.count <= 4 {
            return token
        }
        return token.prefix(1).uppercased() + token.dropFirst().lowercased()
    }

    private static func slugify(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    private static let oneOnOneFillerWords: Set<String> = [
        "one", "on", "and", "with", "skip", "level", "sync", "meeting", "weekly",
        "biweekly", "monthly", "career", "growth", "discussion", "check", "checkin",
        "in", "catchup", "catch", "up"
    ]

    private static func sortNewestFirst(_ lhs: RecordingDTO, _ rhs: RecordingDTO) -> Bool {
        if lhs.startDate == rhs.startDate {
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
        return lhs.startDate > rhs.startDate
    }
}

struct SmartFolderOverrideStore {
    enum MutationFailure: Sendable, Equatable {
        case encodingFailed
        case writeFailed
    }

    struct MutationResult: Sendable, Equatable {
        let requestedCount: Int
        let changedCount: Int
        let failure: MutationFailure?

        var didCommit: Bool { failure == nil }
    }

    private enum Mutation {
        case pin
        case exclude
        case clear
    }

    private enum Key {
        static var overrides: String { ActiveProfileDefaults.key("smartFolders.overrides.v2") }
        static var pinned: String { ActiveProfileDefaults.key("smartFolders.pinned.v1") }
        static var excluded: String { ActiveProfileDefaults.key("smartFolders.excluded.v1") }
    }

    private struct StoredDocument: Codable {
        static let currentVersion = 2

        let version: Int
        let overrides: SmartFolderOverrides

        init(overrides: SmartFolderOverrides) {
            self.version = Self.currentVersion
            self.overrides = overrides
        }
    }

    private let dataForKey: (String) -> Data?
    private let setData: (Data, String) -> Bool
    private let encodeDocument: (SmartFolderOverrides) throws -> Data

    init(defaults: UserDefaults = .standard) {
        self.dataForKey = { defaults.data(forKey: $0) }
        self.setData = {
            defaults.set($0, forKey: $1)
            return true
        }
        self.encodeDocument = Self.encode
    }

    func load() -> SmartFolderOverrides {
        load(migrateLegacy: true)
    }

#if DEBUG
    init(
        dataForKey: @escaping (String) -> Data?,
        setData: @escaping (Data, String) -> Bool
    ) {
        self.dataForKey = dataForKey
        self.setData = setData
        self.encodeDocument = Self.encode
    }

    init(
        dataForKey: @escaping (String) -> Data?,
        setData: @escaping (Data, String) -> Bool,
        encodeDocument: @escaping (SmartFolderOverrides) throws -> Data
    ) {
        self.dataForKey = dataForKey
        self.setData = setData
        self.encodeDocument = encodeDocument
    }
#endif

    func pin(recordingID: UUID, to folderID: String) {
        _ = pin(recordingIDs: [recordingID], to: folderID)
    }

    @discardableResult
    func pin(recordingIDs: Set<UUID>, to folderID: String) -> MutationResult {
        mutate(recordingIDs: recordingIDs, folderID: folderID, mutation: .pin)
    }

    func exclude(recordingID: UUID, from folderID: String) {
        _ = exclude(recordingIDs: [recordingID], from: folderID)
    }

    @discardableResult
    func exclude(recordingIDs: Set<UUID>, from folderID: String) -> MutationResult {
        mutate(recordingIDs: recordingIDs, folderID: folderID, mutation: .exclude)
    }

    func clear(recordingID: UUID, in folderID: String) {
        _ = clear(recordingIDs: [recordingID], in: folderID)
    }

    @discardableResult
    func clear(recordingIDs: Set<UUID>, in folderID: String) -> MutationResult {
        mutate(recordingIDs: recordingIDs, folderID: folderID, mutation: .clear)
    }

    private func mutate(
        recordingIDs: Set<UUID>,
        folderID: String,
        mutation: Mutation
    ) -> MutationResult {
        guard !recordingIDs.isEmpty else {
            return MutationResult(requestedCount: 0, changedCount: 0, failure: nil)
        }

        var overrides = load(migrateLegacy: false)
        let originalPinned = Set(overrides.pinned[folderID] ?? [])
        let originalExcluded = Set(overrides.excluded[folderID] ?? [])
        var pinned = originalPinned
        var excluded = originalExcluded

        switch mutation {
        case .pin:
            pinned.formUnion(recordingIDs)
            excluded.subtract(recordingIDs)
        case .exclude:
            excluded.formUnion(recordingIDs)
            pinned.subtract(recordingIDs)
        case .clear:
            pinned.subtract(recordingIDs)
            excluded.subtract(recordingIDs)
        }

        let changedCount = recordingIDs.reduce(into: 0) { count, recordingID in
            let originalState = (
                originalPinned.contains(recordingID),
                originalExcluded.contains(recordingID)
            )
            let newState = (
                pinned.contains(recordingID),
                excluded.contains(recordingID)
            )
            if originalState != newState { count += 1 }
        }
        guard changedCount > 0 else {
            return MutationResult(
                requestedCount: recordingIDs.count,
                changedCount: 0,
                failure: nil
            )
        }

        if pinned.isEmpty {
            overrides.pinned.removeValue(forKey: folderID)
        } else {
            overrides.pinned[folderID] = Self.sortedIDs(pinned)
        }
        if excluded.isEmpty {
            overrides.excluded.removeValue(forKey: folderID)
        } else {
            overrides.excluded[folderID] = Self.sortedIDs(excluded)
        }
        if let failure = save(overrides) {
            return MutationResult(
                requestedCount: recordingIDs.count,
                changedCount: 0,
                failure: failure
            )
        }
        return MutationResult(
            requestedCount: recordingIDs.count,
            changedCount: changedCount,
            failure: nil
        )
    }

    private func load(migrateLegacy: Bool) -> SmartFolderOverrides {
        if let data = dataForKey(Key.overrides),
           let document = try? JSONDecoder().decode(StoredDocument.self, from: data),
           document.version == StoredDocument.currentVersion {
            return Self.normalized(document.overrides)
        }

        let pinnedData = dataForKey(Key.pinned)
        let excludedData = dataForKey(Key.excluded)
        guard pinnedData != nil || excludedData != nil else { return .empty }
        let legacy = Self.normalized(SmartFolderOverrides(
            pinned: Self.decodeMap(pinnedData),
            excluded: Self.decodeMap(excludedData)
        ))
        if migrateLegacy {
            _ = save(legacy)
        }
        return legacy
    }

    private static func decodeMap(_ data: Data?) -> [String: [UUID]] {
        guard let data,
              let map = try? JSONDecoder().decode([String: [UUID]].self, from: data)
        else { return [:] }
        return map
    }

    private func save(_ overrides: SmartFolderOverrides) -> MutationFailure? {
        let data: Data
        do {
            data = try encodeDocument(Self.normalized(overrides))
        } catch {
            NSLog(
                "[SmartFolderOverrideStore] encode failed: %@",
                error.localizedDescription
            )
            return .encodingFailed
        }
        guard setData(data, Key.overrides) else {
            NSLog("[SmartFolderOverrideStore] versioned override write failed")
            return .writeFailed
        }
        return nil
    }

    private static func encode(_ overrides: SmartFolderOverrides) throws -> Data {
        try JSONEncoder().encode(StoredDocument(overrides: overrides))
    }

    private static func sortedIDs(_ ids: Set<UUID>) -> [UUID] {
        ids.sorted { $0.uuidString < $1.uuidString }
    }

    /// Legacy dual-key writes could be interrupted between keys. Preserve the
    /// old resolver's effective behavior (`excluded` wins), while removing
    /// duplicates before the state is committed to the atomic v2 document.
    private static func normalized(_ overrides: SmartFolderOverrides) -> SmartFolderOverrides {
        let folderIDs = Set(overrides.pinned.keys).union(overrides.excluded.keys)
        var pinned: [String: [UUID]] = [:]
        var excluded: [String: [UUID]] = [:]
        for folderID in folderIDs {
            let excludedIDs = Set(overrides.excluded[folderID] ?? [])
            var pinnedIDs = Set(overrides.pinned[folderID] ?? [])
            pinnedIDs.subtract(excludedIDs)
            if !pinnedIDs.isEmpty {
                pinned[folderID] = sortedIDs(pinnedIDs)
            }
            if !excludedIDs.isEmpty {
                excluded[folderID] = sortedIDs(excludedIDs)
            }
        }
        return SmartFolderOverrides(pinned: pinned, excluded: excluded)
    }
}
