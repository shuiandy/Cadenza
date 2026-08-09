import Foundation
import Testing
@testable import Cadenza

@Suite("ExportContentRenderer")
struct ExportContentRendererTests {

    /// 2026-08-02T00:00:00Z
    private let fixedDate = Date(timeIntervalSince1970: 1_785_628_800)
    private let fixedID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

    // MARK: - Fixtures

    private func makeEntry(
        start: TimeInterval, end: TimeInterval, text: String, speaker: String? = nil
    ) -> TranscriptEntryDTO {
        TranscriptEntryDTO(id: UUID(), startTime: start, endTime: end, text: text, speaker: speaker)
    }

    private func makeTranscript(
        entries: [TranscriptEntryDTO], language: String? = "zh"
    ) -> TranscriptDTO {
        TranscriptDTO(
            id: UUID(),
            fullText: entries.map(\.text).joined(separator: " "),
            segments: entries,
            detectedLanguage: language,
            createdAt: fixedDate
        )
    }

    private func makeSummary(
        overview: String = "整体进展顺利。",
        keyPoints: [String] = [],
        actionItems: [ActionItemDTO] = [],
        decisions: [String] = [],
        followUps: [String] = [],
        yourTasks: [String] = [],
        chapters: [ChapterDTO] = []
    ) -> SummaryDTO {
        SummaryDTO(
            id: UUID(),
            overview: overview,
            keyPoints: keyPoints,
            actionItems: actionItems,
            decisions: decisions,
            followUps: followUps,
            yourTasks: yourTasks,
            provider: "gemini",
            model: "test-model",
            language: "zh",
            createdAt: fixedDate,
            chapters: chapters
        )
    }

    private func makeDetail(
        title: String = "产品周会",
        tags: [String] = [],
        transcript: TranscriptDTO? = nil,
        summary: SummaryDTO? = nil,
        mappings: [SpeakerLabelMappingDTO] = []
    ) -> RecordingDetailDTO {
        RecordingDetailDTO(
            id: fixedID,
            title: title,
            startDate: fixedDate,
            endDate: fixedDate.addingTimeInterval(1800),
            duration: 1800,
            meetingApp: "Teams",
            meetingURL: nil,
            language: "zh",
            tags: tags,
            meetingType: nil,
            lastAccessedDate: nil,
            folderID: nil,
            audioFile: nil,
            linkedCalendarEventID: nil,
            transcript: transcript,
            summary: summary,
            speakerMappings: mappings,
            speakerSuggestions: []
        )
    }

    private func mapping(_ raw: String, to name: String) -> SpeakerLabelMappingDTO {
        SpeakerLabelMappingDTO(rawLabel: raw, profileID: UUID(), profileName: name)
    }

    // MARK: - transcriptText

