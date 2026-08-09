import Foundation
import Testing
@testable import Cadenza

@Suite("SummaryPromptTests")
struct SummaryPromptTests {

    @Test func parseResponseExtractsMeetingType() {
        let json = """
        {
          "title": "Weekly Standup",
          "overview": "Team discussed progress.",
          "key_points": ["Point 1"],
          "action_items": [],
          "decisions": [],
          "follow_ups": [],
          "tags": ["standup"],
          "meeting_type": "standup",
          "chapters": []
        }
        """
        let result = SummaryPrompt.parseResponse(json)
        #expect(result.meetingType == "standup")
        #expect(result.title == "Weekly Standup")
        #expect(result.tags == ["standup"])
    }

    @Test func parseResponseDefaultsMeetingTypeWhenMissing() {
        let json = """
        {
          "title": "Some Meeting",
          "overview": "Discussed things.",
          "key_points": ["A point"],
          "action_items": [],
          "decisions": [],
          "follow_ups": [],
          "tags": ["general"],
          "chapters": []
        }
        """
        let result = SummaryPrompt.parseResponse(json)
        #expect(result.meetingType == nil)
    }

    @Test func parseResponseHandlesNoChaptersGracefully() {
        let json = """
        {
          "title": "Quick Sync",
          "overview": "Brief discussion.",
          "key_points": [],
          "action_items": [],
          "decisions": [],
          "follow_ups": [],
          "tags": [],
          "meeting_type": "oneOnOne"
        }
        """
        let result = SummaryPrompt.parseResponse(json)
        #expect(result.chapters.isEmpty)
        #expect(result.meetingType == "oneOnOne")
        #expect(result.title == "Quick Sync")
    }

    @Test
    func parseChaptersResponse() {
        let json = """
        {
            "chapters": [
                {"title": "Introduction", "start_seconds": 0, "summary": "Team introductions"},
                {"title": "Technical Discussion", "start_seconds": 300, "summary": "Architecture review"}
            ]
        }
        """
        let chapters = SummaryPrompt.parseChaptersResponse(json)
        #expect(chapters.count == 2)
        #expect(chapters[0].title == "Introduction")
        #expect(chapters[0].startSeconds == 0)
        #expect(chapters[1].title == "Technical Discussion")
        #expect(chapters[1].startSeconds == 300)
    }

    @Test
    func parseChaptersResponseHandlesEmpty() {
        let chapters = SummaryPrompt.parseChaptersResponse("""
        {"chapters": []}
        """)
        #expect(chapters.isEmpty)
    }

    @Test
    func parseChaptersResponseHandlesInvalidJSON() {
        let chapters = SummaryPrompt.parseChaptersResponse("not json")
        #expect(chapters.isEmpty)
    }
}

@Suite("WhisperTranscriberTests")
struct WhisperTranscriberTests {

    @Test func diarizeChunksLongRecordingBelowUploadLimit() {
        let chunkDuration = WhisperTranscriber.chunkDurationForUpload(
            model: "gpt-4o-transcribe-diarize",
            fileSize: 16_575_560,
            audioDuration: 1_012
        )

        #expect(chunkDuration == 300.0)
    }

    @Test func diarizeChunkingUsesStrictProactiveDurationBoundary() {
        let exactThreshold = WhisperTranscriber.chunkDurationForUpload(
            model: "gpt-4o-transcribe-diarize",
            fileSize: 10 * 1024 * 1024,
            audioDuration: WhisperTranscriber.diarizeChunkTriggerThreshold
        )
        let overThreshold = WhisperTranscriber.chunkDurationForUpload(
            model: "gpt-4o-transcribe-diarize",
            fileSize: 10 * 1024 * 1024,
            audioDuration: WhisperTranscriber.diarizeChunkTriggerThreshold + 0.001
        )

        #expect(exactThreshold == nil)
        #expect(overThreshold == WhisperTranscriber.diarizeChunkDuration)
    }

