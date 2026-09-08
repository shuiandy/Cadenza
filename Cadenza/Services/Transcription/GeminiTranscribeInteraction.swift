import Foundation
import os

/// Response *shape* only — key names and counts, never transcript content. A
/// response that silently stops carrying `word_info` is otherwise
/// indistinguishable from audio that genuinely had nothing in it, which is how
/// the OpenAI diarization regression stayed invisible for two weeks. Notice
/// level because `.info` is unpersisted by default.
private let interactionLog = Logger(
    subsystem: "com.shuiandy.Cadenza",
    category: "GeminiTranscribe"
)

/// Request building and response parsing for the Gemini Interactions API
/// transcription surface (`POST /v1beta/interactions`), which backs the
/// `gemini-3.5-transcribe` model family.
///
/// This is a different API from `generateContent`, not a new model ID on the
/// same one: the model is named in the body rather than the path, audio is a
/// typed `input` part instead of an attachment to a prompt, and the transcript
/// comes back as `output_text` plus word-level `word_info` annotations that
/// carry speaker labels and time offsets. Nothing is asked of the model in
/// prose, so there is no prompt to drift and no JSON schema to violate.
///
/// Protobuf-JSON reaches the wire in either casing depending on the caller, so
/// every key below is read in both `snake_case` and `camelCase`.
enum GeminiTranscribeInteraction {
    /// Longest span one built segment may cover, and the most text it may
    /// hold. Both caps exist because segments here are assembled from words:
    /// without them a long same-speaker run (or a recording that came back
    /// with no diarization at all) collapses into one wall of text that no
    /// later subdivision or diarization pass can meaningfully re-label.
    /// Mirrors `WhisperTranscriber.mergeSameSpeakerSegments`.
    static let maxSegmentDuration: TimeInterval = 30
    static let maxSegmentCharacters = 500
    /// A pause at least this long ends a segment even within one speaker, so
    /// segment boundaries land on natural breaks rather than the caps alone.
    static let segmentSilenceGap: TimeInterval = 1.5

    /// Whether `model` speaks the Interactions transcription API rather than
    /// `generateContent`. Deliberately a family test, not an exact match: a
    /// user override of `transcriptionModel.gemini` to a future
    /// `gemini-4-transcribe` should route the same way without a rebuild.
    static func isTranscribeModel(_ model: String) -> Bool {
        model.lowercased().contains("transcribe")
    }

    // MARK: - Request

    /// BCP-47 hints for `language_codes`. Empty means auto-detect, which is
    /// also what enables mid-recording code-switching, so an unknown or
    /// unset language must produce `[]` rather than a guess.
    static func languageCodes(for language: String?) -> [String] {
        guard let language,
              !language.isEmpty,
              language.lowercased() != "auto" else { return [] }
        // Chinese is the one case where the bare subtag leaves script
        // ambiguous, and Traditional output for Simplified speech has been a
        // recurring complaint. Everything else Cadenza offers is already a
        // valid BCP-47 primary subtag.
        if language.lowercased() == "zh" { return ["zh-CN"] }
        return [language]
    }