    @Test func transcriptTextResolvesSpeakersAndTimestamps() {
        let transcript = makeTranscript(entries: [
            makeEntry(start: 0, end: 5, text: "大家好", speaker: "SPEAKER_00"),
            makeEntry(start: 75.4, end: 80, text: "开始吧", speaker: "SPEAKER_01"),
            makeEntry(start: 3675, end: 3680, text: "散会"),
        ])
        let text = ExportContentRenderer.transcriptText(
            transcript, mappings: [mapping("SPEAKER_00", to: "Andy")]
        )
        let fallback = SpeakerLabelFormatter.displayName(forRawLabel: "SPEAKER_01")
        let lines = text.components(separatedBy: "\n")
        #expect(lines == [
            "[0:00] Andy: 大家好",
            "[1:15] \(fallback): 开始吧",
            "[61:15] 散会",
        ])
    }

    @Test func transcriptTextTreatsBlankSpeakerAsNone() {
        let transcript = makeTranscript(entries: [
            makeEntry(start: 0, end: 1, text: "无人声", speaker: "   ")
        ])
        let text = ExportContentRenderer.transcriptText(transcript, mappings: [])
        #expect(text == "[0:00] 无人声")
    }

    // MARK: - SRT

    @Test func srtFormatsCuesWithSpeakerPrefix() {
        let transcript = makeTranscript(entries: [
            makeEntry(start: 75.4, end: 80.9, text: "开始吧", speaker: "SPEAKER_00"),
            makeEntry(start: 81, end: 82, text: "好的"),
        ])
        let srt = ExportContentRenderer.transcriptSRT(
            transcript, mappings: [mapping("SPEAKER_00", to: "Andy")]
        )
        let blocks = srt.components(separatedBy: "\n\n")
        #expect(blocks.count == 2)
        #expect(blocks[0] == "1\n00:01:15,400 --> 00:01:20,900\nAndy: 开始吧")
        #expect(blocks[1].hasPrefix("2\n00:01:21,000 --> 00:01:22,000\n好的"))
    }

    @Test func srtTimestampEdges() {
        #expect(ExportContentRenderer.srtTimestamp(0) == "00:00:00,000")
        #expect(ExportContentRenderer.srtTimestamp(-3) == "00:00:00,000")
        #expect(ExportContentRenderer.srtTimestamp(3661.007) == "01:01:01,007")
    }

    // MARK: - transcriptMarkdown

    @Test func transcriptMarkdownGroupsConsecutiveSpeakerTurns() {
        let transcript = makeTranscript(entries: [
            makeEntry(start: 0, end: 5, text: "你好", speaker: "SPEAKER_00"),
            makeEntry(start: 5, end: 10, text: "第二句", speaker: "SPEAKER_00"),
            makeEntry(start: 10, end: 15, text: "回应", speaker: "SPEAKER_01"),
        ])
        let detail = makeDetail(
            tags: ["周会"],
            transcript: transcript,
            mappings: [mapping("SPEAKER_00", to: "Andy")]
        )
        let md = ExportContentRenderer.transcriptMarkdown(transcript, detail: detail)

        #expect(md.hasPrefix("# 产品周会\n"))
        #expect(md.contains("- Tags: 周会"))
        #expect(md.contains("- Language: zh"))
        // 连续同 speaker 只出一个 turn 头——按不带时间戳的 "**Andy**" 计数：
        // 若分组坏掉，第二条会以 "**Andy** · 0:05" 出现，带时间戳计数发现不了
        #expect(md.components(separatedBy: "**Andy**").count == 2)
        #expect(md.contains("你好"))
        #expect(md.contains("第二句"))
        let fallback = SpeakerLabelFormatter.displayName(forRawLabel: "SPEAKER_01")
        #expect(md.contains("**\(fallback)** · 0:10"))
        #expect(md.hasSuffix("\n"))
    }

    // MARK: - summaryMarkdown

    @Test func summaryMarkdownRendersAllSectionsInOrder() {
        let summary = makeSummary(
            keyPoints: ["要点一"],
            actionItems: [
                ActionItemDTO(
                    id: UUID(), assignee: "Bob", task: "写文档", deadline: "周五",
                    isCompleted: false, priority: "high"
                ),
                ActionItemDTO(
                    id: UUID(), assignee: nil, task: "已完成项", deadline: nil,
                    isCompleted: true, priority: "low"
                ),
            ],
            decisions: ["采用方案 A"],
            followUps: ["下周复盘"],
            yourTasks: ["review PR"],
            chapters: [ChapterDTO(title: "开场", startSeconds: 0, summary: "寒暄")]
        )
        let detail = makeDetail(tags: ["周会"], summary: summary)
        let md = ExportContentRenderer.summaryMarkdown(summary, detail: detail)

        let sections = ["## Overview", "## Chapters", "## Key Points", "## Decisions",
                        "## Action Items", "## Follow-ups", "## Your Tasks"]
        let indices = sections.map { md.range(of: $0)?.lowerBound }
        #expect(indices.allSatisfy { $0 != nil })
        #expect(indices.compactMap { $0 } == indices.compactMap { $0 }.sorted())

        #expect(md.contains("- [0:00] 开场 — 寒暄"))
        #expect(md.contains("- [ ] 写文档 (@Bob) — Due: 周五"))
        #expect(md.contains("- [x] 已完成项"))
    }

    @Test func summaryMarkdownOmitsEmptySections() {
        let summary = makeSummary()
        let detail = makeDetail(summary: summary)
        let md = ExportContentRenderer.summaryMarkdown(summary, detail: detail)
        #expect(md.contains("## Overview"))
        #expect(!md.contains("## Chapters"))
        #expect(!md.contains("## Key Points"))
        #expect(!md.contains("## Action Items"))
    }

    // MARK: - metadataJSON

    @Test func metadataJSONRoundTripAndDeterminism() throws {
        let transcript = makeTranscript(entries: [
            makeEntry(start: 0, end: 5, text: "a", speaker: "SPEAKER_00"),
            makeEntry(start: 5, end: 9, text: "b", speaker: "SPEAKER_01"),
            makeEntry(start: 9, end: 12, text: "c", speaker: "SPEAKER_00"),
        ])
        let detail = makeDetail(
            tags: ["周会", "cadenza"],
            transcript: transcript,
            mappings: [mapping("SPEAKER_00", to: "Andy")]
        )
        let data1 = try ExportContentRenderer.metadataJSON(
            detail, folderPath: ["Work", "Meetings"], exportedAt: fixedDate
        )
        let data2 = try ExportContentRenderer.metadataJSON(
            detail, folderPath: ["Work", "Meetings"], exportedAt: fixedDate
        )
        #expect(data1 == data2)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ExportMetadata.self, from: data1)
        #expect(decoded.id == fixedID)
        #expect(decoded.title == "产品周会")
        #expect(decoded.folderPath == ["Work", "Meetings"])
        #expect(decoded.tags == ["周会", "cadenza"])
        #expect(decoded.hasTranscript)
        #expect(!decoded.hasSummary)
        let fallback = SpeakerLabelFormatter.displayName(forRawLabel: "SPEAKER_01")
        #expect(decoded.speakers == ["Andy", fallback])
    }

    // MARK: - Naming

    @Test func exportDirectoryNameSanitizesAndBounds() {
        #expect(
            ExportContentRenderer.exportDirectoryName(for: makeDetail(title: "A/B: C*?"))
                == "2026-08-02 - A-B- C--"
        )
        #expect(
            ExportContentRenderer.exportDirectoryName(for: makeDetail(title: "产品周会"))
                == "2026-08-02 - 产品周会"
        )
        #expect(
            ExportContentRenderer.exportDirectoryName(for: makeDetail(title: "  "))
                == "2026-08-02 - Recording"
        )
        // CJK 长标题受 UTF-8 字节上限约束（180B = 60 个三字节字符），
        // 否则加上日期前缀/后缀会超 APFS 255 字节文件名上限
        let long = String(repeating: "长", count: 100)
        let name = ExportContentRenderer.exportDirectoryName(for: makeDetail(title: long))
        #expect(name == "2026-08-02 - \(String(repeating: "长", count: 60))")
        #expect(ExportFileNaming.sanitizedTitle(long).utf8.count <= 180)
    }

    @Test func mirrorFilenameBehaviorUnchangedAfterRefactor() {
        let detail = makeDetail(title: "A/B")
        #expect(
            MarkdownMirrorService.filename(for: detail)
                == "2026-08-02 - A-B - \(fixedID.uuidString).md"
        )
    }
}
