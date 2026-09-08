import Foundation
import Testing

@testable import Cadenza

@Suite("Gemini Interactions transcription")
struct GeminiTranscribeInteractionTests {

    // MARK: - Model routing

    @Test(arguments: [
        "gemini-3.5-transcribe",
        "gemini-3.5-transcribe-live",
        "gemini-4-transcribe-preview",
        "GEMINI-3.5-TRANSCRIBE",
    ])
    func transcribeFamilyRoutesToInteractions(_ model: String) {
        #expect(GeminiTranscribeInteraction.isTranscribeModel(model))
    }

    @Test(arguments: ["gemini-3.7-flash", "gemini-3.5-flash", "gemini-3.1-flash-live-preview", ""])
    func otherModelsKeepTheGenerateContentPath(_ model: String) {
        #expect(GeminiTranscribeInteraction.isTranscribeModel(model) == false)
    }

    // MARK: - Language hints

    @Test func absentOrAutoLanguageMeansAutoDetect() {
        #expect(GeminiTranscribeInteraction.languageCodes(for: nil).isEmpty)
        #expect(GeminiTranscribeInteraction.languageCodes(for: "").isEmpty)
        #expect(GeminiTranscribeInteraction.languageCodes(for: "auto").isEmpty)
        #expect(GeminiTranscribeInteraction.languageCodes(for: "AUTO").isEmpty)
    }

    @Test func chineseIsPinnedToSimplifiedScript() {
        #expect(GeminiTranscribeInteraction.languageCodes(for: "zh") == ["zh-CN"])
    }

    @Test func otherLanguagesPassThroughAsBCP47() {
        #expect(GeminiTranscribeInteraction.languageCodes(for: "en") == ["en"])
        #expect(GeminiTranscribeInteraction.languageCodes(for: "ja") == ["ja"])
    }

    // MARK: - Request

    @Test func requestCarriesModelAudioAndTranscriptionConfig() throws {
        let data = try GeminiTranscribeInteraction.makeRequestBody(
            model: "gemini-3.5-transcribe",
            base64Audio: "QUJD",
            mimeType: "audio/mp4",
            language: "zh"
        )
        let json = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(json["model"] as? String == "gemini-3.5-transcribe")
        // Meeting audio must not be retained server-side just to transcribe it.
        #expect(json["store"] as? Bool == false)

        let input = try #require(json["input"] as? [[String: Any]])
        #expect(input.count == 1)
        #expect(input[0]["type"] as? String == "audio")
        #expect(input[0]["data"] as? String == "QUJD")
        #expect(input[0]["mime_type"] as? String == "audio/mp4")

        let generation = try #require(json["generation_config"] as? [String: Any])
        let config = try #require(generation["transcription_config"] as? [String: Any])
        #expect(config["language_codes"] as? [String] == ["zh-CN"])

        let mode = try #require(config["mode"] as? [String: Any])
        #expect(mode["type"] as? String == "verbatim")
        #expect(mode["diarization_mode"] as? String == "speaker")
        #expect(mode["timestamp_granularities"] as? [String] == ["word"])
    }

    // MARK: - Scalar parsing

    @Test func protobufDurationsParseFromStringsAndNumbers() {
        #expect(GeminiTranscribeInteraction.duration("12.5s") == 12.5)
        #expect(GeminiTranscribeInteraction.duration("0s") == 0)
        #expect(GeminiTranscribeInteraction.duration(3.25) == 3.25)
        #expect(GeminiTranscribeInteraction.duration(nil) == nil)
        #expect(GeminiTranscribeInteraction.duration("later") == nil)
    }

    @Test func wireSpeakerLabelsBecomeCadenzaLabels() {
        #expect(GeminiTranscribeInteraction.speakerLabel("spk_1") == "Speaker 1")
        #expect(GeminiTranscribeInteraction.speakerLabel("spk_12") == "Speaker 12")
        #expect(GeminiTranscribeInteraction.speakerLabel("speaker_2") == "Speaker 2")
        #expect(GeminiTranscribeInteraction.speakerLabel("Andy") == "Andy")
        #expect(GeminiTranscribeInteraction.speakerLabel("  ") == nil)
        #expect(GeminiTranscribeInteraction.speakerLabel(nil) == nil)
    }

    // MARK: - Word joining

    @Test func latinWordsAreSpacedAndPunctuationHugs() {
        var text = ""
        for word in ["Ship", "it", "today", ","] {
            text = GeminiTranscribeInteraction.appending(word, to: text)
        }
        #expect(text == "Ship it today,")
    }

    @Test func scriptsWithoutWordSpacesAreNotPaddedApart() {
        var text = ""
        for word in ["我们", "明天", "上线", "。"] {
            text = GeminiTranscribeInteraction.appending(word, to: text)
        }
        #expect(text == "我们明天上线。")
    }