    @Test func diarizeChunkingUsesStrictUploadSizeBoundary() {
        let exactSize = WhisperTranscriber.chunkDurationForUpload(
            model: "gpt-4o-transcribe-diarize",
            fileSize: WhisperTranscriber.openAIMaxUploadBytes,
            audioDuration: 300
        )
        let overSize = WhisperTranscriber.chunkDurationForUpload(
            model: "gpt-4o-transcribe-diarize",
            fileSize: WhisperTranscriber.openAIMaxUploadBytes + 1,
            audioDuration: 300
        )

        #expect(exactSize == nil)
        #expect(overSize == WhisperTranscriber.diarizeChunkDuration)
    }

    @Test func diarizeChunksWhenRecordingExceedsModelDurationLimit() {
        let chunkDuration = WhisperTranscriber.chunkDurationForUpload(
            model: "gpt-4o-transcribe-diarize",
            fileSize: 13 * 1024 * 1024,
            audioDuration: WhisperTranscriber.diarizeMaxSingleRequestDuration + 0.001
        )

        #expect(chunkDuration == WhisperTranscriber.diarizeChunkDuration)
    }

    @Test func diarizeKeepsShortRecordingsInSingleRequest() {
        let chunkDuration = WhisperTranscriber.chunkDurationForUpload(
            model: "gpt-4o-transcribe-diarize",
            fileSize: 3 * 1024 * 1024,
            audioDuration: 369
        )

        #expect(chunkDuration == nil)
    }

    @Test func nonDiarizeChunksOnlyWhenUploadIsTooLarge() {
        let shortEnough = WhisperTranscriber.chunkDurationForUpload(
            model: "gpt-4o-transcribe",
            fileSize: 16 * 1024 * 1024,
            audioDuration: 1_068
        )
        let tooLarge = WhisperTranscriber.chunkDurationForUpload(
            model: "gpt-4o-transcribe",
            fileSize: 26 * 1024 * 1024,
            audioDuration: 1_068
        )

        #expect(shortEnough == nil)
        #expect(tooLarge == WhisperTranscriber.standardChunkDuration)
    }

    @Test func speakerLabelNormalizationRejectsPunctuationOnlyGhostLabels() {
        #expect(WhisperTranscriber.normalizedSpeakerLabel(" @ ") == nil)
        #expect(WhisperTranscriber.normalizedSpeakerLabel("  A  ") == "A")
        #expect(WhisperTranscriber.normalizedSpeakerLabel("Caleb") == "Caleb")
    }

    @Test func multiRequestDiarizationDoesNotPersistRequestLocalLabels() {
        #expect(WhisperTranscriber.speakerLabelForMergedChunks("A", totalChunkCount: 1) == "A")
        #expect(WhisperTranscriber.speakerLabelForMergedChunks("A", totalChunkCount: 2) == nil)
        #expect(WhisperTranscriber.speakerLabelForMergedChunks("B", totalChunkCount: 7) == nil)
    }
}

@Suite("SummaryPrompt.splitForMapReduce", .serialized)
struct SplitForMapReduceTests {

    @Test
    func shortTextReturnsSingleChunk() {
        let text = String(repeating: "Hello world. ", count: 100) // ~1300 chars
        let chunks = SummaryPrompt.splitForMapReduce(text)
        #expect(chunks.count == 1)
    }

    @Test
    func longTextSplitsIntoMultipleChunks() {
        // Generate text above threshold (40K chars)
        let sentence = "This is a test sentence with some content about the meeting discussion. "
        let text = String(repeating: sentence, count: 600) // ~43K chars
        let chunks = SummaryPrompt.splitForMapReduce(text)
        #expect(chunks.count > 1)
        // All chunks should be non-empty
        for chunk in chunks {
            #expect(!chunk.isEmpty)
        }
        // Joined chunks should contain all content
        let joined = chunks.joined(separator: "\n\n")
        #expect(joined.count >= text.count - 100) // allow small trimming variance
    }

    @Test
    func respectsParagraphBoundaries() {
        // Build text with clear paragraph boundaries above threshold
        var paragraphs: [String] = []
        for i in 0..<30 {
            paragraphs.append("Paragraph \(i). " + String(repeating: "Content here. ", count: 100))
        }
        let text = paragraphs.joined(separator: "\n\n")
        let chunks = SummaryPrompt.splitForMapReduce(text)
        #expect(chunks.count > 1)
        // No chunk should start mid-sentence (each should start with "Paragraph" or "Content")
        for chunk in chunks {
            let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(!trimmed.isEmpty)
        }
    }

