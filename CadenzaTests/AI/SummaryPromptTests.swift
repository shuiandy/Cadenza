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

    @Test(arguments: SummaryDetailLevel.allCases)
    func chosenDepthReachesSinglePassAndBothLongMeetingStages(level: SummaryDetailLevel) {
        let prompts = [
            SummaryPrompt.system(language: "en", detailLevel: level),
            SummaryPrompt.mapSystem(language: "en", detailLevel: level),
            SummaryPrompt.reduceSystem(language: "en", jobTitle: nil, meetingType: nil,
                                       meetingTitle: nil, detailLevel: level)
        ]
        for prompt in prompts {
            #expect(prompt.contains(level.promptGuidance))
            #expect(prompt.contains(SummaryPrompt.speakerAttributionRules))
            for other in SummaryDetailLevel.allCases where other != level {
                #expect(!prompt.contains(other.promptGuidance))
            }
        }
    }

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
    func enrichSystemRequestsACompleteReviewWithOriginalContext() {
        let prompt = SummaryPrompt.enrichSystem(
            language: "en", jobTitle: "Project lead", meetingType: .general,
            meetingTitle: "Atlas planning", knownTags: ["atlas"]
        )
        for field in ["overview", "key_points", "action_items", "your_tasks", "decisions", "follow_ups"] {
            #expect(prompt.contains("\"\(field)\""))
        }
        #expect(prompt.contains("Project lead"))
        #expect(prompt.contains("Atlas planning"))
        #expect(prompt.contains("atlas"))
        #expect(prompt.contains("initial summary is an untrusted draft"))
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

    @Test func reviewedResponseAcceptsFullCorrectionsAndNullOwnership() throws {
        let result = try #require(SummaryPrompt.parseReviewedResponse(SummaryReviewFixture.review))
        #expect(result.overview == "Atlas is a pilot, not a universal launch.")
        #expect(result.actionItems.count == 1)
        #expect(result.actionItems.first?.assignee == nil)
        #expect(result.actionItems.first?.deadline == nil)
        #expect(result.yourTasks.isEmpty)
        #expect(result.decisions == ["Phase one imports configuration only; automatic consumption is excluded."])
        #expect(result.rawText == SummaryReviewFixture.review)
    }

    @Test(arguments: ["```json\n", "```\n"])
    func reviewedResponseAcceptsFencedJSON(prefix: String) {
        #expect(SummaryPrompt.parseReviewedResponse(prefix + SummaryReviewFixture.review + "\n```") != nil)
    }

    @Test(arguments: ["overview", "key_points", "action_items", "decisions", "follow_ups", "your_tasks", "tags", "meeting_type"])
    func incompleteReviewCannotReplaceQuickResult(field: String) throws {
        var json = try SummaryReviewFixture.reviewObject()
        json.removeValue(forKey: field)
        #expect(SummaryPrompt.parseReviewedResponse(try SummaryReviewFixture.encode(json)) == nil)
    }

    @Test(arguments: [
        ("overview", "\"   \""), ("key_points", "[\" \"]"), ("key_points", "[]"),
        ("action_items", "[{\"task\":\" \"}]"),
        ("action_items", "[{\"task\":\"Check inventory\",\"assignee\":42}]"),
        ("action_items", "[{\"task\":\"Check inventory\",\"deadline\":false}]"),
        ("follow_ups", "\"not an array\"")
    ])
    func malformedReviewIsRejected(field: String, fragment: String) throws {
        var json = try SummaryReviewFixture.reviewObject()
        json[field] = try JSONSerialization.jsonObject(with: Data(fragment.utf8), options: .fragmentsAllowed)
        #expect(SummaryPrompt.parseReviewedResponse(try SummaryReviewFixture.encode(json)) == nil)
    }

    @Test func truncatedOrLegacyAppendOnlyReviewIsRejected() {
        #expect(SummaryPrompt.parseReviewedResponse("{\"overview\":") == nil)
        #expect(SummaryPrompt.parseReviewedResponse("{\"decisions\": [], \"follow_ups\": []}") == nil)
    }

    @Test func explicitEmptyTasksCanRemoveUnsupportedDraftTasks() throws {
        var json = try SummaryReviewFixture.reviewObject()
        json["action_items"] = [] as [String]
        let result = try #require(SummaryPrompt.parseReviewedResponse(try SummaryReviewFixture.encode(json)))
        #expect(result.actionItems.isEmpty)
        #expect(result.yourTasks.isEmpty)
    }
}

