import Foundation
import os
import Testing
@testable import Cadenza

@Suite("PortableArchiveWriter")
struct PortableArchiveWriterTests {

    /// 2026-08-02T00:00:00Z
    private let fixedDate = Date(timeIntervalSince1970: 1_785_628_800)

    private struct StubDiskSpace: DiskSpaceProviding {
        var capacity: Int64
        func availableCapacity(at url: URL) throws -> Int64 { capacity }
    }

    private struct ThrowingDiskSpace: DiskSpaceProviding {
        let message: String

        func availableCapacity(at url: URL) throws -> Int64 {
            throw RawArchiveFailure(message: message)
        }
    }

    private struct RawArchiveFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: - Fixtures

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PortableArchiveTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeDetail(
        id: UUID = UUID(),
        title: String = "会议",
        audioFileURL: URL? = nil,
        withTranscript: Bool = true,
        withSummary: Bool = false,
        tags: [String] = []
    ) -> RecordingDetailDTO {
        let transcript = withTranscript ? TranscriptDTO(
            id: UUID(), fullText: "大家好",
            segments: [TranscriptEntryDTO(id: UUID(), startTime: 0, endTime: 3, text: "大家好", speaker: "SPEAKER_00")],
            detectedLanguage: "zh", createdAt: fixedDate
        ) : nil
        let summary = withSummary ? SummaryDTO(
            id: UUID(), overview: "顺利", keyPoints: ["a"],
            actionItems: [ActionItemDTO(id: UUID(), assignee: "Bob", task: "写文档", deadline: nil,
                                        isCompleted: false, priority: "high")],
            decisions: [], followUps: [], yourTasks: [], provider: "gemini", model: "m",
            language: "zh", createdAt: fixedDate, chapters: []
        ) : nil
        return RecordingDetailDTO(
            id: id, title: title, startDate: fixedDate, endDate: nil, duration: 600,
            meetingApp: nil, meetingURL: nil, language: "zh", tags: tags, meetingType: nil,
            lastAccessedDate: nil, folderID: nil,
            audioFile: audioFileURL.map { .legacyAbsolute($0.path) },
            linkedCalendarEventID: nil, transcript: transcript, summary: summary,
            speakerMappings: [], speakerSuggestions: []
        )
    }

    /// Mirrors the store boundary: the record carries the resolved URL next
    /// to the detail reference.
    private func makeRecord(
        detail: RecordingDetailDTO,
        trashedDate: Date? = nil,
        segmentsDirURL: URL? = nil,
        calendarAutoLinkState: String? = nil
    ) -> ArchiveRecordingRecord {
        ArchiveRecordingRecord(
            detail: detail,
            trashedDate: trashedDate,
            audioFileURL: detail.audioFile.map { URL(fileURLWithPath: $0.storageValue) },
            audioSegmentsDirectoryURL: segmentsDirURL,
            calendarAutoLinkState: calendarAutoLinkState
        )
    }