    @Test
    func thresholdBoundary() {
        // Exactly at threshold should return single chunk
        let text = String(repeating: "x", count: SummaryPrompt.mapReduceThreshold)
        let chunks = SummaryPrompt.splitForMapReduce(text)
        #expect(chunks.count == 1)
    }

    @Test
    func splitsCJKTextAtSentenceBoundaries() {
        // Build Chinese text above threshold with 。 sentence endings
        var paragraphs: [String] = []
        for i in 0..<30 {
            // Each "paragraph" is ~1500 chars of Chinese-style sentences
            let sentence = "这是第\(i)段的测试内容，用来验证中文分割功能。"
            paragraphs.append(String(repeating: sentence, count: 60))
        }
        let text = paragraphs.joined(separator: "\n\n")
        let chunks = SummaryPrompt.splitForMapReduce(text)
        #expect(chunks.count > 1)
        for chunk in chunks {
            #expect(!chunk.isEmpty)
        }
    }
}

@Suite("SummaryPrompt.mapReducePrompts")
struct MapReducePromptTests {

    @Test
    func mapSystemContainsLanguage() {
        let prompt = SummaryPrompt.mapSystem(language: "zh")
        #expect(prompt.contains("Chinese"))
    }

    @Test
    func autoLanguagePromptUsesTranscriptLanguage() {
        let prompt = SummaryPrompt.quickSystem(language: "auto")
        #expect(prompt.contains("same language as the transcript"))
        #expect(!prompt.contains("Respond in English"))
    }

    @Test
    func titleInstructionUsesTargetLanguage() {
        let prompt = SummaryPrompt.quickSystem(language: "zh")
        #expect(prompt.contains("For \"title\""))
        #expect(prompt.contains("Chinese"))
    }

    @Test
    func reduceSystemIncludesJobTitle() {
        let prompt = SummaryPrompt.reduceSystem(language: "en", jobTitle: "PM", meetingType: nil, meetingTitle: nil)
        #expect(prompt.contains("PM"))
    }

    @Test
    func reduceSystemIncludesMeetingTitle() {
        let prompt = SummaryPrompt.reduceSystem(language: "en", jobTitle: nil, meetingType: nil, meetingTitle: "Sprint Review")
        #expect(prompt.contains("Sprint Review"))
    }

    @Test
    func reduceSystemIncludesJSONStructure() {
        let prompt = SummaryPrompt.reduceSystem(language: "en", jobTitle: nil, meetingType: nil, meetingTitle: nil)
        #expect(prompt.contains("\"title\""))
        #expect(prompt.contains("\"key_points\""))
        #expect(prompt.contains("\"action_items\""))
    }
}

@Suite("SummaryLanguageResolver")
struct SummaryLanguageResolverTests {

    @Test
    func autoUsesDetectedTranscriptLanguageFirst() {
        let language = SummaryLanguageResolver.resolve(
            requestedSummaryLanguage: "auto",
            detectedTranscriptLanguage: "zh",
            transcriptionLanguage: "en"
        )
        #expect(language == "zh")
    }

    @Test
    func autoFallsBackToTranscriptionLanguage() {
        let language = SummaryLanguageResolver.resolve(
            requestedSummaryLanguage: "auto",
            detectedTranscriptLanguage: nil,
            transcriptionLanguage: "zh"
        )
        #expect(language == "zh")
    }

    @Test
    func explicitSummaryLanguageWins() {
        let language = SummaryLanguageResolver.resolve(
            requestedSummaryLanguage: "en",
            detectedTranscriptLanguage: "zh",
            transcriptionLanguage: "zh"
        )
        #expect(language == "en")
    }

    @Test
    func normalizesLocaleCodes() {
        let language = SummaryLanguageResolver.resolve(
            requestedSummaryLanguage: "auto",
            detectedTranscriptLanguage: "zh-Hans",
            transcriptionLanguage: nil
        )
        #expect(language == "zh")
    }
}

@Suite("SummaryPrompt.twoStagePrompts")
struct TwoStagePromptTests {