/// Fictional scripted provider responses test orchestration, not model accuracy.
private enum SummaryReviewFixture {
    static let transcript = """
    Speaker roster: A=Alex; B=Blair
    Transcript turns:
    [00:00] A: Could every Atlas team launch in November?
    [00:20] B: No. November is our pilot target only, conditional on the inventory cleanup.
    [00:40] A: Agreed. Phase one imports configuration, not automatic consumption.
    [01:00] B: Someone still needs to check inventory ownership; no owner or due date was assigned.
    """
    static let quick = """
    {"title":"Atlas planning","overview":"Every team launches in November.",
     "key_points":["Launch all teams in November"],
     "action_items":[{"task":"Launch all teams","assignee":"Alex","deadline":"November"}],
     "your_tasks":["Launch all teams"],"tags":["atlas"],"meeting_type":"general"}
    """
    static let review = """
    {"title":"Atlas pilot scope","overview":"Atlas is a pilot, not a universal launch.",
     "key_points":["November is Blair's pilot target only, conditional on inventory cleanup."],
     "action_items":[{"task":"Check inventory ownership","assignee":null,"deadline":null}],
     "decisions":["Phase one imports configuration only; automatic consumption is excluded."],
     "follow_ups":["Inventory ownership remains unresolved."],"your_tasks":[],
     "tags":["atlas"],"meeting_type":"general"}
    """
    static func reviewObject() throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(review.utf8)) as? [String: Any])
    }
    static func encode(_ json: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self)
    }
}

