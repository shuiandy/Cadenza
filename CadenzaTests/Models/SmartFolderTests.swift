import Foundation
import Testing

@testable import Cadenza

private final class SmartFolderPersistenceSpy {
    var storage: [String: Data] = [:]
    private(set) var writtenKeys: [String] = []

    func data(forKey key: String) -> Data? {
        storage[key]
    }

    func set(_ data: Data, forKey key: String) {
        storage[key] = data
        writtenKeys.append(key)
    }

    func resetWrites() {
        writtenKeys.removeAll()
    }
}

@Suite("Smart Folders", .serialized)
struct SmartFolderTests {
    private func recording(
        id: UUID = UUID(),
        title: String,
        meetingType: MeetingType?,
        tags: [String] = [],
        daysAgo: Int = 0
    ) -> RecordingDTO {
        RecordingDTO(
            id: id,
            title: title,
            startDate: Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date(),
            endDate: nil,
            duration: 1_800,
            meetingApp: nil,
            meetingURL: nil,
            language: "en",
            tags: tags,
            meetingType: meetingType?.rawValue,
            lastAccessedDate: nil,
            trashedDate: nil,
            folderID: nil,
            linkedCalendarEventID: nil,
            hasTranscript: true,
            hasSummary: true,
            transcriptPreview: nil,
            summaryPreview: nil,
            audioFile: nil
        )
    }

    @Test
    func builtInTypeFoldersMatchMeetingTypesAndTitleHints() {
        let oneOnOne = recording(title: "Andy / Caleb 1:1", meetingType: .oneOnOne)
        let standup = recording(title: "ProdSec weekly standup", meetingType: nil)
        let client = recording(title: "Customer QBR with Acme", meetingType: .clientMeeting)
        let general = recording(title: "Random notes", meetingType: .general)
        let folders = SmartFolderResolver.smartFolders(
            for: [oneOnOne, standup, client, general],
            overrides: .empty
        )

        #expect(folders.first(id: SmartFolderID.oneOnOnes.rawValue)?.recordingIDs == [oneOnOne.id])
        #expect(folders.first(id: SmartFolderID.teamMeetings.rawValue)?.recordingIDs == [standup.id])
        #expect(folders.first(id: SmartFolderID.clientMeetings.rawValue)?.recordingIDs == [client.id])
    }

    @Test
    func oneOnOnePeopleFoldersAreDerivedFromMeetingTitles() throws {
        let caleb1 = recording(title: "Andy / Caleb 1:1", meetingType: .oneOnOne, daysAgo: 2)
        let caleb2 = recording(title: "1:1 Caleb", meetingType: .oneOnOne, daysAgo: 1)
        let jy = recording(title: "Andy and JY skip level", meetingType: .oneOnOne)
        let folders = SmartFolderResolver.smartFolders(
            for: [caleb1, caleb2, jy],
            overrides: .empty,
            userName: "Andy"
        )

        let calebFolder = try #require(folders.first { $0.id == "oneOnOne.person.caleb" })
        #expect(calebFolder.title == "1:1 / Caleb")
        #expect(calebFolder.recordingIDs == [caleb2.id, caleb1.id])

        let jyFolder = try #require(folders.first { $0.id == "oneOnOne.person.jy" })
        #expect(jyFolder.title == "1:1 / JY")
        #expect(jyFolder.recordingIDs == [jy.id])
    }

    @Test
    func personFolderIndexPreservesLegacyMembershipOrderAndOverrides() throws {
        let manual = recording(title: "Career growth discussion", meetingType: .general)
        let newestCaleb = recording(
            title: "Andy / Caleb 1:1",
            meetingType: .oneOnOne,
            daysAgo: 1
        )
        let olderCaleb = recording(
            title: "1:1 Caleb",
            meetingType: .oneOnOne,
            daysAgo: 2
        )
        let jy = recording(
            title: "Andy / JY 1:1",
            meetingType: .oneOnOne,
            daysAgo: 3
        )
        let recordings = [olderCaleb, jy, manual, newestCaleb]
        let folderID = "oneOnOne.person.caleb"
        let overrides = SmartFolderOverrides(
            pinned: [folderID: [manual.id, UUID()]],
            excluded: [folderID: [newestCaleb.id]]
        )

        let folders = SmartFolderResolver.smartFolders(
            for: recordings,
            overrides: overrides,
            userName: "Andy"
        )
        let calebFolder = try #require(folders.first { $0.id == folderID })
        let legacyMatchedIDs = Set([newestCaleb.id, olderCaleb.id])
        let pinnedIDs = overrides.pinnedIDs(for: folderID)
        let excludedIDs = overrides.excludedIDs(for: folderID)
        let expectedIDs = recordings
            .sorted(by: newestFirst)
            .filter {
                (legacyMatchedIDs.contains($0.id) || pinnedIDs.contains($0.id))
                    && !excludedIDs.contains($0.id)
            }
            .map(\.id)

        #expect(calebFolder.recordingIDs == expectedIDs)
        #expect(calebFolder.recordingIDs == [manual.id, olderCaleb.id])
        #expect(folders.first { $0.id == "oneOnOne.person.jy" }?.recordingIDs == [jy.id])
    }

