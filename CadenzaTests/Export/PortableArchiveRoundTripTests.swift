import Foundation
import SwiftData
import Testing
@testable import Cadenza

/// End-to-end round trip: real in-memory RecordingsStore fixture → real
/// PortableArchiveWriter → validator + independent relationship-graph
/// comparison. This is the CI gate behind the "Portable Archive" claim
/// (spec §12.2): counts, hashes, entity decode, referential integrity and
/// the normalized DTO graph must all survive the trip.
@Suite("PortableArchiveRoundTrip", .serialized)
struct PortableArchiveRoundTripTests {

    @Test @MainActor
    func archiveRoundTripsFixtureStore() async throws {
        let container = try RecordingsStore.makeContainer(inMemory: true)
        let store = RecordingsStore(modelContainer: container)
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveRoundTrip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        await store.setAudioRootForTesting(work)
        let baseDate = Date(timeIntervalSince1970: 1_785_628_800)

        // ---- Fixture: folder + speaker profile ----
        let folder = await store.createFolder(name: "Work", icon: "folder", iconColor: "blue")
        let profile = await store.createSpeakerProfile(displayName: "Andy")
        try #require(folder != nil)
        try #require(profile != nil)

        func makeAudioFile(_ name: String) throws -> String {
            let url = work.appendingPathComponent(name)
            try Data(repeating: 0xCD, count: 96).write(to: url)
            return url.path
        }

        // ---- 7 条常规录音：转录 + 摘要 + 音频，部分带 folder/tags ----
        var normalIDs: [UUID] = []
        var firstAudioPath: String?
        for index in 0..<7 {
            let id = UUID()
            normalIDs.append(id)
            await store.createRecording(
                id: id, title: "常规会议 \(index)",
                startDate: baseDate.addingTimeInterval(TimeInterval(index) * 3600),
                segmentsDirURL: nil
            )
            _ = await store.saveTranscript(
                recordingID: id,
                fullText: "第 \(index) 场会议的内容",
                segments: [
                    TranscriptEntry(startTime: 0, endTime: 5, text: "开场 \(index)", speaker: "SPEAKER_00"),
                    TranscriptEntry(startTime: 5, endTime: 9, text: "讨论 \(index)", speaker: "SPEAKER_01"),
                ],
                language: "zh",
                tags: index % 2 == 0 ? ["周会"] : ["评审"]
            )
            _ = await store.saveSummary(
                recordingID: id,
                summary: SummaryResult(
                    title: "常规会议 \(index)", overview: "第 \(index) 场概览",
                    keyPoints: ["要点"], actionItems: [ActionItemResult(assignee: "Bob", task: "任务 \(index)", deadline: nil)],
                    decisions: [], followUps: [], yourTasks: [], tags: [],
                    chapters: [], rawText: ""
                ),
                chaptersJSON: nil, language: "zh"
            )
            let audioPath = try makeAudioFile("normal-\(index).m4a")
            if index == 0 { firstAudioPath = audioPath }
            _ = await store.finalizeRecording(id: id, duration: 600, audioFileURL: URL(fileURLWithPath: audioPath))
            if index < 3, let folderID = folder?.id {
                _ = await store.moveToFolder(recordingID: id, folderID: folderID)
            }
        }
        // speaker mapping 在第一条上
        if let profileID = profile?.id {
            _ = await store.setSpeakerMapping(recordingID: normalIDs[0], rawLabel: "SPEAKER_00", profileID: profileID)
        }
        // 用户手动解除日历关联（.userCleared 是用户意图，必须随档）
        _ = await store.linkCalendarEvent(recordingID: normalIDs[1], calendarEventID: nil)
        // 声纹样本（embeddings 选装面，本测试 opt-in 以覆盖真实 round-trip）
        let profileModel = try container.mainContext.fetch(FetchDescriptor<SpeakerProfile>()).first
        let voiceSample = SpeakerVoiceSample(
            recordingID: normalIDs[0], rawLabel: "SPEAKER_00", profile: profileModel,
            embeddingData: Data([9, 9, 9, 9]), embeddingDimension: 4,
            sampleDuration: 2, nonOverlapRatio: 1, qualityScore: 0.8, modelVersion: "v1"
        )
        container.mainContext.insert(voiceSample)
        try container.mainContext.save()

        // ---- 特殊行 ----
        // 缺失音频：DB 引用了不存在的文件 → 归档必须记 failure
        let missingAudioID = UUID()
        await store.createRecording(id: missingAudioID, title: "音频丢失", startDate: baseDate, segmentsDirURL: nil)
        _ = await store.saveTranscript(
            recordingID: missingAudioID, fullText: "还有转录",
            segments: [TranscriptEntry(startTime: 0, endTime: 2, text: "还有转录")],
            language: "zh", tags: []
        )
        _ = await store.finalizeRecording(
            id: missingAudioID, duration: 600,
            audioFileURL: work.appendingPathComponent("vanished.m4a")
        )

        // unmerged：只有 segments 目录，无合并音频（崩溃恢复中的形态）
        let unmergedID = UUID()
        let segDir = work.appendingPathComponent("segments-\(unmergedID.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: segDir, withIntermediateDirectories: true)
        try Data(repeating: 0xEF, count: 48).write(to: segDir.appendingPathComponent("segment-000.m4a"))
        await store.createRecording(id: unmergedID, title: "未合并", startDate: baseDate, segmentsDirURL: segDir)

        // 回收站行
        let trashedID = UUID()
        await store.createRecording(id: trashedID, title: "已删除", startDate: baseDate, segmentsDirURL: nil)
        _ = await store.finalizeRecording(id: trashedID, duration: 600, audioFileURL: URL(fileURLWithPath: try makeAudioFile("trashed.m4a")))
        _ = await store.trashRecording(recordingID: trashedID, reason: "test")

        // agent artifact
        _ = await store.writeExternalArtifact(ArtifactCandidate(
            kind: .meetingPrep, targetType: .calendarEvent, targetKey: "evt-1",
            bodyMarkdown: "# 会前简报", provenanceSource: .external, provenanceDetail: "test",
            status: .ready, generationID: nil, generatingStartedAt: nil,
            errorClass: nil, errorMessage: nil,
            targetStartDate: baseDate, targetEndDate: baseDate.addingTimeInterval(1800),
            targetFingerprint: "fp", contextBuiltAt: baseDate, staleReason: nil
        ))

        // ---- 全字段非默认 sentinel（防"字段被映射成默认值仍全绿"）----
        // 经 mainContext 全新插入（actor 从未注册过这些行 → fetch 必然新鲜）。
        let mainContext = container.mainContext
        let sentinelDate = baseDate.addingTimeInterval(9 * 3600)

        let zoeProfile = SpeakerProfile(displayName: "Zoe", notes: "sentinel-notes", teamOrOrg: "ACME")
        zoeProfile.aliases = ["Z", "Zoé"]
        zoeProfile.createdAt = sentinelDate
        zoeProfile.lastSeenAt = sentinelDate.addingTimeInterval(60)
        mainContext.insert(zoeProfile)

        let parentFolder = Folder(name: "Clients", icon: "briefcase", iconColor: "red",
                                  colorHex: "#00FF00", status: "archived", sortOrder: 7)
        let childFolder = Folder(name: "Acme", icon: "building.2", iconColor: "purple",
                                 colorHex: "#FF0000", status: "archived", sortOrder: 8)
        childFolder.parentFolder = parentFolder
        mainContext.insert(parentFolder)
        mainContext.insert(childFolder)

        let sentinelID = UUID()
        let sentinel = Recording(id: sentinelID, title: "哨兵完整字段",
                                 startDate: sentinelDate, language: "en", source: .external)
        sentinel.endDate = sentinelDate.addingTimeInterval(1234)
        sentinel.duration = 1234
        sentinel.meetingApp = "Teams"
        sentinel.meetingURL = "https://teams.microsoft.com/meet/sentinel"
        sentinel.meetingType = "standup"
        sentinel.linkedCalendarEventID = "evt-sentinel"
        sentinel.calendarAutoLinkState = CalendarAutoLinkState.linked.rawValue
        sentinel.tags = ["sentinel", "全字段"]
        sentinel.createdAt = sentinelDate.addingTimeInterval(-100)
        sentinel.updatedAt = sentinelDate.addingTimeInterval(200)
        sentinel.speakerMappings = [SpeakerLabelMapping(rawLabel: "SPEAKER_09", profileID: zoeProfile.id)]
        sentinel.ownership = .userOwned
        sentinel.folder = childFolder
        let sentinelTranscript = Transcript(fullText: "sentinel transcript", segments: [
            TranscriptEntry(startTime: 1.5, endTime: 4.25, text: "sentinel line", speaker: "SPEAKER_09")
        ])
        sentinelTranscript.detectedLanguage = "en"
        sentinelTranscript.createdAt = sentinelDate
        sentinel.transcript = sentinelTranscript
        let sentinelSummary = MeetingSummary(
            overview: "sentinel overview",
            keyPoints: ["kp1", "kp2"],
            actionItems: [ActionItem(assignee: "Zoe", task: "审阅归档", deadline: "周一",
                                     isCompleted: true, priority: .high,
                                     createdAt: sentinelDate, updatedAt: sentinelDate)],
            decisions: ["决定 X"], followUps: ["跟进 Y"], yourTasks: ["我的 Z"],
            model: "model-9", language: "en"
        )
        sentinelSummary.provider = "custom-provider"
        sentinelSummary.createdAt = sentinelDate
        sentinelSummary.chaptersJSON = String(
            decoding: try JSONEncoder().encode([ChapterDTO(title: "开场", startSeconds: 12, summary: "章节摘要")]),
            as: UTF8.self
        )
        sentinel.summary = sentinelSummary
        mainContext.insert(sentinel)

        let sentinelRecap = Recap(
            period: "weekly",
            startDate: sentinelDate, endDate: sentinelDate.addingTimeInterval(7 * 86400),
            title: "sentinel recap", overview: "recap overview",
            sections: [RecapSection(category: "wins", summary: "赢了", recordingIDs: [sentinelID])],
            stats: RecapStats(meetingCount: 3, totalDuration: 5400, actionItemCount: 2, decisionCount: 1),
            recordingIDs: [sentinelID, normalIDs[0]],
            allActionItems: ["A1"], allDecisions: ["D1"],
            provider: "gemini"
        )
        sentinelRecap.createdAt = sentinelDate
        mainContext.insert(sentinelRecap)
        try mainContext.save()

        // chat history
        let chatDir = work.appendingPathComponent("chat", isDirectory: true)
        try FileManager.default.createDirectory(at: chatDir, withIntermediateDirectories: true)
        try Data("{\"messages\":[]}".utf8).write(to: chatDir.appendingPathComponent("session-1.json"))

        // ---- 写归档（source 接线与 AppState 完全同构；embeddings opt-in）----
        let source = PortableArchiveSource(
            catalog: { try await store.fetchArchiveCatalog() },
            record: { try await store.fetchArchiveRecording(recordingID: $0) },
            voiceSamples: { try await store.fetchArchiveVoiceSamples(recordingID: $0) },
            chatHistoryDirectory: chatDir,
            appVersion: "round-trip-test"
        )
        let result = try await PortableArchiveWriter.write(
            toParent: work.appendingPathComponent("dest"),
            source: source,
            options: .init(includeVoiceEmbeddings: true),
            now: baseDate
        )

        // ---- 验证 ----
        #expect(result.recordingCount == 11)
        #expect(result.failureCount == 1)

        let archive = try PortableArchiveValidator.validate(at: result.archiveURL)
        #expect(archive.manifest.counts["recordings"] == 11)
        #expect(archive.manifest.counts["transcripts"] == 9)
        #expect(archive.manifest.counts["summaries"] == 8)
        #expect(archive.manifest.counts["folders"] == 3)
        #expect(archive.manifest.counts["recaps"] == 1)
        #expect(archive.manifest.counts["agentArtifacts"] == 1)
        #expect(archive.manifest.counts["speakerProfiles"] == 2)
        #expect(archive.manifest.counts["voiceSamples"] == 1)
        #expect(archive.manifest.includesVoiceEmbeddings)
        #expect(archive.manifest.unmergedRecordingIDs == [unmergedID])
        #expect(archive.manifest.failures.map(\.recordingID) == [missingAudioID])
        #expect(archive.artifacts.first?.bodyMarkdown == "# 会前简报")
        #expect(archive.manifest.files.map(\.path).contains("chat-history/session-1.json"))

        // 关系图：store 侧与归档侧各自独立构建后必须一致
        let fromStore = try await ArchiveNormalizer.fromStore(store)
        let fromArchive = ArchiveNormalizer.fromArchive(archive)
        #expect(fromStore.count == 11)
        #expect(fromStore == fromArchive)

        // 真正的 round-trip：归档重建成新 in-memory store，
        // 全字段 snapshot 与源 store 必须一致（schema 少存任何用户字段即红）
        let rebuiltContainer = try PortableArchiveRestorer.rebuild(archive)
        let sourceSnapshot = try StoreSnapshot.capture(container)
        let rebuiltSnapshot = try StoreSnapshot.capture(rebuiltContainer)
        // 分集合比较：失败时可直接看到差异落点
        #expect(sourceSnapshot.folders == rebuiltSnapshot.folders)
        #expect(sourceSnapshot.profiles == rebuiltSnapshot.profiles)
        #expect(sourceSnapshot.recaps == rebuiltSnapshot.recaps)
        #expect(sourceSnapshot.artifacts == rebuiltSnapshot.artifacts)
        #expect(sourceSnapshot.voiceSamples == rebuiltSnapshot.voiceSamples)
        for (sourceRec, rebuiltRec) in zip(sourceSnapshot.recordings, rebuiltSnapshot.recordings)
        where sourceRec != rebuiltRec {
            Issue.record("recording mismatch \(sourceRec.id):\nsource:  \(sourceRec)\nrebuilt: \(rebuiltRec)")
            break
        }
        #expect(sourceSnapshot == rebuiltSnapshot)
        #expect(sourceSnapshot.recordings.count == 11)
        #expect(sourceSnapshot.profiles.count == 2)
        #expect(sourceSnapshot.recaps.count == 1)
        #expect(sourceSnapshot.artifacts.count == 1)
        #expect(sourceSnapshot.voiceSamples.count == 1)
        // fixture 真实生效的自证：非默认 sentinel 在源侧存在且随档往返
        #expect(sourceSnapshot.recordings.first { $0.id == normalIDs[1] }?
            .calendarAutoLinkState == CalendarAutoLinkState.userCleared.rawValue)
        #expect(rebuiltSnapshot.voiceSamples.first?.embeddingData == Data([9, 9, 9, 9]))
        let rebuiltSentinel = rebuiltSnapshot.recordings.first { $0.id == sentinelID }
        #expect(rebuiltSentinel?.meetingURL == "https://teams.microsoft.com/meet/sentinel")
        #expect(rebuiltSentinel?.calendarAutoLinkState == CalendarAutoLinkState.linked.rawValue)
        #expect(rebuiltSentinel?.summary?.provider == "custom-provider")
        #expect(rebuiltSentinel?.summary?.chapters == ["开场|12.0|章节摘要"])
        #expect(rebuiltSentinel?.summary?.actionItems.first?.contains("审阅归档|Zoe|周一|true|high") == true)
        let rebuiltRecap = rebuiltSnapshot.recaps.first
        #expect(rebuiltRecap?.provider == "gemini")
        #expect(rebuiltRecap?.sections.first?.contains("wins|赢了") == true)
        #expect(rebuiltRecap?.stats == "3|5400.0|2|1")
        #expect(rebuiltRecap?.recordingIDs == [sentinelID, normalIDs[0]])
        #expect(fromArchive.first { $0.id == sentinelID }?.folderPath == ["Clients", "Acme"])
        #expect(rebuiltSnapshot.profiles.first { $0.displayName == "Zoe" }?.aliases == ["Z", "Zoé"])

        // 抽查关键关系落点
        let normalized = Dictionary(uniqueKeysWithValues: fromArchive.map { ($0.id, $0) })
        #expect(normalized[normalIDs[0]]?.speakerMappings == ["SPEAKER_00→Andy"])
        #expect(normalized[normalIDs[0]]?.folderPath == ["Work"])
        #expect(normalized[trashedID]?.isTrashed == true)
        #expect(normalized[missingAudioID]?.hasAudio == false)
        #expect(normalized[unmergedID]?.hasUnmergedSegments == true)
        #expect(normalized[normalIDs[6]]?.actionItems == ["任务 6|Bob|-|false"])

        // 字节级对账：归档内的音频/分段/聊天文件必须与源文件逐字节一致
        // （manifest hash 只证明归档内部自洽，不证明复制保真）
        let sourceAudioPath = try #require(firstAudioPath)
        let archivedAudio = try Data(contentsOf: result.archiveURL
            .appendingPathComponent("audio/\(normalIDs[0].uuidString).m4a"))
        #expect(archivedAudio == (try Data(contentsOf: URL(fileURLWithPath: sourceAudioPath))))

        let archivedSegment = try Data(contentsOf: result.archiveURL
            .appendingPathComponent("segments/\(unmergedID.uuidString)/segment-000.m4a"))
        #expect(archivedSegment == (try Data(contentsOf: segDir.appendingPathComponent("segment-000.m4a"))))

        let archivedChat = try Data(contentsOf: result.archiveURL
            .appendingPathComponent("chat-history/session-1.json"))
        #expect(archivedChat == (try Data(contentsOf: chatDir.appendingPathComponent("session-1.json"))))
    }

