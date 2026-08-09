import Foundation
import Testing
@testable import Cadenza

@Suite("BatchFileExporter")
@MainActor
struct BatchFileExporterTests {

    /// 2026-08-02T00:00:00Z
    private let fixedDate = Date(timeIntervalSince1970: 1_785_628_800)

    // MARK: - Fixtures

    private struct StubDiskSpace: DiskSpaceProviding {
        var capacity: Int64
        func availableCapacity(at url: URL) throws -> Int64 { capacity }
    }

    private struct ThrowingDiskSpace: DiskSpaceProviding {
        let message: String

        func availableCapacity(at url: URL) throws -> Int64 {
            throw RawExportFailure(message: message)
        }
    }

    private struct RawExportFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BatchFileExporterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeTranscript(text: String = "大家好") -> TranscriptDTO {
        TranscriptDTO(
            id: UUID(),
            fullText: text,
            segments: [TranscriptEntryDTO(id: UUID(), startTime: 0, endTime: 5, text: text, speaker: "SPEAKER_00")],
            detectedLanguage: "zh",
            createdAt: fixedDate
        )
    }

    private func makeSummary() -> SummaryDTO {
        SummaryDTO(
            id: UUID(), overview: "进展顺利", keyPoints: [], actionItems: [], decisions: [],
            followUps: [], yourTasks: [], provider: "gemini", model: "m", language: "zh",
            createdAt: fixedDate, chapters: []
        )
    }

    private func makeDetail(
        id: UUID = UUID(),
        title: String = "产品周会",
        audioFilePath: String? = nil,
        folderID: UUID? = nil,
        transcript: TranscriptDTO? = nil,
        summary: SummaryDTO? = nil
    ) -> RecordingDetailDTO {
        RecordingDetailDTO(
            id: id, title: title, startDate: fixedDate, endDate: nil, duration: 600,
            meetingApp: nil, meetingURL: nil, language: "zh", tags: [], meetingType: nil,
            lastAccessedDate: nil, folderID: folderID,
            audioFile: audioFilePath.flatMap { AudioFileReference(storageValue: $0) },
            linkedCalendarEventID: nil, transcript: transcript, summary: summary,
            speakerMappings: [], speakerSuggestions: []
        )
    }

    /// Writes a fake audio file and returns its path.
    private func makeAudioFile(in dir: URL, name: String = "src.m4a", bytes: Int = 128) throws -> String {
        let url = dir.appendingPathComponent(name)
        try Data(repeating: 0xAB, count: bytes).write(to: url)
        return url.path
    }

    private func makeExporter(
        existingExporter: BatchFileExporter? = nil,
        details: [UUID: RecordingDetailDTO],
        capacity: Int64 = .max / 2,
        folders: [FolderDTO] = [],
        onFetch: (@MainActor (UUID) -> Void)? = nil
    ) -> BatchFileExporter {
        let exporter = existingExporter ?? BatchFileExporter()
        exporter.dependencies = BatchFileExporter.Dependencies(
            fetchDetail: { id in
                onFetch?(id)
                return details[id]
            },
            fetchAudioPaths: { ids in
                var paths: [UUID: URL] = [:]
                for id in ids {
                    if let value = details[id]?.audioFile?.storageValue, !value.isEmpty {
                        paths[id] = URL(fileURLWithPath: value)
                    }
                }
                return paths
            },
            fetchFolders: { folders },
            diskSpace: StubDiskSpace(capacity: capacity),
            now: { [fixedDate] in fixedDate }
        )
        return exporter
    }

    private func makeFolder(id: UUID = UUID(), name: String, parent: UUID? = nil) -> FolderDTO {
        FolderDTO(id: id, name: name, icon: "folder", iconColor: "blue", colorHex: nil,
                  status: "active", createdAt: fixedDate, sortOrder: 0,
                  recordingCount: 0, parentFolderID: parent, subfolderCount: 0)
    }

