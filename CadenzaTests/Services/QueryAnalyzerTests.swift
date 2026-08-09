import Testing
@testable import Cadenza

struct QueryAnalyzerTests {
    let knownSpeakers: [SpeakerNameInfo] = [
        SpeakerNameInfo(displayName: "Andy", aliases: ["Andrew", "安迪"]),
        SpeakerNameInfo(displayName: "Sarah", aliases: []),
    ]

    @Test func englishLastWeek() {
        let intent = QueryAnalyzer.analyze("What happened last week?", knownSpeakers: knownSpeakers)
        #expect(intent.timeRange == .lastWeek)
    }

    @Test func chineseYesterday() {
        let intent = QueryAnalyzer.analyze("昨天的会讨论了什么", knownSpeakers: knownSpeakers)
        #expect(intent.timeRange == .yesterday)
    }

    @Test func chineseThisWeek() {
        let intent = QueryAnalyzer.analyze("这周有什么进展", knownSpeakers: knownSpeakers)
        #expect(intent.timeRange == .thisWeek)
    }

    @Test func englishAllTime() {
        let intent = QueryAnalyzer.analyze("Have we ever discussed the vault migration?", knownSpeakers: knownSpeakers)
        #expect(intent.timeRange == .allTime)
    }

    @Test func englishAllMyRecordings() {
        let intent = QueryAnalyzer.analyze("Search all my recordings for IDOR findings", knownSpeakers: knownSpeakers)
        #expect(intent.timeRange == .allTime)
    }

    @Test func chineseAllRecordings() {
        let intent = QueryAnalyzer.analyze("在所有录音里找一下关于密钥迁移的讨论", knownSpeakers: knownSpeakers)
        #expect(intent.timeRange == .allTime)
    }

    @Test func everyDoesNotTriggerAllTime() {
        // \bever\b must not match inside "every".
        let intent = QueryAnalyzer.analyze("What does every team member own?", knownSpeakers: knownSpeakers)
        #expect(intent.timeRange == nil)
    }

    @Test func explicitRecentRangeWinsOverAllPhrase() {
        // Concrete time words are listed before the all-time patterns.
        let intent = QueryAnalyzer.analyze("Summarize all my meetings last week", knownSpeakers: knownSpeakers)
        #expect(intent.timeRange == .lastWeek)
    }

    @Test func noTimeSignal() {
        let intent = QueryAnalyzer.analyze("Tell me about the project", knownSpeakers: knownSpeakers)
        #expect(intent.timeRange == nil)
    }

    @Test func matchDisplayName() {
        let intent = QueryAnalyzer.analyze("What did Andy say?", knownSpeakers: knownSpeakers)
        #expect(intent.speakerQueries.contains("Andy"))
    }

    @Test func matchAlias() {
        let intent = QueryAnalyzer.analyze("Andrew mentioned something", knownSpeakers: knownSpeakers)
        #expect(intent.speakerQueries.contains("Andy"))
    }

    @Test func matchChineseAlias() {
        let intent = QueryAnalyzer.analyze("安迪说了什么", knownSpeakers: knownSpeakers)
        #expect(intent.speakerQueries.contains("Andy"))
    }

    @Test func matchRawSpeakerLabel() {
        let intent = QueryAnalyzer.analyze("Speaker 2 said something about deployment", knownSpeakers: knownSpeakers)
        #expect(intent.speakerQueries.contains("Speaker 2"))
    }

    @Test func noSpeakerMatch() {
        let intent = QueryAnalyzer.analyze("What about the budget?", knownSpeakers: knownSpeakers)
        #expect(intent.speakerQueries.isEmpty)
    }

    @Test func extractsKeywords() {
        let intent = QueryAnalyzer.analyze("关于部署延迟的问题", knownSpeakers: knownSpeakers)
        #expect(intent.keywords.contains("部署"))
        #expect(intent.keywords.contains("延迟"))
    }

    @Test func mixedQuery() {
        let intent = QueryAnalyzer.analyze("Andy 上周说了什么关于部署的", knownSpeakers: knownSpeakers)
        #expect(intent.timeRange == .lastWeek)
        #expect(intent.speakerQueries.contains("Andy"))
        #expect(intent.keywords.contains("部署"))
    }

    @Test func mentionsPassedThrough() {
        let id = UUID()
        let intent = QueryAnalyzer.analyze("Tell me about this", knownSpeakers: knownSpeakers, mentionedRecordingIDs: [id])
        #expect(intent.mentionedRecordingIDs == [id])
    }

    @Test func resolvesLatestChineseOneOnOneAtRecordingLevel() {
        let speakers = knownSpeakers + [SpeakerNameInfo(displayName: "Caleb", aliases: [])]
        let intent = QueryAnalyzer.analyze(
            "上次跟 Caleb 的1on1，他叫我周四展示 workflow",
            knownSpeakers: speakers
        )

        #expect(intent.speakerQueries == ["Caleb"])
        #expect(intent.meetingType == .oneOnOne)
        #expect(intent.prefersMostRecentRecording)
        #expect(intent.keywords.contains("workflow"))
        #expect(!intent.keywords.contains("wo"))
    }

    @Test func lastWeekDoesNotMeanSingleLatestRecording() {
        let intent = QueryAnalyzer.analyze("What happened last week?", knownSpeakers: knownSpeakers)
        #expect(!intent.prefersMostRecentRecording)
    }

    @Test func englishLastOneOnOneVariantsResolveLatestRecording() {
        let speakers = knownSpeakers + [SpeakerNameInfo(displayName: "Caleb", aliases: [])]

        let compact = QueryAnalyzer.analyze("last 1on1 with Caleb", knownSpeakers: speakers)
        #expect(compact.prefersMostRecentRecording)
        #expect(compact.meetingType == .oneOnOne)
        #expect(compact.speakerQueries == ["Caleb"])

        let hyphenated = QueryAnalyzer.analyze("previous 1-on-1 with Caleb", knownSpeakers: speakers)
        #expect(hyphenated.prefersMostRecentRecording)
        #expect(hyphenated.meetingType == .oneOnOne)
    }

    @Test func detectsContextualFollowUps() {
        #expect(QueryAnalyzer.isContextualFollowUp("那关于 performance review 呢"))
        #expect(QueryAnalyzer.isContextualFollowUp("详细点？"))
        #expect(QueryAnalyzer.isContextualFollowUp("现在呢？"))
        #expect(QueryAnalyzer.isContextualFollowUp("展开说说原文"))
        #expect(QueryAnalyzer.isContextualFollowUp("你不能看到 transcript 吗"))
        #expect(!QueryAnalyzer.isContextualFollowUp("这周有哪些 action items"))
    }
}