    static func makeRequestBody(
        model: String,
        base64Audio: String,
        mimeType: String,
        language: String?
    ) throws -> Data {
        // Word timestamps trade a little accuracy for timing (the model card
        // says so), but Cadenza's transcript UI, subdivision and speaker
        // alignment are all keyed on segment times, so they are not optional.
        let body: [String: Any] = [
            "model": model,
            // The Interactions API stores every interaction by default and
            // keeps it for 55 days on the paid tier. That would mean Google
            // retaining a copy of the user's meeting audio as a side effect of
            // transcribing it, which the generateContent path never did.
            // Cadenza chains no interactions and runs no background jobs, so
            // opting out costs nothing.
            "store": false,
            "input": [
                [
                    "type": "audio",
                    "data": base64Audio,
                    "mime_type": mimeType
                ]
            ],
            "generation_config": [
                "transcription_config": [
                    "language_codes": languageCodes(for: language),
                    "mode": [
                        "type": "verbatim",
                        "diarization_mode": "speaker",
                        "timestamp_granularities": ["word"]
                    ]
                ]
            ]
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    // MARK: - Response

    struct Word: Sendable, Equatable {
        let text: String
        let start: TimeInterval?
        let end: TimeInterval?
        let speaker: String?
    }

    /// What the provider actually returned, independent of whether the text
    /// looks fine. Counts only, never content.
    struct Quality: Sendable, Equatable {
        let wordCount: Int
        let timedWordCount: Int
        let speakerLabelledWordCount: Int

        /// The request asked for word timestamps and diarization. A response
        /// carrying no usable word annotations is a provider regression, not
        /// an empty room, and it is the shape that collapses a whole chunk
        /// into one untimed block. Missing speakers alone is survivable: the
        /// local diarization pass fills those in.
        var isDegraded: Bool { wordCount == 0 || timedWordCount == 0 }

        var shapeDescription: String {
            "words=\(wordCount) timed=\(timedWordCount) speakers=\(speakerLabelledWordCount)"
        }
    }

    struct Parsed: Sendable {
        let result: TranscriptResult
        let quality: Quality
    }

    static func parse(
        _ data: Data,
        language: String?,
        audioDuration: TimeInterval? = nil
    ) throws -> Parsed {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TranscriptionError.apiError("Failed to parse Gemini transcription response")
        }
        if let message = errorMessage(in: json) {
            throw TranscriptionError.apiError(message)
        }

        let words = extractWords(from: json)
        let outputText = Self.outputText(in: json)
        let quality = Quality(
            wordCount: words.count,
            timedWordCount: words.count { $0.start != nil },
            speakerLabelledWordCount: words.count { $0.speaker != nil }
        )

        if !quality.isDegraded {
            let segments = buildSegments(from: words)
            if !segments.isEmpty {
                if quality.speakerLabelledWordCount == 0 {
                    interactionLog.notice(
                        "transcribe: no speaker labels in response (\(quality.shapeDescription, privacy: .public)), deferring to local diarization"
                    )
                }
                let text = outputText ?? segments.map(\.text).joined(separator: " ")
                return Parsed(
                    result: TranscriptResult(
                        text: text,
                        segments: segments,
                        language: language,
                        duration: nil
                    ),
                    quality: quality
                )
            }
        }

        // Degraded: the response carried no usable word annotations. The
        // transcript itself is usually still good, so the chunk is salvaged
        // rather than failed — but never as one untimed block. That shape
        // survives `subdivideCoarseSegments` (which only splits spans over
        // 60s, and this one would claim zero) and denies every downstream
        // pass anything to align against. Sentence-split it and spread it
        // across the span the audio actually occupied instead.
        guard let outputText, !outputText.isEmpty else {
            throw TranscriptionError.apiError("Gemini transcription response contained no transcript")
        }
        interactionLog.notice(
            "transcribe: DEGRADED response, no usable word annotations (\(quality.shapeDescription, privacy: .public)); falling back to sentence split over \(audioDuration ?? 0, privacy: .public)s"
        )
        return Parsed(
            result: TranscriptResult(
                text: outputText,
                segments: fallbackSegments(from: outputText, audioDuration: audioDuration),
                language: language,
                duration: nil
            ),
            quality: quality
        )
    }

    /// Last-resort segmentation from plain text. Timings are interpolated by
    /// character share across `audioDuration`, so they are approximate by
    /// construction; they exist so the timeline, subdivision and speaker
    /// alignment have real spans to work with instead of a single zero-length
    /// segment. With no known duration the spans stay zero, but the text is
    /// still split so nothing downstream sees one monolithic block.
    static func fallbackSegments(
        from text: String,
        audioDuration: TimeInterval?
    ) -> [TranscriptResultSegment] {
        let pieces = sentences(in: text)
        guard !pieces.isEmpty else { return [] }

        let totalCharacters = pieces.reduce(0) { $0 + $1.count }
        let span = (audioDuration?.isFinite == true && (audioDuration ?? 0) > 0) ? audioDuration! : 0
        var segments: [TranscriptResultSegment] = []
        var consumed = 0
        var start: TimeInterval = 0

        for piece in pieces {
            consumed += piece.count
            let end = totalCharacters > 0
                ? span * TimeInterval(consumed) / TimeInterval(totalCharacters)
                : 0
            segments.append(TranscriptResultSegment(
                startTime: start,
                endTime: max(start, end),
                text: piece,
                speaker: nil
            ))
            start = max(start, end)
        }
        return segments
    }

    /// Split on sentence terminators in both Latin and CJK punctuation, then
    /// hard-wrap anything still over the character cap so a transcript with no
    /// punctuation at all cannot come back as one block.
    static func sentences(in text: String) -> [String] {
        let terminators: Set<Character> = [".", "!", "?", "\n", "。", "！", "？", "；", ";"]
        var pieces: [String] = []
        var current = ""

        func commit() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { pieces.append(trimmed) }
            current = ""
        }

        for character in text {
            current.append(character)
            if terminators.contains(character) || current.count >= maxSegmentCharacters {
                commit()
            }
        }
        commit()
        return pieces
    }

    static func errorMessage(in json: [String: Any]) -> String? {
        if let errors = json["errors"] as? [[String: Any]],
           let first = errors.first {
            return first["message"] as? String ?? "Gemini transcription failed"
        }
        if let error = json["error"] as? [String: Any] {
            return error["message"] as? String ?? "Gemini transcription failed"
        }
        switch json["status"] as? String {
        case "failed", "cancelled", "incomplete", "budget_exceeded":
            return "Gemini transcription \(json["status"] as? String ?? "failed")"
        case "in_progress", "queued", "requires_action":
            // Cadenza never sets background or stream, so a non-terminal
            // status means the API changed its synchronous contract. Say so
            // instead of reporting an empty transcript.
            return "Gemini transcription did not finish synchronously"
        default:
            return nil
        }
    }

