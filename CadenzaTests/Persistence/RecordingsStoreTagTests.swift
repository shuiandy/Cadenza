import Testing
import SwiftData
@testable import Cadenza

@Suite("RecordingsStore tags", .serialized)
struct RecordingsStoreTagTests {

    @MainActor
    private func cleanDefaults() {
        let d = UserDefaults.standard
        d.removeObject(forKey: "tagBlocklist")
        d.removeObject(forKey: "tagNormalizationVersion")
        d.removeObject(forKey: "tagBlocklistFingerprint")
    }

    // MARK: - Vocabulary-aware addTag(allowNew:)

    @Test @MainActor
    func addTagAllowNewAddsToKnownVocabulary() async throws {
        cleanDefaults()
        let store = RecordingsStore(modelContainer: try RecordingsStore.makeContainer(inMemory: true))
        let a = UUID(), b = UUID()
        await store.createRecording(id: a, title: "A", startDate: Date(), segmentsDirURL: nil)
        await store.createRecording(id: b, title: "B", startDate: Date(), segmentsDirURL: nil)
        // Seed the library vocabulary with "wiz" (a tool name — not blocklisted).
        _ = await store.addTag(recordingID: a, tag: "wiz")

        // "wiz" is now known → accepted without allowNew.
        let outcome = await store.addTag(recordingID: b, tag: "Wiz", allowNew: false)
        #expect(outcome == .added(canonical: "wiz", isNew: false))
        #expect(await store.fetchRecordingDetail(recordingID: b)?.tags == ["wiz"])
    }

    @Test @MainActor
    func addTagRejectsBlocklistedWord() async throws {
        cleanDefaults()
        let store = RecordingsStore(modelContainer: try RecordingsStore.makeContainer(inMemory: true))
        let id = UUID()
        await store.createRecording(id: id, title: "R", startDate: Date(), segmentsDirURL: nil)
        // "security" is in the registered default blocklist (too generic) → rejected
        // even with allowNew, on both the 3-arg and 2-arg paths.
        #expect(await store.addTag(recordingID: id, tag: "security", allowNew: true) == .invalid)
        #expect(await store.fetchRecordingDetail(recordingID: id)?.tags.isEmpty == true)
    }

    @Test @MainActor
    func addTagRejectsUnknownWithoutAllowNew() async throws {
        cleanDefaults()
        let store = RecordingsStore(modelContainer: try RecordingsStore.makeContainer(inMemory: true))
        let id = UUID()
        await store.createRecording(id: id, title: "R", startDate: Date(), segmentsDirURL: nil)

        let outcome = await store.addTag(recordingID: id, tag: "brand-new-category", allowNew: false)
        #expect(outcome == .rejectedUnknown(canonical: "brand-new-category"))
        #expect(await store.fetchRecordingDetail(recordingID: id)?.tags.isEmpty == true)  // not written
    }

    @Test @MainActor
    func addTagAllowNewCreatesNewCategory() async throws {
        cleanDefaults()
        let store = RecordingsStore(modelContainer: try RecordingsStore.makeContainer(inMemory: true))
        let id = UUID()
        await store.createRecording(id: id, title: "R", startDate: Date(), segmentsDirURL: nil)

        let outcome = await store.addTag(recordingID: id, tag: "brand-new-category", allowNew: true)
        #expect(outcome == .added(canonical: "brand-new-category", isNew: true))
        #expect(await store.fetchRecordingDetail(recordingID: id)?.tags == ["brand-new-category"])
    }