    @Test func koreanKeepsItsWordSpaces() {
        var text = ""
        for word in ["오늘", "회의"] {
            text = GeminiTranscribeInteraction.appending(word, to: text)
        }
        #expect(text == "오늘 회의")
    }

    @Test func mixedScriptBoundaryDoesNotInventASpace() {
        let text = GeminiTranscribeInteraction.appending("Cycode", to: "我们用")
        #expect(text == "我们用Cycode")
    }

    // MARK: - Segmentation

    private func word(
        _ text: String,
        _ start: TimeInterval,
        _ end: TimeInterval,
        _ speaker: String?
    ) -> GeminiTranscribeInteraction.Word {
        .init(text: text, start: start, end: end, speaker: speaker)
    }

    @Test func speakerChangeStartsANewSegment() {
        let segments = GeminiTranscribeInteraction.buildSegments(from: [
            word("Hello", 0, 0.5, "Speaker 1"),
            word("there", 0.5, 1.0, "Speaker 1"),
            word("Hi", 1.1, 1.5, "Speaker 2"),
        ])

        #expect(segments.count == 2)
        #expect(segments[0].text == "Hello there")
        #expect(segments[0].speaker == "Speaker 1")
        #expect(segments[0].startTime == 0)
        #expect(segments[0].endTime == 1.0)
        #expect(segments[1].text == "Hi")
        #expect(segments[1].speaker == "Speaker 2")
        #expect(segments[1].startTime == 1.1)
    }

    @Test func aLongPauseBreaksASegmentWithinOneSpeaker() {
        let gap = GeminiTranscribeInteraction.segmentSilenceGap
        let segments = GeminiTranscribeInteraction.buildSegments(from: [
            word("First", 0, 0.5, "Speaker 1"),
            word("Second", 0.5 + gap, 1.0 + gap, "Speaker 1"),
        ])

        #expect(segments.count == 2)
        #expect(segments[0].text == "First")
        #expect(segments[1].text == "Second")
    }

    @Test func oneSpeakerTalkingForeverStillGetsSplit() {
        // Sixty seconds of uninterrupted speech from a single speaker: the
        // exact shape that used to collapse into one unreadable wall.
        let words = (0..<120).map { index in
            word("word", TimeInterval(index) * 0.5, TimeInterval(index) * 0.5 + 0.4, "Speaker 1")
        }
        let segments = GeminiTranscribeInteraction.buildSegments(from: words)

        #expect(segments.count > 1)
        for segment in segments {
            #expect(segment.endTime - segment.startTime <= GeminiTranscribeInteraction.maxSegmentDuration + 1)
            #expect(segment.speaker == "Speaker 1")
        }
        #expect(segments.map(\.startTime) == segments.map(\.startTime).sorted())
    }

    @Test func undiarizedWordsStillProduceTimedSegments() {
        // Eighty unbroken seconds with no speaker labels at all: the caps are
        // the only thing standing between this and one giant segment.
        let words = (0..<800).map { index in
            word("w", TimeInterval(index) * 0.1, TimeInterval(index) * 0.1 + 0.08, nil)
        }
        let segments = GeminiTranscribeInteraction.buildSegments(from: words)

        #expect(segments.count > 1)
        #expect(segments.allSatisfy { $0.speaker == nil })
        #expect(segments.allSatisfy { $0.text.count <= GeminiTranscribeInteraction.maxSegmentCharacters + 8 })
        #expect(segments.allSatisfy { $0.endTime - $0.startTime <= GeminiTranscribeInteraction.maxSegmentDuration + 1 })
        // No word may be dropped on the way through segmentation.
        #expect(segments.map { $0.text.filter { $0 == "w" }.count }.reduce(0, +) == 800)
    }

    @Test func aShortUndiarizedRunStaysOneSegment() {
        // The caps must not fragment ordinary speech: twenty seconds well
        // inside both limits belongs in a single segment.
        let words = (0..<120).map { index in
            word("w", TimeInterval(index) * 0.1, TimeInterval(index) * 0.1 + 0.08, nil)
        }
        #expect(GeminiTranscribeInteraction.buildSegments(from: words).count == 1)
    }

    @Test func noWordsProducesNoSegments() {
        #expect(GeminiTranscribeInteraction.buildSegments(from: []).isEmpty)
    }

    // MARK: - Response parsing