    private func makeSource(
        records: [ArchiveRecordingRecord],
        folders: [ArchiveFolder] = [],
        speakerProfiles: [ArchiveSpeakerProfile] = [],
        voiceSamples: [UUID: [ArchiveVoiceSampleRecord]] = [:],
        chatDir: URL? = nil
    ) -> PortableArchiveSource {
        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.detail.id, $0) })
        let catalog = ArchiveCatalog(
            sizing: records.map {
                ArchiveSizingInfo(
                    recordingID: $0.detail.id,
                    audioFileURL: $0.audioFileURL,
                    audioSegmentsDirectoryURL: $0.audioSegmentsDirectoryURL
                )
            },
            folders: folders,
            recaps: [],
            artifacts: [],
            speakerProfiles: speakerProfiles
        )
        return PortableArchiveSource(
            catalog: { catalog },
            record: { byID[$0] },
            voiceSamples: { voiceSamples[$0] ?? [] },
            chatHistoryDirectory: chatDir,
            appVersion: "test"
        )
    }

    private func makeArchiveFolder(id: UUID = UUID(), name: String) -> ArchiveFolder {
        ArchiveFolder(id: id, name: name, parentFolderID: nil, icon: "folder",
                      iconColor: "blue", colorHex: nil, status: "active",
                      createdAt: fixedDate, sortOrder: 0)
    }

    /// 独立于 writer 的文件遍历（防循环验证：不复用 hashAllFiles）。
    private func walkFiles(under root: URL) throws -> [String] {
        var paths: [String] = []
        let rootPath = root.standardizedFileURL.path
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [] }
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let full = url.standardizedFileURL.path
            guard full.hasPrefix(rootPath + "/") else { continue }
            paths.append(String(full.dropFirst(rootPath.count + 1)))
        }
        return paths
    }

    private func makeVoiceSample(recordingID: UUID) -> ArchiveVoiceSampleRecord {
        ArchiveVoiceSampleRecord(
            recordingID: recordingID, rawLabel: "SPEAKER_00", profileID: nil,
            embeddingData: Data([1, 2, 3, 4]), embeddingDimension: 4,
            sampleDuration: 3, nonOverlapRatio: 1, qualityScore: 0.9,
            modelVersion: "v1", createdAt: fixedDate
        )
    }

    // MARK: - Tests

    @Test func writesVerifiableArchiveIncludingUnmergedAndFailures() async throws {
        let work = try makeTempDir()
        let parent = work.appendingPathComponent("dest")

        // rec1: 正常音频；rec2: DB 引用了不存在的音频；rec3: unmerged segments
        let audio1 = work.appendingPathComponent("a1.m4a")
        try Data(repeating: 0x01, count: 64).write(to: audio1)
        let segDir = work.appendingPathComponent("segments-src", isDirectory: true)
        try FileManager.default.createDirectory(at: segDir, withIntermediateDirectories: true)
        try Data(repeating: 0x02, count: 32).write(to: segDir.appendingPathComponent("segment-000.m4a"))
        try Data("{}".utf8).write(to: segDir.appendingPathComponent("segments.json"))

        let chatDir = work.appendingPathComponent("chat-src", isDirectory: true)
        try FileManager.default.createDirectory(at: chatDir, withIntermediateDirectories: true)
        try Data("{\"id\":1}".utf8).write(to: chatDir.appendingPathComponent("session.json"))

        let rec1 = UUID(), rec2 = UUID(), rec3 = UUID()
        let records = [
            makeRecord(
                detail: makeDetail(id: rec1, title: "正常", audioFileURL: audio1,
                                   withSummary: true, tags: ["周会"])
            ),
            makeRecord(
                detail: makeDetail(id: rec2, title: "坏音频",
                                   audioFileURL: work.appendingPathComponent("gone.m4a"))
            ),
            makeRecord(
                detail: makeDetail(id: rec3, title: "未合并"),
                trashedDate: fixedDate, segmentsDirURL: segDir
            ),
        ]
        let folder = makeArchiveFolder(name: "Work")

        let result = try await PortableArchiveWriter.write(
            toParent: parent,
            source: makeSource(records: records, folders: [folder], chatDir: chatDir),
            diskSpace: StubDiskSpace(capacity: .max / 2),
            now: fixedDate
        )

        #expect(result.recordingCount == 3)
        #expect(result.failureCount == 1)
        let archive = parent.appendingPathComponent("Cadenza Archive 2026-08-02.cadenza-archive")
        #expect(result.archiveURL == archive)
        #expect(FileManager.default.fileExists(atPath: archive.path))
        // staging 清理干净
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: parent.path)
            .filter { $0.hasPrefix(".cadenza-archive-staging") }
        #expect(leftovers.isEmpty)

        // manifest 校验
        let decoder = PortableArchiveSchema.makeDecoder()
        let manifest = try decoder.decode(
            PortableArchiveManifest.self,
            from: Data(contentsOf: archive.appendingPathComponent("manifest.json"))
        )
        #expect(manifest.archiveSchemaVersion == PortableArchiveSchema.version)
        #expect(manifest.counts["recordings"] == 3)
        #expect(manifest.counts["summaries"] == 1)
        #expect(manifest.counts["folders"] == 1)
        #expect(manifest.counts["tags"] == 1)
        #expect(manifest.unmergedRecordingIDs == [rec3])
        #expect(!manifest.includesVoiceEmbeddings)
        #expect(manifest.failures.count == 1)
        #expect(manifest.failures.first?.recordingID == rec2)

        let paths = Set(manifest.files.map(\.path))
        #expect(paths.contains("audio/\(rec1.uuidString).m4a"))
        #expect(paths.contains("segments/\(rec3.uuidString)/segment-000.m4a"))
        #expect(paths.contains("chat-history/session.json"))
        #expect(paths.contains("entities/recordings.json"))
        #expect(paths.contains("entities/speaker-profiles.json"))
        #expect(!paths.contains("entities/embeddings.json"))

        // 每个 manifest 条目 hash/size 与磁盘一致；磁盘上除 manifest 外无未登记文件
        // （用独立 enumerator 遍历，不复用 writer 的 hashAllFiles，防循环验证）
        for entry in manifest.files {
            let url = archive.appendingPathComponent(entry.path)
            #expect(try PortableArchiveWriter.sha256OfFile(at: url) == entry.sha256, "hash mismatch: \(entry.path)")
        }
        let onDisk = try walkFiles(under: archive).filter { $0 != "manifest.json" }
        #expect(Set(onDisk) == paths)

        // 实体内容抽查
        let archivedRecordings = try decoder.decode(
            [ArchiveRecording].self,
            from: Data(contentsOf: archive.appendingPathComponent("entities/recordings.json"))
        )
        #expect(archivedRecordings.map(\.id) == [rec1, rec2, rec3])
        #expect(archivedRecordings[0].hasAudio)
        #expect(!archivedRecordings[1].hasAudio)
        #expect(archivedRecordings[2].hasUnmergedSegments)
        #expect(archivedRecordings[2].trashedDate == fixedDate)
    }

    @Test func cancellationMidRunCleansStagingAndProducesNoArchive() async throws {
        let work = try makeTempDir()
        let parent = work.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        // 两条记录：第一条处理完（onProgress 触发）后请求取消 →
        // 此时 staging 已存在且有内容，清理路径被真实执行。
        let records = [
            makeRecord(detail: makeDetail(title: "一")),
            makeRecord(detail: makeDetail(title: "二")),
        ]
        let flag = OSAllocatedUnfairLock(initialState: false)
        do {
            _ = try await PortableArchiveWriter.write(
                toParent: parent,
                source: makeSource(records: records),
                diskSpace: StubDiskSpace(capacity: .max / 2),
                now: fixedDate,
                isCancelled: { flag.withLock { $0 } },
                onProgress: { done, _ in
                    if done >= 1 { flag.withLock { $0 = true } }
                }
            )
            Issue.record("expected cancellation")
        } catch let error as PortableArchiveError {
            #expect(error == .cancelled)
        }
        // staging 清干净，也没有 final 归档
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty)
    }

    @Test func danglingSpeakerMappingIsDroppedAndReported() async throws {
        let work = try makeTempDir()
        let parent = work.appendingPathComponent("dest")
        // mapping 指向 catalog 里不存在的 profile（catalog 之后新建的场景）
        var detail = makeDetail(title: "孤儿映射")
        detail.speakerMappings = [
            SpeakerLabelMappingDTO(rawLabel: "SPEAKER_00", profileID: UUID(), profileName: "Ghost")
        ]
        let record = makeRecord(detail: detail)

        let result = try await PortableArchiveWriter.write(
            toParent: parent,
            source: makeSource(records: [record]),
            diskSpace: StubDiskSpace(capacity: .max / 2),
            now: fixedDate
        )
        #expect(result.failureCount == 1)
        let decoder = PortableArchiveSchema.makeDecoder()
        let recordings = try decoder.decode(
            [ArchiveRecording].self,
            from: Data(contentsOf: result.archiveURL.appendingPathComponent("entities/recordings.json"))
        )
        #expect(recordings.first?.speakerMappings.isEmpty == true)
        // validator 的 mapping→profile 引用检查放行（因为写侧已清除）
        _ = try PortableArchiveValidator.validate(at: result.archiveURL)
    }

    @Test func sweepSkipsLiveOwnerAndRemovesDeadOwner() async throws {
        let work = try makeTempDir()
        let parent = work.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let fm = FileManager.default

        // 活进程（自己的 pid）拥有的 staging → 保留
        let live = parent.appendingPathComponent("\(PortableArchiveWriter.stagingPrefix)live", isDirectory: true)
        try fm.createDirectory(at: live, withIntermediateDirectories: true)
        try Data("\(ProcessInfo.processInfo.processIdentifier)".utf8)
            .write(to: PortableArchiveWriter.ownerMarkerURL(forStaging: live))

        // 死 pid 拥有的 staging → 清除
        let dead = parent.appendingPathComponent("\(PortableArchiveWriter.stagingPrefix)dead", isDirectory: true)
        try fm.createDirectory(at: dead, withIntermediateDirectories: true)
        try Data("999999".utf8)
            .write(to: PortableArchiveWriter.ownerMarkerURL(forStaging: dead))

        PortableArchiveWriter.sweepStaleStaging(in: parent)
        #expect(fm.fileExists(atPath: live.path))
        #expect(!fm.fileExists(atPath: dead.path))
        #expect(!fm.fileExists(atPath: PortableArchiveWriter.ownerMarkerURL(forStaging: dead).path))

        // 活 pid 但目录超龄（creationDate 之后再看 now+25h）→ 清除
        PortableArchiveWriter.sweepStaleStaging(
            in: parent, now: Date().addingTimeInterval(PortableArchiveWriter.staleAgeLimit + 3600)
        )
        #expect(!fm.fileExists(atPath: live.path))
    }

    @Test func danglingFolderReferenceIsClearedAndReported() async throws {
        let work = try makeTempDir()
        let parent = work.appendingPathComponent("dest")
        // 录音引用了 catalog 里不存在的 folder（catalog 拿到后被删的场景）
        let ghostFolderID = UUID()
        var detail = makeDetail(title: "孤儿引用")
        detail.folderID = ghostFolderID
        let record = makeRecord(detail: detail)

        let result = try await PortableArchiveWriter.write(
            toParent: parent,
            source: makeSource(records: [record], folders: [makeArchiveFolder(name: "Work")]),
            diskSpace: StubDiskSpace(capacity: .max / 2),
            now: fixedDate
        )
        #expect(result.failureCount == 1)

        let decoder = PortableArchiveSchema.makeDecoder()
        let manifest = try decoder.decode(
            PortableArchiveManifest.self,
            from: Data(contentsOf: result.archiveURL.appendingPathComponent("manifest.json"))
        )
        #expect(manifest.failures.first?.reason.contains("folder") == true)
        let recordings = try decoder.decode(
            [ArchiveRecording].self,
            from: Data(contentsOf: result.archiveURL.appendingPathComponent("entities/recordings.json"))
        )
        // 归档内部一致：引用被置空，validator 的 dangling 检查因此永不放行脏归档
        #expect(recordings.first?.folderID == nil)
        _ = try PortableArchiveValidator.validate(at: result.archiveURL)
    }

    @Test func staleStagingFromPreviousRunIsSwept() async throws {
        let work = try makeTempDir()
        let parent = work.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let fm = FileManager.default
        // 模拟上次崩溃残留的隐藏 staging 目录（无 marker，回溯超过宽限期）
        let stale = parent.appendingPathComponent(
            "\(PortableArchiveWriter.stagingPrefix)deadbeef", isDirectory: true
        )
        try fm.createDirectory(at: stale, withIntermediateDirectories: true)
        try Data(repeating: 0xFF, count: 16).write(to: stale.appendingPathComponent("orphan.bin"))
        try fm.setAttributes(
            [.creationDate: Date().addingTimeInterval(-PortableArchiveWriter.orphanGracePeriod - 60)],
            ofItemAtPath: stale.path
        )
        // 新鲜的无 marker 目录（竞态中间态）→ 必须保留
        let fresh = parent.appendingPathComponent(
            "\(PortableArchiveWriter.stagingPrefix)fresh", isDirectory: true
        )
        try fm.createDirectory(at: fresh, withIntermediateDirectories: true)

        let record = makeRecord(detail: makeDetail())
        _ = try await PortableArchiveWriter.write(
            toParent: parent,
            source: makeSource(records: [record]),
            diskSpace: StubDiskSpace(capacity: .max / 2),
            now: fixedDate
        )
        #expect(!fm.fileExists(atPath: stale.path))
        #expect(fm.fileExists(atPath: fresh.path))
    }

    @Test func markerOnlyStateGetsGracePeriod() throws {
        let work = try makeTempDir()
        let parent = work.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let fm = FileManager.default
        // 新鲜 marker-only（marker 先行、目录尚未创建的窗口）→ 保留
        let freshDir = parent.appendingPathComponent(
            "\(PortableArchiveWriter.stagingPrefix)pending", isDirectory: true
        )
        let freshMarker = PortableArchiveWriter.ownerMarkerURL(forStaging: freshDir)
        try Data("12345".utf8).write(to: freshMarker)
        // 陈旧 marker-only（目录早已搬走）→ 清除
        let staleDir = parent.appendingPathComponent(
            "\(PortableArchiveWriter.stagingPrefix)gone", isDirectory: true
        )
        let staleMarker = PortableArchiveWriter.ownerMarkerURL(forStaging: staleDir)
        try Data("12345".utf8).write(to: staleMarker)
        try fm.setAttributes(
            [.creationDate: Date().addingTimeInterval(-PortableArchiveWriter.orphanGracePeriod - 60)],
            ofItemAtPath: staleMarker.path
        )

        PortableArchiveWriter.sweepStaleStaging(in: parent)
        #expect(fm.fileExists(atPath: freshMarker.path))
        #expect(!fm.fileExists(atPath: staleMarker.path))
    }

    @Test func diskFullFailsBeforeWritingAnything() async throws {
        let work = try makeTempDir()
        let parent = work.appendingPathComponent("dest")
        let record = makeRecord(detail: makeDetail())
        do {
            _ = try await PortableArchiveWriter.write(
                toParent: parent,
                source: makeSource(records: [record]),
                diskSpace: StubDiskSpace(capacity: 1024),
                now: fixedDate
            )
            Issue.record("expected insufficientDiskSpace")
        } catch let error as PortableArchiveError {
            guard case .insufficientDiskSpace = error else {
                Issue.record("unexpected error \(error)")
                return
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty)
    }

    @Test func voiceEmbeddingsOnlyWhenOptedIn() async throws {
        let work = try makeTempDir()
        let id = UUID()
        let record = makeRecord(detail: makeDetail(id: id))
        let source = makeSource(records: [record], voiceSamples: [id: [makeVoiceSample(recordingID: id)]])
        let decoder = PortableArchiveSchema.makeDecoder()

        // 默认：不包含
        let off = try await PortableArchiveWriter.write(
            toParent: work.appendingPathComponent("off"), source: source,
            diskSpace: StubDiskSpace(capacity: .max / 2), now: fixedDate
        )
        #expect(!FileManager.default.fileExists(
            atPath: off.archiveURL.appendingPathComponent("entities/embeddings.json").path))
        let offManifest = try decoder.decode(
            PortableArchiveManifest.self,
            from: Data(contentsOf: off.archiveURL.appendingPathComponent("manifest.json"))
        )
        #expect(!offManifest.includesVoiceEmbeddings)
        #expect(offManifest.counts["voiceSamples"] == 0)

        // 勾选：包含且可解码
        let on = try await PortableArchiveWriter.write(
            toParent: work.appendingPathComponent("on"), source: source,
            options: .init(includeVoiceEmbeddings: true),
            diskSpace: StubDiskSpace(capacity: .max / 2), now: fixedDate
        )
        let samples = try decoder.decode(
            [ArchiveVoiceSample].self,
            from: Data(contentsOf: on.archiveURL.appendingPathComponent("entities/embeddings.json"))
        )
        #expect(samples.count == 1)
        #expect(samples.first?.embeddingData == Data([1, 2, 3, 4]))
    }

    @MainActor @Test func exporterMapsRawWriterFailureToLocalizedStableSummary() async throws {
        let rawCanary = #"RAW-ARCHIVE-{\"token\":\"secret-value\",\"path\":\"/private/archive\"}"#
        let exporter = PortableArchiveExporter()
        exporter.migrationGate = StorageMigrationGate()
        exporter.makeSource = { makeSource(records: []) }
        exporter.diskSpace = ThrowingDiskSpace(message: rawCanary)

        await exporter.export(toParent: try makeTempDir(), includeVoiceEmbeddings: false)

        guard case .failed(let message) = exporter.phase else {
            Issue.record("unexpected phase \(exporter.phase)")
            return
        }
        #expect(message == ExportError.unexpected("").localizedMessage())
        #expect(!message.contains(rawCanary))
        #expect(!message.contains("secret-value"))
        #expect(!message.contains("/private/archive"))

        let chinese = ExportError.unexpected(rawCanary).localizedMessage(
            locale: Locale(identifier: "zh-Hans")
        )
        #expect(chinese.contains("导出失败"))
        #expect(!chinese.contains(rawCanary))
        #expect(!chinese.contains("secret-value"))
    }

    @Test func entityEncodingIsDeterministic() async throws {
        let work = try makeTempDir()
        let recordID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
        let record = makeRecord(
            detail: makeDetail(id: recordID, withSummary: true, tags: ["b", "a"])
        )
        // 多个 samples：embeddings.json 的字节级确定性也要有直接证据
        let samples = [
            makeVoiceSample(recordingID: recordID),
            {
                var second = makeVoiceSample(recordingID: recordID)
                second.rawLabel = "SPEAKER_01"
                second.embeddingData = Data([5, 6, 7, 8])
                return second
            }(),
        ]
        let source = makeSource(records: [record], voiceSamples: [recordID: samples])
        let options = PortableArchiveWriter.Options(includeVoiceEmbeddings: true)
        let one = try await PortableArchiveWriter.write(
            toParent: work.appendingPathComponent("one"), source: source, options: options,
            diskSpace: StubDiskSpace(capacity: .max / 2), now: fixedDate
        )
        let two = try await PortableArchiveWriter.write(
            toParent: work.appendingPathComponent("two"), source: source, options: options,
            diskSpace: StubDiskSpace(capacity: .max / 2), now: fixedDate
        )
        for file in ["entities/recordings.json", "entities/summaries.json",
                     "entities/transcripts.json", "entities/embeddings.json", "manifest.json"] {
            let data1 = try Data(contentsOf: one.archiveURL.appendingPathComponent(file))
            let data2 = try Data(contentsOf: two.archiveURL.appendingPathComponent(file))
            #expect(data1 == data2, "nondeterministic \(file)")
        }

        // sortedKeys 的直接证据：counts 字典（唯一真正依赖 .sortedKeys 的
        // [String: Int]）在 manifest 字节里必须按字典序出现——同进程编码两次
        // 相等无法发现 sortedKeys 被移除，这里可以。
        let manifestText = String(
            decoding: try Data(contentsOf: one.archiveURL.appendingPathComponent("manifest.json")),
            as: UTF8.self
        )
        let countKeys = ["\"agentArtifacts\"", "\"folders\"", "\"recordings\"", "\"voiceSamples\""]
        let positions = countKeys.compactMap { manifestText.range(of: $0)?.lowerBound }
        #expect(positions.count == countKeys.count)
        #expect(positions == positions.sorted())
    }
}