    @Test
    func personFolderClassificationWorkScalesWithIndexedInput() {
        let recordingCount = 1_500
        let recordings = (0..<recordingCount).map { index in
            recording(
                title: "1:1 Person\(String(format: "%04d", index))",
                meetingType: .oneOnOne
            )
        }

        let metrics = SmartFolderResolver.personClassificationMetrics(
            for: recordings,
            overrides: .empty
        )
        let logarithmicFactor = Int(ceil(log2(Double(recordingCount)))) + 1

        #expect(metrics.personFolderCount == recordingCount)
        #expect(metrics.inputRecordingCount == recordingCount)
        #expect(metrics.groupedRecordingCount == recordingCount)
        #expect(metrics.recordingOrderLookupCount == recordingCount)
        #expect(metrics.overrideIDCount == 0)
        #expect(metrics.recordingOrderComparisonCount == 0)
        #expect(metrics.measuredWorkCount <= recordingCount * logarithmicFactor * 8)
    }

    @Test
    func overridesCanExcludeRuleMatchesAndPinManualRecordings() {
        let matched = recording(id: UUID(), title: "Andy / Caleb 1:1", meetingType: .oneOnOne)
        let manual = recording(id: UUID(), title: "Career growth discussion", meetingType: .general)
        let overrides = SmartFolderOverrides(
            pinned: [SmartFolderID.oneOnOnes.rawValue: [manual.id]],
            excluded: [SmartFolderID.oneOnOnes.rawValue: [matched.id]]
        )

        let folders = SmartFolderResolver.smartFolders(for: [matched, manual], overrides: overrides)

        #expect(folders.first(id: SmartFolderID.oneOnOnes.rawValue)?.recordingIDs == [manual.id])
    }

    @Test
    func batchOverridesDeduplicateOneThousandIDsAndSwitchStateAtomically() throws {
        let suiteName = "SmartFolderTests.batch.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let folderID = SmartFolderID.oneOnOnes.rawValue
        let ids = Set((0..<1_000).map { _ in UUID() })
        let duplicatedID = try #require(ids.first)
        let legacyDuplicates = [folderID: [duplicatedID, duplicatedID]]
        defaults.set(
            try JSONEncoder().encode(legacyDuplicates),
            forKey: ActiveProfileDefaults.key("smartFolders.pinned.v1")
        )
        let store = SmartFolderOverrideStore(defaults: defaults)

        let pinResult = store.pin(recordingIDs: ids, to: folderID)
        let afterPin = store.load()

        #expect(pinResult.requestedCount == 1_000)
        #expect(pinResult.changedCount == 999)
        #expect(afterPin.pinned[folderID]?.count == 1_000)
        #expect(Set(afterPin.pinned[folderID] ?? []) == ids)
        #expect(afterPin.excluded[folderID] == nil)

        let excludeResult = store.exclude(recordingIDs: ids, from: folderID)
        let afterExclude = store.load()

        #expect(excludeResult.changedCount == 1_000)
        #expect(afterExclude.pinned[folderID] == nil)
        #expect(afterExclude.excluded[folderID]?.count == 1_000)
        #expect(Set(afterExclude.excluded[folderID] ?? []) == ids)

        let duplicateExclude = store.exclude(recordingIDs: ids, from: folderID)
        #expect(duplicateExclude.changedCount == 0)
        #expect(store.load().excluded[folderID]?.count == 1_000)

        let clearResult = store.clear(recordingIDs: ids, in: folderID)
        #expect(clearResult.changedCount == 1_000)
        #expect(store.load() == .empty)
    }