    static func outputText(in json: [String: Any]) -> String? {
        if let text = (json["output_text"] ?? json["outputText"]) as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        // `output_text` is an SDK convenience field; over raw REST the text
        // may only exist inside the steps.
        let joined = textContents(in: json)
            .compactMap { $0["text"] as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return joined.isEmpty ? nil : joined
    }

    /// Every content object in `steps[].content[]` that carries text and/or
    /// annotations, in document order.
    private static func textContents(in json: [String: Any]) -> [[String: Any]] {
        guard let steps = json["steps"] as? [[String: Any]] else { return [] }
        return steps.flatMap { step -> [[String: Any]] in
            (step["content"] as? [[String: Any]]) ?? []
        }
    }

    static func extractWords(from json: [String: Any]) -> [Word] {
        textContents(in: json).flatMap { content -> [Word] in
            guard let annotations = content["annotations"] as? [[String: Any]] else { return [] }
            return annotations.compactMap(word(from:))
        }
    }

    private static func word(from annotation: [String: Any]) -> Word? {
        let type = (annotation["type"] as? String)?.lowercased()
        guard type == nil || type == "word_info" || type == "wordinfo" else { return nil }
        guard let raw = annotation["text"] as? String else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return Word(
            text: text,
            start: duration(annotation["start_offset"] ?? annotation["startOffset"]),
            end: duration(annotation["end_offset"] ?? annotation["endOffset"]),
            speaker: speakerLabel(annotation["speaker"] as? String)
        )
    }

    /// protobuf `Duration` reaches JSON as a string of seconds with a trailing
    /// `s` ("12.500s"). Numbers are accepted too so a plain-JSON encoder on
    /// the other side cannot break timing.
    static func duration(_ value: Any?) -> TimeInterval? {
        if let number = value as? NSNumber { return number.doubleValue }
        guard let string = value as? String else { return nil }
        let trimmed = string.hasSuffix("s") ? String(string.dropLast()) : string
        return TimeInterval(trimmed)
    }

    /// `spk_1` is the wire label; "Speaker 1" is what the rest of Cadenza
    /// (SpeakerDiarizer, SpeakerLabelFormatter, speaker memory) speaks.
    static func speakerLabel(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lowered = trimmed.lowercased()
        for prefix in ["spk_", "spk", "speaker_"] where lowered.hasPrefix(prefix) {
            let index = lowered.dropFirst(prefix.count)
            if !index.isEmpty, index.allSatisfy(\.isNumber) {
                return "Speaker \(Int(index) ?? 0)"
            }
        }
        return trimmed
    }

    // MARK: - Segmentation

    static func buildSegments(from words: [Word]) -> [TranscriptResultSegment] {
        var segments: [TranscriptResultSegment] = []
        var text = ""
        var speaker: String?
        var start: TimeInterval = 0
        var end: TimeInterval = 0
        var open = false

        func flush() {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard open, !trimmed.isEmpty else { return }
            segments.append(TranscriptResultSegment(
                startTime: start,
                endTime: max(start, end),
                text: trimmed,
                speaker: speaker
            ))
        }

        for word in words {
            let wordStart = word.start ?? end
            let wordEnd = word.end ?? wordStart

            if open {
                let speakerChanged = word.speaker != speaker
                let gap = wordStart - end
                let tooLong = (wordEnd - start) > maxSegmentDuration
                    || text.count >= maxSegmentCharacters
                if speakerChanged || gap >= segmentSilenceGap || tooLong {
                    flush()
                    open = false
                }
            }

            if !open {
                text = ""
                speaker = word.speaker
                start = wordStart
                open = true
            }
            text = appending(word.text, to: text)
            end = max(end, wordEnd)
        }
        flush()
        return segments
    }

    /// Join words without inventing spaces inside scripts that do not use
    /// them. Chinese, Japanese and Thai run words together; Korean does not,
    /// so Hangul is deliberately absent from the no-space set.
    static func appending(_ word: String, to text: String) -> String {
        guard !text.isEmpty else { return word }
        guard let previous = text.unicodeScalars.last,
              let next = word.unicodeScalars.first else { return text + word }
        return needsSpace(after: previous, before: next) ? text + " " + word : text + word
    }

    static func needsSpace(after previous: Unicode.Scalar, before next: Unicode.Scalar) -> Bool {
        if previous == " " { return false }
        if isScriptWithoutWordSpaces(previous) || isScriptWithoutWordSpaces(next) { return false }
        // ASCII punctuation that hugs the word it follows or precedes.
        if ",.!?;:%)]}".unicodeScalars.contains(next) { return false }
        if "([{".unicodeScalars.contains(previous) { return false }
        if next == "'" || previous == "'" { return false }
        return true
    }

    private static func isScriptWithoutWordSpaces(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3000...0x303F,   // CJK symbols and punctuation
             0x3040...0x30FF,   // Hiragana, Katakana
             0x3400...0x4DBF,   // CJK Unified Ideographs Extension A
             0x4E00...0x9FFF,   // CJK Unified Ideographs
             0xF900...0xFAFF,   // CJK Compatibility Ideographs
             0xFF00...0xFF65,   // Full-width forms (excludes half-width kana)
             0x20000...0x2FA1F, // CJK Extensions B-F
             0x0E00...0x0E7F:   // Thai
            return true
        default:
            return false
        }
    }
}
