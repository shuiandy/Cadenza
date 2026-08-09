import CryptoKit
import Foundation

enum ExternalRecordingFingerprint {
    static func source(_ input: ExternalRecordingUpsertInput) -> String {
        var values: [String] = [
            input.title,
            date(input.startDate),
            optionalDate(input.endDate),
            number(input.duration),
            input.language,
            input.meetingApp ?? "",
            input.meetingURL ?? "",
            input.calendarEventID ?? "",
        ]
        values.append(contentsOf: input.tags.sorted())
        append(input.transcript, to: &values)
        append(input.summary, to: &values)
        return hash(values)
    }

    static func local(_ recording: Recording) -> String {
        var values: [String] = [
            recording.title,
            date(recording.startDate),
            optionalDate(recording.endDate),
            number(recording.duration),
            recording.language,
            recording.meetingApp ?? "",
            recording.meetingURL ?? "",
            recording.linkedCalendarEventID ?? "",
            optionalDate(recording.trashedDate),
        ]
        values.append(contentsOf: recording.tags.sorted())
        if let transcript = recording.transcript {
            values.append("transcript")
            values.append(transcript.fullText)
            values.append(transcript.detectedLanguage ?? "")
            for segment in transcript.segments {
                values.append(number(segment.startTime))
                values.append(number(segment.endTime))
                values.append(segment.text)
                values.append(segment.speaker ?? "")
            }
        } else {
            values.append("no-transcript")
        }
        if let summary = recording.summary {
            values.append("summary")
            values.append(summary.overview)
            values.append(contentsOf: summary.keyPoints)
            values.append(contentsOf: summary.decisions)
            values.append(contentsOf: summary.followUps)
            values.append(contentsOf: summary.yourTasks)
            values.append(summary.language)
            for item in summary.actionItems {
                values.append(item.assignee ?? "")
                values.append(item.task)
                values.append(item.deadline ?? "")
                values.append(item.isCompleted ? "1" : "0")
                values.append(item.priority.rawValue)
            }
        } else {
            values.append("no-summary")
        }
        for mapping in (recording.speakerMappings ?? []).sorted(by: {
            $0.rawLabel == $1.rawLabel
                ? $0.profileID.uuidString < $1.profileID.uuidString
                : $0.rawLabel < $1.rawLabel
        }) {
            values.append(mapping.rawLabel)
            values.append(mapping.profileID.uuidString)
        }
        return hash(values)
    }

    static func transcript(_ text: String) -> String {
        data(Data(text.utf8))
    }

    static func data(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func normalizedSHA256(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.count == 64,
              normalized.allSatisfy(\.isHexDigit) else { return nil }
        return normalized
    }

    private static func append(_ transcript: ExternalTranscriptInput?, to values: inout [String]) {
        guard let transcript else {
            values.append("no-transcript")
            return
        }
        values.append("transcript")
        values.append(transcript.fullText)
        values.append(transcript.detectedLanguage ?? "")
        for segment in transcript.segments {
            values.append(number(segment.startTime))
            values.append(number(segment.endTime))
            values.append(segment.text)
            values.append(segment.speaker ?? "")
        }
    }

    private static func append(_ summary: ExternalSummaryInput?, to values: inout [String]) {
        guard let summary else {
            values.append("no-summary")
            return
        }
        values.append("summary")
        values.append(summary.overview)
        values.append(contentsOf: summary.keyPoints)
        values.append(contentsOf: summary.decisions)
        values.append(contentsOf: summary.followUps)
        values.append(contentsOf: summary.yourTasks)
        values.append(summary.language)
        for item in summary.actionItems {
            values.append(item.assignee ?? "")
            values.append(item.task)
            values.append(item.deadline ?? "")
            values.append(item.isCompleted ? "1" : "0")
            values.append(item.priority.rawValue)
        }
    }

    private static func hash(_ values: [String]) -> String {
        var data = Data()
        for value in values {
            let bytes = Data(value.utf8)
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
            data.append(bytes)
        }
        return self.data(data)
    }

    private static func date(_ value: Date) -> String {
        String(value.timeIntervalSinceReferenceDate.bitPattern)
    }

    private static func optionalDate(_ value: Date?) -> String {
        value.map(date) ?? ""
    }

    private static func number(_ value: Double) -> String {
        String(value.bitPattern)
    }
}

enum ExternalImportQualityEvaluator {
    static func signals(for input: ExternalRecordingPreviewInput) -> [ExternalImportQualitySignal] {
        var signals: [ExternalImportQualitySignal] = []
        if input.transcriptCharacterCount == 0 {
            signals.append(.noTranscript)
        }
        if input.transcriptCharacterCount == 0,
           input.transcriptSegmentCount == 0,
           !input.hasSummary,
           input.actionItemCount == 0 {
            signals.append(.likelyEmpty)
        }
        if input.duration > 0, input.duration < 30 {
            signals.append(.shortDuration)
        }
        let title = input.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let testTerms = [
            "test", "testing", "mic check", "microphone check", "dummy", "sample", "empty recording",
            "测试", "试音", "麦克风测试", "空录音",
        ]
        if testTerms.contains(where: { title.localizedCaseInsensitiveContains($0) }) {
            signals.append(.likelyTest)
        }
        return signals
    }
}