    @Test
    func legacyDualKeysMigrateToOneVersionedBlobWrite() throws {
        let spy = SmartFolderPersistenceSpy()
        let folderID = SmartFolderID.oneOnOnes.rawValue
        let pinnedOnly = UUID()
        let conflicting = UUID()
        spy.storage[ActiveProfileDefaults.key("smartFolders.pinned.v1")] = try JSONEncoder().encode([
            folderID: [pinnedOnly, conflicting, conflicting]
        ])
        spy.storage[ActiveProfileDefaults.key("smartFolders.excluded.v1")] = try JSONEncoder().encode([
            folderID: [conflicting]
        ])
        let store = SmartFolderOverrideStore(
            dataForKey: { spy.data(forKey: $0) },
            setData: {
                spy.set($0, forKey: $1)
                return true
            }
        )

        let migrated = store.load()

        let v2Key = ActiveProfileDefaults.key("smartFolders.overrides.v2")
        #expect(spy.writtenKeys == [v2Key])
        #expect(spy.storage[v2Key] != nil)
        #expect(migrated.pinned[folderID] == [pinnedOnly])
        #expect(migrated.excluded[folderID] == [conflicting])

        spy.resetWrites()
        #expect(store.load() == migrated)
        #expect(spy.writtenKeys.isEmpty)
    }

    @Test
    func pinToExcludeSwitchWritesOneBlobAndNeverPersistsDualState() throws {
        let spy = SmartFolderPersistenceSpy()
        let folderID = SmartFolderID.oneOnOnes.rawValue
        let ids = Set((0..<1_000).map { _ in UUID() })
        let store = SmartFolderOverrideStore(
            dataForKey: { spy.data(forKey: $0) },
            setData: {
                spy.set($0, forKey: $1)
                return true
            }
        )
        _ = store.pin(recordingIDs: ids, to: folderID)
        spy.resetWrites()

        let result = store.exclude(recordingIDs: ids, from: folderID)
        let persisted = store.load()

        #expect(result.changedCount == 1_000)
        #expect(spy.writtenKeys == [ActiveProfileDefaults.key("smartFolders.overrides.v2")])
        #expect(persisted.pinned[folderID] == nil)
        #expect(Set(persisted.excluded[folderID] ?? []) == ids)
        #expect(Set(persisted.pinned[folderID] ?? []).intersection(ids).isEmpty)
    }

    @Test
    func sidebarFoldersHideDerivedPeopleFolders() {
        let oneOnOne = recording(title: "Andy / Caleb 1:1", meetingType: .oneOnOne)
        let team = recording(title: "ProdSec weekly standup", meetingType: .standup)
        let folders = SmartFolderResolver.smartFolders(
            for: [oneOnOne, team],
            overrides: .empty,
            userName: "Andy"
        )

        let sidebarFolders = SmartFolderResolver.sidebarFolders(from: folders)

        #expect(sidebarFolders.map(\.id).contains(SmartFolderID.oneOnOnes.rawValue))
        #expect(sidebarFolders.map(\.id).contains(SmartFolderID.teamMeetings.rawValue))
        #expect(!sidebarFolders.contains { $0.id == "oneOnOne.person.caleb" })
    }

    @Test
    func cacheRebuildsSmartFolderDerivedStateOncePerSnapshot() throws {
        let oneOnOne = recording(title: "Andy / Caleb 1:1", meetingType: .oneOnOne)
        let team = recording(title: "ProdSec weekly standup", meetingType: .standup)
        var cache = SmartFolderCache()

        cache.rebuild(recordings: [oneOnOne, team], overrides: .empty, userName: "Andy")

        #expect(cache.sidebarFolders.map(\.id) == [SmartFolderID.oneOnOnes.rawValue, SmartFolderID.teamMeetings.rawValue])
        #expect(cache.targets.map(\.id) == SmartFolderID.allCases.map(\.rawValue))
        #expect(cache.recordings(in: SmartFolderID.oneOnOnes.rawValue).map(\.id) == [oneOnOne.id])
        #expect(cache.folder(id: SmartFolderID.teamMeetings.rawValue)?.recordingIDs == [team.id])

        cache.rebuild(recordings: [team], overrides: .empty, userName: "Andy")

        #expect(cache.sidebarFolders.map(\.id) == [SmartFolderID.teamMeetings.rawValue])
        #expect(cache.recordings(in: SmartFolderID.oneOnOnes.rawValue).isEmpty)
    }

    @MainActor @Test
    func menuTargetsAreStaticDefinitionsWithoutDerivedMembership() {
        let matchingRecording = recording(
            title: "Andy / Caleb 1:1",
            meetingType: .oneOnOne
        )
        let appState = AppState()
        appState.recordings = [matchingRecording]

        let targets = appState.smartFolderTargets

        #expect(targets.map(\.id) == SmartFolderID.allCases.map(\.rawValue))
        #expect(targets.allSatisfy { $0.recordingIDs.isEmpty })
    }

    private func newestFirst(_ lhs: RecordingDTO, _ rhs: RecordingDTO) -> Bool {
        if lhs.startDate == rhs.startDate {
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
        return lhs.startDate > rhs.startDate
    }
}

private extension Array where Element == SmartFolderDTO {
    func first(id: String) -> SmartFolderDTO? {
        first { $0.id == id }
    }
}