    private func runToCompletion(
        _ exporter: BatchFileExporter, ids: [UUID], options: BatchExportOptions, destination: URL
    ) async {
        await exporter.prepare(recordingIDs: ids, options: options, destination: destination)
        guard case .confirming = exporter.phase else { return }
        await exporter.confirmAndStart()
    }

    // MARK: - Tests

    @Test func runRefusedWhileMigrationClaimed() async throws {
        let work = try makeTempDir()
        let dest = work.appendingPathComponent("out")
        let id = UUID()
        let exporter = makeExporter(details: [id: makeDetail(id: id, transcript: makeTranscript())])
        let gate = StorageMigrationGate()
        exporter.migrationGate = gate
        #expect(gate.claimMigration())

        await exporter.prepareAndRun(
            recordingIDs: [id], options: BatchExportOptions(), destination: dest
        )

        guard case .failed = exporter.phase else {
            Issue.record("expected refusal, got \(exporter.phase)")
            return
        }
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: dest.path)) ?? []
        #expect(leftovers.isEmpty)
        gate.releaseMigration()
    }

    /// The run holds its lease until completion: a migration claim fails
    /// while an item fetch is suspended and succeeds after the run ends.
    @Test func runHoldsItsLeaseUntilCompletion() async throws {
        let work = try makeTempDir()
        let dest = work.appendingPathComponent("out")
        let id = UUID()
        let detail = makeDetail(id: id, transcript: makeTranscript())
        let latch = BatchExporterTestLatch()
        let exporter = BatchFileExporter()
        let gate = StorageMigrationGate()
        exporter.migrationGate = gate
        exporter.dependencies = BatchFileExporter.Dependencies(
            fetchDetail: { _ in
                await latch.wait()
                return detail
            },
            fetchAudioPaths: { _ in [:] },
            fetchFolders: { [] },
            diskSpace: StubDiskSpace(capacity: .max / 2),
            now: { Date(timeIntervalSince1970: 0) }
        )

        let run = Task {
            await exporter.prepareAndRun(
                recordingIDs: [id], options: BatchExportOptions(), destination: dest
            )
        }
        for _ in 0..<200 {
            if latch.didStart { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(latch.didStart)
        #expect(!gate.claimMigration())

        latch.release()
        await run.value
        #expect(gate.claimMigration())
        gate.releaseMigration()
    }

    @Test func happyPathExportsAllRequestedFiles() async throws {
        let work = try makeTempDir()
        let dest = work.appendingPathComponent("out")
        let audioPath = try makeAudioFile(in: work)
        let id1 = UUID(), id2 = UUID()
        let workFolder = makeFolder(name: "Work")
        let exporter = makeExporter(
            details: [
                id1: makeDetail(id: id1, title: "会议一", audioFilePath: audioPath,
                                folderID: workFolder.id,
                                transcript: makeTranscript(), summary: makeSummary()),
                id2: makeDetail(id: id2, title: "会议二", audioFilePath: audioPath,
                                transcript: makeTranscript(), summary: makeSummary()),
            ],
            folders: [workFolder]
        )
        await runToCompletion(
            exporter, ids: [id1, id2],
            options: BatchExportOptions(transcriptTxt: true, transcriptSRT: true,
                                        transcriptMarkdown: true, summaryMarkdown: true, audio: true),
            destination: dest
        )

        #expect(exporter.phase == .finished(succeeded: 2, failures: []))
        let dir1 = dest.appendingPathComponent("2026-08-02 - 会议一")
        for file in ["audio.m4a", "transcript.txt", "transcript.srt", "transcript.md",
                     "summary.md", "metadata.json"] {
            #expect(FileManager.default.fileExists(atPath: dir1.appendingPathComponent(file).path),
                    "missing \(file)")
        }
        // 音频是原件复制
        let exported = try Data(contentsOf: dir1.appendingPathComponent("audio.m4a"))
        #expect(exported == Data(repeating: 0xAB, count: 128))
        // metadata 可解码且带 folderPath
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let metadata = try decoder.decode(
            ExportMetadata.self,
            from: Data(contentsOf: dir1.appendingPathComponent("metadata.json"))
        )
        #expect(metadata.folderPath == ["Work"])
        #expect(metadata.exportedAt == fixedDate)
    }

    @Test func missingAudioFileIsFailureButBatchContinues() async throws {
        let work = try makeTempDir()
        let dest = work.appendingPathComponent("out")
        let goodAudio = try makeAudioFile(in: work)
        let id1 = UUID(), id2 = UUID()
        let exporter = makeExporter(details: [
            id1: makeDetail(id: id1, title: "坏录音",
                            audioFilePath: work.appendingPathComponent("gone.m4a").path,
                            transcript: makeTranscript()),
            id2: makeDetail(id: id2, title: "好录音", audioFilePath: goodAudio,
                            transcript: makeTranscript()),
        ])
        await runToCompletion(exporter, ids: [id1, id2],
                              options: BatchExportOptions(), destination: dest)

        guard case .finished(let succeeded, let failures) = exporter.phase else {
            Issue.record("unexpected phase \(exporter.phase)")
            return
        }
        #expect(succeeded == 1)
        #expect(failures.count == 1)
        #expect(failures.first?.id == id1)
        let reason = try #require(failures.first?.reason)
        #expect(
            reason == LocalizedBundle.string(
                "The audio file for this recording could not be found.",
                locale: nil
            )
        )
        #expect(!reason.contains(work.path))
        #expect(!reason.contains("gone.m4a"))
        // 失败条目的其它文件仍导出（部分成功保留）
        let badDir = dest.appendingPathComponent("2026-08-02 - 坏录音")
        #expect(FileManager.default.fileExists(atPath: badDir.appendingPathComponent("transcript.txt").path))
        #expect(!FileManager.default.fileExists(atPath: badDir.appendingPathComponent("audio.m4a").path))
    }

    @Test func duplicateTitlesGetSuffixedDirectories() async throws {
        let work = try makeTempDir()
        let dest = work.appendingPathComponent("out")
        let id1 = UUID(), id2 = UUID()
        let exporter = makeExporter(details: [
            id1: makeDetail(id: id1, title: "同名", transcript: makeTranscript()),
            id2: makeDetail(id: id2, title: "同名", transcript: makeTranscript()),
        ])
        await runToCompletion(
            exporter, ids: [id1, id2],
            options: BatchExportOptions(transcriptTxt: true, transcriptSRT: false,
                                        transcriptMarkdown: false, summaryMarkdown: false, audio: false),
            destination: dest
        )
        #expect(exporter.phase == .finished(succeeded: 2, failures: []))
        #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("2026-08-02 - 同名").path))
        #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("2026-08-02 - 同名 -2").path))
    }

    @Test func cancelMidRunKeepsCompletedItems() async throws {
        let work = try makeTempDir()
        let dest = work.appendingPathComponent("out")
        let ids = [UUID(), UUID(), UUID()]
        let details = Dictionary(uniqueKeysWithValues: ids.enumerated().map { index, id in
            (id, makeDetail(id: id, title: "录音\(index)", transcript: makeTranscript()))
        })
        let exporter = BatchFileExporter()
        let configuredExporter = makeExporter(existingExporter: exporter, details: details) { id in
            // 第二条 fetch 时请求取消：该条仍会完成，第三条不再开始
            if id == ids[1] { exporter.cancel() }
        }
        await runToCompletion(configuredExporter, ids: ids,
                              options: BatchExportOptions(), destination: dest)

        guard case .cancelled(let exported, let failures) = configuredExporter.phase else {
            Issue.record("unexpected phase \(configuredExporter.phase)")
            return
        }
        #expect(exported == 2)
        #expect(failures.isEmpty)
        #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("2026-08-02 - 录音0").path))
        #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("2026-08-02 - 录音1").path))
        #expect(!FileManager.default.fileExists(atPath: dest.appendingPathComponent("2026-08-02 - 录音2").path))
    }

    @Test func preflightRejectsWhenDiskFull() async throws {
        let work = try makeTempDir()
        let id = UUID()
        let exporter = makeExporter(
            details: [id: makeDetail(id: id, transcript: makeTranscript())],
            capacity: 1024 // 远小于 margin
        )
        await exporter.prepare(recordingIDs: [id], options: BatchExportOptions(),
                               destination: work.appendingPathComponent("out"))
        // 断言 case 而非本地化文案——测试宿主语言不定（key 有 en 单元）
        guard case .failed = exporter.phase else {
            Issue.record("unexpected phase \(exporter.phase)")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: work.appendingPathComponent("out").path))
    }

    @Test func rawPreflightAndDestinationErrorsUseStableUserFacingSummary() async throws {
        let rawCanary = #"RAW-EXPORT-{\"token\":\"secret-value\",\"path\":\"/private/source.m4a\"}"#
        let work = try makeTempDir()
        let id = UUID()
        let detail = makeDetail(id: id, transcript: makeTranscript())

        let preflightExporter = BatchFileExporter()
        preflightExporter.dependencies = BatchFileExporter.Dependencies(
            fetchDetail: { _ in detail },
            fetchAudioPaths: { _ in [:] },
            fetchFolders: { [] },
            diskSpace: ThrowingDiskSpace(message: rawCanary),
            now: { Date(timeIntervalSince1970: 0) }
        )
        await preflightExporter.prepare(
            recordingIDs: [id],
            options: BatchExportOptions(),
            destination: work.appendingPathComponent("preflight")
        )

        let expected = ExportError.unexpected("").localizedMessage()
        guard case .failed(let preflightMessage) = preflightExporter.phase else {
            Issue.record("unexpected preflight phase \(preflightExporter.phase)")
            return
        }
        #expect(preflightMessage == expected)
        #expect(!preflightMessage.contains(rawCanary))
        #expect(!preflightMessage.contains("secret-value"))

        let blockedDestination = work.appendingPathComponent("destination-is-a-file")
        try Data("blocked".utf8).write(to: blockedDestination)
        let destinationExporter = makeExporter(details: [id: detail])
        await runToCompletion(
            destinationExporter,
            ids: [id],
            options: BatchExportOptions(),
            destination: blockedDestination
        )
        guard case .failed(let destinationMessage) = destinationExporter.phase else {
            Issue.record("unexpected destination phase \(destinationExporter.phase)")
            return
        }
        #expect(destinationMessage == expected)
        #expect(!destinationMessage.contains(blockedDestination.path))
    }

    @Test func optionsSubsetWritesOnlyRequestedFiles() async throws {
        let work = try makeTempDir()
        let dest = work.appendingPathComponent("out")
        let audioPath = try makeAudioFile(in: work)
        let id = UUID()
        let exporter = makeExporter(details: [
            id: makeDetail(id: id, audioFilePath: audioPath,
                           transcript: makeTranscript(), summary: makeSummary())
        ])
        await runToCompletion(
            exporter, ids: [id],
            options: BatchExportOptions(transcriptTxt: false, transcriptSRT: false,
                                        transcriptMarkdown: false, summaryMarkdown: true, audio: false),
            destination: dest
        )
        #expect(exporter.phase == .finished(succeeded: 1, failures: []))
        let dir = dest.appendingPathComponent("2026-08-02 - 产品周会")
        let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(contents == ["metadata.json", "summary.md"])
    }

    @Test func absentContentIsNotAFailure() async throws {
        let work = try makeTempDir()
        let dest = work.appendingPathComponent("out")
        let id = UUID()
        // 无转录、无摘要、audioFilePath 为 nil —— 合法的空录音，不是错误
        let exporter = makeExporter(details: [id: makeDetail(id: id, title: "空录音")])
        await runToCompletion(exporter, ids: [id],
                              options: BatchExportOptions(), destination: dest)
        #expect(exporter.phase == .finished(succeeded: 1, failures: []))
        let dir = dest.appendingPathComponent("2026-08-02 - 空录音")
        let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(contents == ["metadata.json"])
    }

    @Test func folderPathBuilderWalksParentsAndSurvivesCycles() {
        let root = UUID(), child = UUID(), grandchild = UUID()
        func folder(_ id: UUID, _ name: String, parent: UUID?) -> FolderDTO {
            FolderDTO(id: id, name: name, icon: "folder", iconColor: "blue", colorHex: nil,
                      status: "active", createdAt: fixedDate, sortOrder: 0,
                      recordingCount: 0, parentFolderID: parent, subfolderCount: 0)
        }
        let folders = [
            folder(root, "Work", parent: nil),
            folder(child, "Meetings", parent: root),
            folder(grandchild, "Weekly", parent: child),
        ]
        #expect(FolderPathBuilder.path(to: grandchild, in: folders) == ["Work", "Meetings", "Weekly"])
        #expect(FolderPathBuilder.path(to: nil, in: folders) == [])
        #expect(FolderPathBuilder.path(to: UUID(), in: folders) == [])

        // 环：A→B→A 不死循环
        let a = UUID(), b = UUID()
        let cyclic = [folder(a, "A", parent: b), folder(b, "B", parent: a)]
        #expect(FolderPathBuilder.path(to: a, in: cyclic) == ["B", "A"])
    }

    @Test func prepareAndRunNeverConfirmsSomeoneElsesPendingRun() async throws {
        let work = try makeTempDir()
        let destA = work.appendingPathComponent("outA")
        let destB = work.appendingPathComponent("outB")
        let idA = UUID(), idB = UUID()
        let exporter = makeExporter(details: [
            idA: makeDetail(id: idA, title: "任务A", transcript: makeTranscript()),
            idB: makeDetail(id: idB, title: "任务B", transcript: makeTranscript()),
        ])
        // 任务 A 走到 .confirming（等用户确认）
        await exporter.prepare(recordingIDs: [idA], options: BatchExportOptions(), destination: destA)
        guard case .confirming(let pending, _) = exporter.phase, pending == 1 else {
            Issue.record("unexpected phase \(exporter.phase)")
            return
        }
        // 任务 B 走免确认入口：exporter busy → prepare 未认领 → 绝不能替 A 开跑
        await exporter.prepareAndRun(recordingIDs: [idB], options: BatchExportOptions(), destination: destB)
        guard case .confirming = exporter.phase else {
            Issue.record("prepareAndRun confirmed someone else's run: \(exporter.phase)")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: destA.path))
        #expect(!FileManager.default.fileExists(atPath: destB.path))
    }

    @Test func deletedRecordingIsFailureAndBatchContinues() async throws {
        let work = try makeTempDir()
        let dest = work.appendingPathComponent("out")
        let missing = UUID()
        let present = UUID()
        let exporter = makeExporter(details: [
            present: makeDetail(id: present, title: "还在", transcript: makeTranscript())
        ])
        await runToCompletion(exporter, ids: [missing, present],
                              options: BatchExportOptions(), destination: dest)
        guard case .finished(let succeeded, let failures) = exporter.phase else {
            Issue.record("unexpected phase \(exporter.phase)")
            return
        }
        #expect(succeeded == 1)
        #expect(failures.map(\.id) == [missing])
    }
}


/// Single-shot suspension latch for the exporter's fetch closure.
@MainActor
private final class BatchExporterTestLatch {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var didStart = false

    func wait() async {
        didStart = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