    private func response(
        outputKey: String = "output_text",
        startKey: String = "start_offset",
        endKey: String = "end_offset"
    ) -> Data {
        let json: [String: Any] = [
            "id": "int_1",
            "status": "completed",
            outputKey: "Hello there Hi",
            "steps": [
                [
                    "type": "model_output",
                    "content": [
                        [
                            "type": "text",
                            "text": "Hello there Hi",
                            "annotations": [
                                ["type": "word_info", "text": "Hello", startKey: "0s", endKey: "0.5s", "speaker": "spk_1"],
                                ["type": "word_info", "text": "there", startKey: "0.5s", endKey: "1s", "speaker": "spk_1"],
                                ["type": "word_info", "text": "Hi", startKey: "1.1s", endKey: "1.5s", "speaker": "spk_2"],
                            ]
                        ]
                    ]
                ]
            ]
        ]
        return try! JSONSerialization.data(withJSONObject: json)
    }

    @Test func annotationsBecomeTimedDiarizedSegments() throws {
        let result = try GeminiTranscribeInteraction.parse(response(), language: "en").result

        #expect(result.text == "Hello there Hi")
        #expect(result.language == "en")
        #expect(result.segments.count == 2)
        #expect(result.segments[0].speaker == "Speaker 1")
        #expect(result.segments[0].text == "Hello there")
        #expect(result.segments[1].speaker == "Speaker 2")
        #expect(result.segments[1].startTime == 1.1)
    }

    @Test func camelCaseWireFormatParsesIdentically() throws {
        let camel = try GeminiTranscribeInteraction.parse(
            response(outputKey: "outputText", startKey: "startOffset", endKey: "endOffset"),
            language: "en"
        ).result
        let snake = try GeminiTranscribeInteraction.parse(response(), language: "en").result

        #expect(camel.text == snake.text)
        #expect(camel.segments.count == snake.segments.count)
        #expect(camel.segments[0].speaker == snake.segments[0].speaker)
        #expect(camel.segments[1].startTime == snake.segments[1].startTime)
    }

    // One segment here because the transcript is one sentence, not because a
    // degraded response is allowed to collapse. See the degradation section.
    @Test func aOneSentenceDegradedTranscriptStaysOneSegment() throws {
        let json: [String: Any] = [
            "status": "completed",
            "output_text": "No annotations came back."
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let result = try GeminiTranscribeInteraction.parse(data, language: nil).result

        #expect(result.text == "No annotations came back.")
        #expect(result.segments.count == 1)
        #expect(result.segments[0].speaker == nil)
        #expect(result.segments[0].startTime == 0)
    }

    @Test func stepTextIsUsedWhenTheSdkConvenienceFieldIsAbsent() throws {
        let json: [String: Any] = [
            "status": "completed",
            "steps": [
                ["type": "model_output", "content": [["type": "text", "text": "Raw REST transcript."]]]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let result = try GeminiTranscribeInteraction.parse(data, language: nil).result

        #expect(result.text == "Raw REST transcript.")
    }

    @Test func reportedErrorsThrowRatherThanReturningEmptyText() throws {
        let json: [String: Any] = [
            "status": "failed",
            "errors": [["message": "audio too long"]]
        ]
        let data = try JSONSerialization.data(withJSONObject: json)

        #expect(throws: TranscriptionError.self) {
            _ = try GeminiTranscribeInteraction.parse(data, language: nil)
        }
    }

    @Test(arguments: ["in_progress", "queued", "requires_action"])
    func nonTerminalStatusIsReportedRatherThanReadAsEmpty(_ status: String) throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "status": status,
            "output_text": ""
        ])