    @Test @MainActor
    func voiceSampleFetchOrderIsStableAcrossCalls() async throws {
        let container = try RecordingsStore.makeContainer(inMemory: true)
        let store = RecordingsStore(modelContainer: container)
        let recordingID = UUID()
        let baseDate = Date(timeIntervalSince1970: 1_785_628_800)
        // 乱序插入 3 个不同 label 的样本（SwiftData 默认枚举顺序未定义）
        for (label, byte) in [("SPEAKER_02", UInt8(3)), ("SPEAKER_00", 1), ("SPEAKER_01", 2)] {
            let sample = SpeakerVoiceSample(
                recordingID: recordingID, rawLabel: label,
                embeddingData: Data([byte]), embeddingDimension: 1,
                sampleDuration: 1, nonOverlapRatio: 1, qualityScore: 0.5, modelVersion: "v1"
            )
            sample.createdAt = baseDate
            container.mainContext.insert(sample)
        }
        // 深层 tie-breaker 路径：label/createdAt/embeddingData 全相同，
        // 仅 modelVersion 与 qualityScore 不同——全序仍必须稳定区分
        for (model, quality) in [("vB", Float(0.9)), ("vA", 0.9), ("vA", 0.1)] {
            let twin = SpeakerVoiceSample(
                recordingID: recordingID, rawLabel: "SPEAKER_00",
                embeddingData: Data([1]), embeddingDimension: 1,
                sampleDuration: 1, nonOverlapRatio: 1, qualityScore: quality, modelVersion: model
            )
            twin.createdAt = baseDate
            container.mainContext.insert(twin)
        }
        try container.mainContext.save()

        let first = try await store.fetchArchiveVoiceSamples(recordingID: recordingID)
        let second = try await store.fetchArchiveVoiceSamples(recordingID: recordingID)
        #expect(first.count == 6)
        #expect(first.map(\.rawLabel) == ["SPEAKER_00", "SPEAKER_00", "SPEAKER_00",
                                          "SPEAKER_00", "SPEAKER_01", "SPEAKER_02"])
        // twins 内部按 modelVersion → qualityScore 稳定排序（v1 < vA(0.1) < vA(0.9) < vB）
        let twinKeys = first.prefix(4).map { "\($0.modelVersion)|\($0.qualityScore)" }
        #expect(twinKeys == ["v1|0.5", "vA|0.1", "vA|0.9", "vB|0.9"])
        #expect(first.map { "\($0.modelVersion)|\($0.qualityScore)|\($0.rawLabel)" }
            == second.map { "\($0.modelVersion)|\($0.qualityScore)|\($0.rawLabel)" })
        #expect(first.map(\.embeddingData) == second.map(\.embeddingData))
    }

    @Test @MainActor
    func embeddingsBytesIdenticalAcrossInsertionOrdersEvenWithDelimiterCollisions() async throws {
        // 分隔符注入对（review 提供的构造）：旧的 "|" 拼接键会让这两条
        // 不同记录碰撞出同一个 key，SwiftData 未定义的枚举顺序随之泄漏进
        // embeddings.json。逐字段比较必须给出稳定全序 → 两个反向插入的
        // store 导出的 embeddings.json 必须逐字节相同。
        let recordingID = UUID(uuidString: "AAAAAAAA-1111-2222-3333-444444444444")!
        let fixedDate = Date(timeIntervalSince1970: 1_785_628_800)
        let injectionPair: [(rawLabel: String, modelVersion: String)] = [
            ("A", "B|807321600.0||C"),
            ("A|807321600.0||B", "C"),
        ]

        func makeArchive(insertionOrder: [Int], parent: URL) async throws -> URL {
            let container = try RecordingsStore.makeContainer(inMemory: true)
            let store = RecordingsStore(modelContainer: container)
            await store.createRecording(id: recordingID, title: "碰撞", startDate: fixedDate, segmentsDirURL: nil)
            for index in insertionOrder {
                let pair = injectionPair[index]
                let sample = SpeakerVoiceSample(
                    recordingID: recordingID, rawLabel: pair.rawLabel,
                    embeddingData: Data([1]), embeddingDimension: 1,
                    sampleDuration: 1, nonOverlapRatio: 1, qualityScore: 0.5,
                    modelVersion: pair.modelVersion
                )
                sample.createdAt = fixedDate
                container.mainContext.insert(sample)
            }
            try container.mainContext.save()
            let source = PortableArchiveSource(
                catalog: { try await store.fetchArchiveCatalog() },
                record: { try await store.fetchArchiveRecording(recordingID: $0) },
                voiceSamples: { try await store.fetchArchiveVoiceSamples(recordingID: $0) },
                chatHistoryDirectory: nil,
                appVersion: "collision-test"
            )
            let result = try await PortableArchiveWriter.write(
                toParent: parent, source: source,
                options: .init(includeVoiceEmbeddings: true),
                now: fixedDate
            )
            return result.archiveURL
        }

        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveCollision-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let forward = try await makeArchive(insertionOrder: [0, 1], parent: work.appendingPathComponent("f"))
        let reversed = try await makeArchive(insertionOrder: [1, 0], parent: work.appendingPathComponent("r"))

        let forwardBytes = try Data(contentsOf: forward.appendingPathComponent("entities/embeddings.json"))
        let reversedBytes = try Data(contentsOf: reversed.appendingPathComponent("entities/embeddings.json"))
        #expect(forwardBytes == reversedBytes)
        // 两条记录都在且可区分（没有被判等吞掉）
        let decoded = try PortableArchiveSchema.makeDecoder().decode([ArchiveVoiceSample].self, from: forwardBytes)
        #expect(decoded.count == 2)
        #expect(Set(decoded.map { Data($0.rawLabel.utf8) })
            == [Data("A".utf8), Data("A|807321600.0||B".utf8)])
        // comparator 本身的方向性：A 必须严格先于 B（且不满足双向 false 的假相等）
        let samples = try await {
            let container = try RecordingsStore.makeContainer(inMemory: true)
            let store = RecordingsStore(modelContainer: container)
            await store.createRecording(id: recordingID, title: "x", startDate: fixedDate, segmentsDirURL: nil)
            for pair in injectionPair {
                let sample = SpeakerVoiceSample(
                    recordingID: recordingID, rawLabel: pair.rawLabel,
                    embeddingData: Data([1]), embeddingDimension: 1,
                    sampleDuration: 1, nonOverlapRatio: 1, qualityScore: 0.5,
                    modelVersion: pair.modelVersion
                )
                sample.createdAt = fixedDate
                container.mainContext.insert(sample)
            }
            try container.mainContext.save()
            return try await store.fetchArchiveVoiceSamples(recordingID: recordingID)
        }()
        #expect(RecordingsStore.archiveVoiceSampleTotalOrder(samples[0], samples[1]))
        #expect(!RecordingsStore.archiveVoiceSampleTotalOrder(samples[1], samples[0]))
    }

    @Test @MainActor
    func embeddingsBytesIdenticalForCanonicallyEquivalentLabels() async throws {
        // Swift String 的 ==/< 按 canonical equivalence：NFC "é" == NFD "e◌́"
        // 且 < 双向 false，但 JSONEncoder 按原始 code units 输出不同字节。
        // comparator 必须按 UTF-8 code units 区分，否则 SwiftData 未定义顺序
        // 仍会泄漏进 embeddings.json。
        let nfc = "SPEAKER_\u{00E9}"          // é（单码位）
        let nfd = "SPEAKER_e\u{0301}"         // e + combining acute
        #expect(nfc == nfd)                    // String 语义判等（前提确认）
        #expect(Data(nfc.utf8) != Data(nfd.utf8)) // 字节不同（前提确认）

        let recordingID = UUID(uuidString: "BBBBBBBB-1111-2222-3333-444444444444")!
        let fixedDate = Date(timeIntervalSince1970: 1_785_628_800)

        func makeArchive(labels: [String], parent: URL) async throws -> URL {
            let container = try RecordingsStore.makeContainer(inMemory: true)
            let store = RecordingsStore(modelContainer: container)
            await store.createRecording(id: recordingID, title: "规范化", startDate: fixedDate, segmentsDirURL: nil)
            for label in labels {
                let sample = SpeakerVoiceSample(
                    recordingID: recordingID, rawLabel: label,
                    embeddingData: Data([1]), embeddingDimension: 1,
                    sampleDuration: 1, nonOverlapRatio: 1, qualityScore: 0.5, modelVersion: "v1"
                )
                sample.createdAt = fixedDate
                container.mainContext.insert(sample)
            }
            try container.mainContext.save()
            let source = PortableArchiveSource(
                catalog: { try await store.fetchArchiveCatalog() },
                record: { try await store.fetchArchiveRecording(recordingID: $0) },
                voiceSamples: { try await store.fetchArchiveVoiceSamples(recordingID: $0) },
                chatHistoryDirectory: nil,
                appVersion: "nfc-nfd-test"
            )
            return try await PortableArchiveWriter.write(
                toParent: parent, source: source,
                options: .init(includeVoiceEmbeddings: true),
                now: fixedDate
            ).archiveURL
        }

        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveNFC-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let forward = try await makeArchive(labels: [nfc, nfd], parent: work.appendingPathComponent("f"))
        let reversed = try await makeArchive(labels: [nfd, nfc], parent: work.appendingPathComponent("r"))

        let forwardBytes = try Data(contentsOf: forward.appendingPathComponent("entities/embeddings.json"))
        let reversedBytes = try Data(contentsOf: reversed.appendingPathComponent("entities/embeddings.json"))
        #expect(forwardBytes == reversedBytes)
        // 两种表示都存活且按字节可区分——比较 Data(utf8)，不用 Set<String>
        // （它同样按 canonical equivalence 合并）
        let decoded = try PortableArchiveSchema.makeDecoder().decode([ArchiveVoiceSample].self, from: forwardBytes)
        #expect(decoded.count == 2)
        #expect(Set(decoded.map { Data($0.rawLabel.utf8) }) == [Data(nfc.utf8), Data(nfd.utf8)])
    }

    @Test @MainActor
    func validatorRejectsTamperedArchive() async throws {
        let container = try RecordingsStore.makeContainer(inMemory: true)
        let store = RecordingsStore(modelContainer: container)
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveTamper-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        await store.setAudioRootForTesting(work)

        let id = UUID()
        await store.createRecording(id: id, title: "唯一", startDate: Date(timeIntervalSince1970: 1_785_628_800), segmentsDirURL: nil)
        _ = await store.saveTranscript(
            recordingID: id, fullText: "内容",
            segments: [TranscriptEntry(startTime: 0, endTime: 1, text: "内容")],
            language: "zh", tags: []
        )

        let source = PortableArchiveSource(
            catalog: { try await store.fetchArchiveCatalog() },
            record: { try await store.fetchArchiveRecording(recordingID: $0) },
            voiceSamples: { try await store.fetchArchiveVoiceSamples(recordingID: $0) },
            chatHistoryDirectory: nil,
            appVersion: "tamper-test"
        )
        let result = try await PortableArchiveWriter.write(
            toParent: work.appendingPathComponent("dest"),
            source: source,
            now: Date(timeIntervalSince1970: 1_785_628_800)
        )

        // 未篡改：通过
        _ = try PortableArchiveValidator.validate(at: result.archiveURL)

        // 篡改 entities 文件 → hash 校验必须失败
        let target = result.archiveURL.appendingPathComponent("entities/transcripts.json")
        var data = try Data(contentsOf: target)
        data.append(Data(" ".utf8))
        try data.write(to: target)
        #expect(throws: ArchiveValidationError.self) {
            _ = try PortableArchiveValidator.validate(at: result.archiveURL)
        }
    }
}