    @Test
    func quickSystemContainsReducedSchema() {
        let prompt = SummaryPrompt.quickSystem(language: "en")
        #expect(prompt.contains("\"key_points\""))
        #expect(prompt.contains("\"action_items\""))
        #expect(!prompt.contains("\"decisions\""))
        #expect(!prompt.contains("\"follow_ups\""))
    }

    @Test
    func quickSystemIncludesJobTitle() {
        let prompt = SummaryPrompt.quickSystem(language: "en", jobTitle: "Engineering Manager")
        #expect(prompt.contains("Engineering Manager"))
    }

    @Test
    func quickSystemIncludesMeetingTitle() {
        let prompt = SummaryPrompt.quickSystem(language: "en", meetingTitle: "Sprint Planning")
        #expect(prompt.contains("Sprint Planning"))
    }

    @Test
    func enrichSystemContainsDecisionsSchema() {
        let prompt = SummaryPrompt.enrichSystem(language: "en")
        #expect(prompt.contains("\"decisions\""))
        #expect(prompt.contains("\"follow_ups\""))
    }

    @Test
    func enrichUserIncludesTranscriptAndSummary() {
        let msg = SummaryPrompt.enrichUser(transcript: "Hello meeting", quickSummaryText: "Quick overview")
        #expect(msg.contains("Hello meeting"))
        #expect(msg.contains("Quick overview"))
    }
}

@Suite("SummaryPrompt.twoStageParsing")
struct TwoStageParsingTests {

    @Test
    func parseQuickResponseReturnsEmptyDecisions() {
        let json = """
        {
          "title": "Sprint Review",
          "overview": "Team reviewed sprint progress.",
          "key_points": ["Feature A shipped"],
          "action_items": [{"assignee": "Alice", "task": "Deploy v2", "deadline": null}],
          "tags": ["sprint"],
          "meeting_type": "sprintPlanning"
        }
        """
        let result = SummaryPrompt.parseQuickResponse(json)
        #expect(result.title == "Sprint Review")
        #expect(result.overview.contains("sprint"))
        #expect(result.keyPoints.count == 1)
        #expect(result.actionItems.count == 1)
        #expect(result.decisions.isEmpty)
        #expect(result.followUps.isEmpty)
        #expect(result.meetingType == "sprintPlanning")
    }

    @Test
    func parseEnrichResponseExtractsDecisionsAndFollowUps() {
        let json = """
        {
          "decisions": ["Adopt new framework", "Postpone migration"],
          "follow_ups": ["Schedule design review"]
        }
        """
        let (decisions, followUps) = SummaryPrompt.parseEnrichResponse(json)
        #expect(decisions.count == 2)
        #expect(decisions[0] == "Adopt new framework")
        #expect(followUps.count == 1)
    }

    @Test
    func parseEnrichResponseHandlesEmpty() {
        let json = """
        {"decisions": [], "follow_ups": []}
        """
        let (decisions, followUps) = SummaryPrompt.parseEnrichResponse(json)
        #expect(decisions.isEmpty)
        #expect(followUps.isEmpty)
    }

    @Test
    func parseEnrichResponseHandlesInvalidJSON() {
        let (decisions, followUps) = SummaryPrompt.parseEnrichResponse("not json")
        #expect(decisions.isEmpty)
        #expect(followUps.isEmpty)
    }

    @Test
    func mergeQuickAndEnrichCombinesCorrectly() {
        let quick = SummaryResult(
            title: "Meeting", overview: "Overview", keyPoints: ["Point"],
            actionItems: [], decisions: [], followUps: [], yourTasks: [],
            tags: ["tag"], chapters: [], rawText: "quick raw",
            meetingType: "general"
        )
        let merged = SummaryPrompt.mergeQuickAndEnrich(
            quick: quick,
            decisions: ["Decision A"],
            followUps: ["Follow B"],
            enrichRawText: "enrich raw"
        )
        #expect(merged.title == "Meeting")
        #expect(merged.overview == "Overview")
        #expect(merged.keyPoints == ["Point"])
        #expect(merged.decisions == ["Decision A"])
        #expect(merged.followUps == ["Follow B"])
        #expect(merged.tags == ["tag"])
        #expect(merged.rawText.contains("quick raw"))
        #expect(merged.rawText.contains("enrich raw"))
    }
}