        #expect(throws: TranscriptionError.self) {
            _ = try GeminiTranscribeInteraction.parse(data, language: nil)
        }
    }

    @Test func emptyResponseThrows() throws {
        let data = try JSONSerialization.data(withJSONObject: ["status": "completed"])

        #expect(throws: TranscriptionError.self) {
            _ = try GeminiTranscribeInteraction.parse(data, language: nil)
        }
    }

    @Test func malformedBodyThrows() {
        #expect(throws: TranscriptionError.self) {
            _ = try GeminiTranscribeInteraction.parse(Data("not json".utf8), language: nil)
        }
    }

    // MARK: - Provider degradation
    //
    // OpenAI's diarizing model silently stopped returning speaker data in
    // August 2026 and the client amplified it into multi-minute blocks that no
    // later pass could re-segment. These pin the equivalent Gemini failures to
    // a survivable shape.

    @Test func aResponseThatLostItsAnnotationsIsNeverOneBlock() throws {
        // Five minutes of transcript with no word_info at all: the exact shape
        // that used to collapse a whole chunk into one zero-length segment.
        let transcript = Array(repeating: "We should ship the migration today.", count: 60)
            .joined(separator: " ")
        let data = try JSONSerialization.data(withJSONObject: [
            "status": "completed",
            "output_text": transcript
        ])

        let parsed = try GeminiTranscribeInteraction.parse(data, language: nil, audioDuration: 300)

        #expect(parsed.quality.isDegraded)
        #expect(parsed.quality.wordCount == 0)
        #expect(parsed.result.segments.count > 1)
        // Timings must span the audio, not collapse to zero.
        #expect(parsed.result.segments.first?.startTime == 0)
        #expect((parsed.result.segments.last?.endTime ?? 0) > 290)
        #expect(parsed.result.segments.allSatisfy { $0.endTime >= $0.startTime })
        // Monotonic and non-overlapping, so alignment has something to use.
        for (previous, next) in zip(parsed.result.segments, parsed.result.segments.dropFirst()) {
            #expect(next.startTime >= previous.endTime)
        }
        // Nothing is dropped on the way through the fallback.
        let rejoined = parsed.result.segments.map(\.text).joined(separator: " ")
        #expect(rejoined.filter { !$0.isWhitespace } == transcript.filter { !$0.isWhitespace })
    }

    @Test func degradedFallbackStillSplitsWhenDurationIsUnknown() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "status": "completed",
            "output_text": "First point. Second point. Third point."
        ])

        let parsed = try GeminiTranscribeInteraction.parse(data, language: nil, audioDuration: nil)

        #expect(parsed.result.segments.count == 3)
        #expect(parsed.result.segments.allSatisfy { $0.startTime == 0 && $0.endTime == 0 })
    }

    @Test func annotationsWithoutTimestampsCountAsDegraded() throws {
        // Speakers survived but offsets did not: segmenting on speaker changes
        // alone would emit confident-looking segments with worthless timings.
        let data = try JSONSerialization.data(withJSONObject: [
            "status": "completed",
            "output_text": "Hello there. Hi back.",
            "steps": [["type": "model_output", "content": [[
                "type": "text",
                "annotations": [
                    ["type": "word_info", "text": "Hello", "speaker": "spk_1"],
                    ["type": "word_info", "text": "there", "speaker": "spk_1"],
                    ["type": "word_info", "text": "Hi", "speaker": "spk_2"],
                ]
            ]]]]
        ])

        let parsed = try GeminiTranscribeInteraction.parse(data, language: nil, audioDuration: 12)

        #expect(parsed.quality.isDegraded)
        #expect(parsed.quality.wordCount == 3)
        #expect(parsed.quality.timedWordCount == 0)
        #expect(parsed.quality.speakerLabelledWordCount == 3)
        #expect(parsed.result.segments.count > 1)
        #expect((parsed.result.segments.last?.endTime ?? 0) > 0)
    }

    @Test func missingSpeakersAloneIsNotDegraded() throws {
        // Timings are intact, so the segments are real and the local
        // diarization pass can label them. Retrying would waste the budget.
        let data = try JSONSerialization.data(withJSONObject: [
            "status": "completed",
            "output_text": "One two three",
            "steps": [["type": "model_output", "content": [[
                "type": "text",
                "annotations": [
                    ["type": "word_info", "text": "One", "start_offset": "0s", "end_offset": "0.4s"],
                    ["type": "word_info", "text": "two", "start_offset": "0.4s", "end_offset": "0.8s"],
                    ["type": "word_info", "text": "three", "start_offset": "9s", "end_offset": "9.5s"],
                ]
            ]]]]
        ])

        let parsed = try GeminiTranscribeInteraction.parse(data, language: nil, audioDuration: 10)

        #expect(parsed.quality.isDegraded == false)
        #expect(parsed.quality.speakerLabelledWordCount == 0)
        #expect(parsed.result.segments.count == 2)  // split by the 9s pause
        #expect(parsed.result.segments.allSatisfy { $0.speaker == nil })
        #expect(parsed.result.segments[1].startTime == 9)
    }

    // MARK: - Sentence splitting

    @Test func sentencesSplitOnBothLatinAndCJKTerminators() {
        #expect(
            GeminiTranscribeInteraction.sentences(in: "Ship it. Now! Really?")
                == ["Ship it.", "Now!", "Really?"]
        )
        #expect(
            GeminiTranscribeInteraction.sentences(in: "上线了。真的吗？好的！")
                == ["上线了。", "真的吗？", "好的！"]
        )
    }

    @Test func unpunctuatedTextIsHardWrappedRatherThanLeftWhole() {
        let wall = String(repeating: "词", count: 2_000)
        let pieces = GeminiTranscribeInteraction.sentences(in: wall)

        #expect(pieces.count > 1)
        #expect(pieces.allSatisfy { $0.count <= GeminiTranscribeInteraction.maxSegmentCharacters })
        #expect(pieces.joined().count == 2_000)
    }
}