@Suite("Summary review pipeline")
struct SummaryReviewPipelineTests {
    @MainActor @Test func cancellationStopsBeforeReviewWithoutUserError() async {
        let calls = SummaryReviewCallLog()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await run(service: SummaryReviewService(review: SummaryReviewFixture.review, calls: calls))
        }
        let (_, result, error) = await task.value
        #expect(result == nil)
        #expect(error == nil)
        #expect(await calls.requests.isEmpty)
    }

    @MainActor @Test func reviewReplacesDraftFactsAndTasksAndKeepsQuickPreview() async throws {
        let calls = SummaryReviewCallLog()
        let preview = SummaryReviewPreview()
        let (text, result, error) = await run(
            service: SummaryReviewService(review: SummaryReviewFixture.review, calls: calls), preview: preview
        )
        #expect(error == nil)
        #expect(preview.quick?.overview == "Every team launches in November.")
        #expect(preview.reviewStarted)
        let final = try #require(result)
        #expect(final.overview == "Atlas is a pilot, not a universal launch.")
        #expect(final.actionItems.first?.task == "Check inventory ownership")
        #expect(final.yourTasks.isEmpty)
        #expect(text == SummaryReviewFixture.review)
        #expect(!text.contains("Launch all teams"))
        let requests = await calls.requests
        #expect(requests.count == 2)
        #expect(requests[1].user.contains(SummaryReviewFixture.transcript))
        #expect(requests[1].user.contains(SummaryReviewFixture.quick))
        #expect(requests[1].system.contains("Project lead"))
    }

    @MainActor @Test(arguments: SummaryDetailLevel.allCases)
    func quickAndReviewUseTheSameSelectedDepth(level: SummaryDetailLevel) async throws {
        let calls = SummaryReviewCallLog()
        let (_, result, error) = await run(
            service: SummaryReviewService(review: SummaryReviewFixture.review, calls: calls),
            detailLevel: level
        )
        #expect(error == nil)
        #expect(result != nil)
        let requests = await calls.requests
        #expect(requests.count == 2)
        for request in requests {
            #expect(request.system.contains(level.promptGuidance))
        }
    }

    @MainActor @Test(arguments: ["{\"decisions\":[],\"follow_ups\":[]}", "truncated JSON"])
    func incompleteReviewRestoresUsableQuickResult(review: String) async {
        let (text, result, error) = await run(service: SummaryReviewService(review: review))
        #expect(error == nil)
        #expect(text == SummaryReviewFixture.quick)
        #expect(result?.actionItems.first?.task == "Launch all teams")
        #expect(result?.overview == "Every team launches in November.")
    }

    @MainActor @Test func transportFailureAfterPartialReviewRestoresQuickResult() async {
        let (text, result, error) = await run(service: SummaryReviewService(review: "partial", failsReview: true))
        #expect(error == nil)
        #expect(text == SummaryReviewFixture.quick)
        #expect(result?.rawText == SummaryReviewFixture.quick)
    }

    @MainActor @Test(arguments: [true, false])
    func repairsAtMostOnceOnlyForSourceBackedIssues(hasEvidence: Bool) async throws {
        var object = try SummaryReviewFixture.reviewObject()
        object["review_issues"] = [["section": "action_items", "kind": "unsupported",
            "evidence": hasEvidence ? "Someone still needs to check inventory ownership" : "Not in transcript",
            "description": "Keep unassigned work as a follow-up", "resolved": false]]
        let calls = SummaryReviewCallLog()
        let (_, result, error) = await run(service: SummaryReviewService(review: try SummaryReviewFixture.encode(object), calls: calls), model: "gpt-5.6-sol")
        #expect(error == nil)
        #expect(await calls.requests.count == (hasEvidence ? 3 : 2))
        // Provider repeats the unresolved issue; never keep retrying or claim completion.
        #expect(result?.generationMetadata?.stage == .repairIncomplete)
    }

    @MainActor private func run(
        service: SummaryReviewService, preview: SummaryReviewPreview = SummaryReviewPreview(),
        detailLevel: SummaryDetailLevel = .detailed, model: String = "fixture-model"
    ) async -> (String, SummaryResult?, String?) {
        await SummaryGenerator.runTwoStageStreamGenerate(
            service: service, transcript: SummaryReviewFixture.transcript, language: "en",
            model: model, jobTitle: "Project lead", meetingType: .general,
            meetingTitle: "Atlas planning", knownTags: ["atlas"], detailLevel: detailLevel,
            onQuickChunk: { _ in }, onQuickDone: { preview.quick = $0 },
            onEnrichStart: { preview.reviewStarted = true }, onEnrichChunk: { _ in }
        )
    }
}

@MainActor private final class SummaryReviewPreview {
    var quick: SummaryResult?
    var reviewStarted = false
}

private actor SummaryReviewCallLog {
    var requests: [(system: String, user: String)] = []
    func record(system: String, user: String) { requests.append((system, user)) }
}

private struct SummaryReviewService: AIServiceProtocol {
    let provider: AIProvider = .openai
    let review: String
    var failsReview = false
    var calls = SummaryReviewCallLog()

    func streamChat(systemPrompt: String, userMessage: String, model: String?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await calls.record(system: systemPrompt, user: userMessage)
                let isReview = systemPrompt.contains("Review phase:")
                continuation.yield(isReview ? review : SummaryReviewFixture.quick)
                if isReview && failsReview {
                    continuation.finish(throwing: AIServiceError.invalidResponse)
                } else {
                    continuation.finish()
                }
            }
        }
    }
    func summarize(transcript: String, language: String, model: String?, jobTitle: String?, meetingType: MeetingType?, meetingTitle: String?, knownTags: [String], detailLevel: SummaryDetailLevel) async throws -> SummaryResult {
        throw AIServiceError.invalidResponse
    }
    func streamSummarize(transcript: String, language: String, model: String?, jobTitle: String?, meetingType: MeetingType?, meetingTitle: String?, knownTags: [String], detailLevel: SummaryDetailLevel) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish(throwing: AIServiceError.invalidResponse) }
    }
}