    @Test @MainActor
    func addTagSaveFailureReportsPersistenceFailureAndDoesNotGhostCommit() async throws {
        cleanDefaults()
        let store = RecordingsStore(modelContainer: try RecordingsStore.makeContainer(inMemory: true))
        let id = UUID()
        #expect(await store.createRecording(
            id: id,
            title: "R",
            startDate: Date(),
            segmentsDirURL: nil
        ))

        await store._test_failNextSave()
        let outcome = await store.addTag(
            recordingID: id,
            tag: "brand-new-category",
            allowNew: true
        )

        #expect(outcome == .persistenceFailed)
        #expect(await store.fetchRecordingDetail(recordingID: id)?.tags.isEmpty == true)
        #expect(await store.updateTitle(recordingID: id, title: "Later save"))
        #expect(await store.fetchRecordingDetail(recordingID: id)?.tags.isEmpty == true)
    }

    @Test @MainActor
    func addTagAliasMatchesKnownVocabulary() async throws {
        cleanDefaults()
        let store = RecordingsStore(modelContainer: try RecordingsStore.makeContainer(inMemory: true))
        let a = UUID(), b = UUID()
        await store.createRecording(id: a, title: "A", startDate: Date(), segmentsDirURL: nil)
        await store.createRecording(id: b, title: "B", startDate: Date(), segmentsDirURL: nil)
        // Library has 合规 (via the alias map, "compliance" canonicalizes to 合规).
        _ = await store.addTag(recordingID: a, tag: "compliance")
        #expect(await store.fetchRecordingDetail(recordingID: a)?.tags == ["合规"])

        // Now "compliance" on B (allowNew:false) must hit the known 合规, not be rejected.
        let outcome = await store.addTag(recordingID: b, tag: "compliance", allowNew: false)
        #expect(outcome == .added(canonical: "合规", isNew: false))
    }

    @Test @MainActor
    func addTagAllowNewInvalidAndIdempotent() async throws {
        cleanDefaults()
        let store = RecordingsStore(modelContainer: try RecordingsStore.makeContainer(inMemory: true))
        let id = UUID()
        await store.createRecording(id: id, title: "R", startDate: Date(), segmentsDirURL: nil)

        #expect(await store.addTag(recordingID: id, tag: "   ", allowNew: true) == .invalid)
        #expect(await store.addTag(recordingID: UUID(), tag: "x", allowNew: true) == .recordingNotFound)

        _ = await store.addTag(recordingID: id, tag: "alpha", allowNew: true)
        let again = await store.addTag(recordingID: id, tag: "ALPHA", allowNew: false)
        #expect(again == .alreadyPresent(canonical: "alpha"))  // idempotent, not rejected
    }

    @Test @MainActor
    func addTagNormalizesAndDedups() async throws {
        cleanDefaults()
        let store = RecordingsStore(modelContainer: try RecordingsStore.makeContainer(inMemory: true))
        let id = UUID()
        await store.createRecording(id: id, title: "R", startDate: Date(), segmentsDirURL: nil)
        _ = await store.addTag(recordingID: id, tag: "One_On_One")
        _ = await store.addTag(recordingID: id, tag: "1-on-1")   // 同义，应去重
        let detail = await store.fetchRecordingDetail(recordingID: id)
        #expect(detail?.tags == ["1on1"])
    }

    @Test @MainActor
    func saveSummaryMergesAndKeepsManualTags() async throws {
        cleanDefaults()
        let store = RecordingsStore(modelContainer: try RecordingsStore.makeContainer(inMemory: true))
        let id = UUID()
        await store.createRecording(id: id, title: "R", startDate: Date(), segmentsDirURL: nil)
        _ = await store.addTag(recordingID: id, tag: "important")   // 手动
        let summary = SummaryResult(
            title: "T", overview: "o", keyPoints: [], actionItems: [],
            decisions: [], followUps: [], yourTasks: [],
            tags: ["standup", "important"], chapters: [], rawText: ""
        )
        _ = await store.saveSummary(recordingID: id, summary: summary, chaptersJSON: nil)
        let detail = await store.fetchRecordingDetail(recordingID: id)
        #expect(detail?.tags.contains("important") == true)   // 手动保留
        #expect(detail?.tags.contains("standup") == true)     // AI 并入
        #expect(detail?.tags.count == 2)                      // important 不重复
    }

    @Test @MainActor
    func tagFilterMatchesByFormatKey() async throws {
        cleanDefaults()
        let store = RecordingsStore(modelContainer: try RecordingsStore.makeContainer(inMemory: true))
        let id = UUID()
        await store.createRecording(id: id, title: "R", startDate: Date(), segmentsDirURL: nil)
        _ = await store.addTag(recordingID: id, tag: "Code Review")   // 存为 code-review
        let hit = await store.fetchRecordingDTOs(sortKey: "dateNewest", folderID: nil, tagFilter: "codereview")
        #expect(hit.count == 1)
    }

    @Test @MainActor
    func distinctTagsCountsAndFiltersByLanguage() async throws {
        cleanDefaults()
        let store = RecordingsStore(modelContainer: try RecordingsStore.makeContainer(inMemory: true))
        let a = UUID(); let b = UUID()
        await store.createRecording(id: a, title: "A", startDate: Date(), segmentsDirURL: nil)
        await store.createRecording(id: b, title: "B", startDate: Date(), segmentsDirURL: nil)
        _ = await store.addTag(recordingID: a, tag: "设计评审")
        _ = await store.addTag(recordingID: b, tag: "设计评审")
        _ = await store.addTag(recordingID: a, tag: "standup")        // latin (7, 无数字)
        let all = await store.distinctTags()
        #expect(all.first(where: { $0.tag == "设计评审" })?.count == 2)
        let zh = await store.distinctTags(language: "zh")
        #expect(zh.contains { $0.tag == "设计评审" })
        #expect(!zh.contains { $0.tag == "standup" })                 // latin 不喂给中文摘要
    }

    @Test @MainActor
    func migrationCleansDirtyTagsAndPicksFrequentSurface() async throws {
        cleanDefaults()
        let container = try RecordingsStore.makeContainer(inMemory: true)
        // 直接注入"脏"数据(绕过归一化),模拟迁移前的库。
        let ctx = ModelContext(container)
        let r1 = Recording(id: UUID(), title: "A", startDate: Date())
        r1.tags = ["1on1", "one_on_one", "oneonone"]
        let r2 = Recording(id: UUID(), title: "B", startDate: Date())
        r2.tags = ["Code Review", "Code Review", "codereview"]   // 频次: code-review×2, designreview×1
        ctx.insert(r1); ctx.insert(r2)
        try ctx.save()

        let store = RecordingsStore(modelContainer: container)
        #expect(await store.normalizeAllTagsIfNeeded(force: true))
        // 幂等: 再跑一次结果不变
        #expect(await store.normalizeAllTagsIfNeeded(force: true))

        let dtos = await store.fetchRecordingDTOs(sortKey: "nameAZ", folderID: nil, tagFilter: nil)
        let byTitle = Dictionary(uniqueKeysWithValues: dtos.map { ($0.title, $0.tags) })
        #expect(byTitle["A"] == ["1on1"])              // 变体合并
        #expect(byTitle["B"] == ["code-review"])      // 脏 surface 清洗为频次高的规范形(非原样保留)
    }
}
