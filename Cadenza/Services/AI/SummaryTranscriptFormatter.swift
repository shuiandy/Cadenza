import Foundation

/// Builds the canonical transcript input used by meeting-summary providers.
/// Speaker boundaries must survive provider selection and map-reduce chunking.
enum SummaryTranscriptFormatter {
    private struct Segment {
        let startTime: TimeInterval
        let endTime: TimeInterval
        let text: String
        let speaker: String?
    }

    private struct TailTrimResult {
        let segments: [Segment]
        let logicalEndTime: TimeInterval?
    }

    private enum ClosingCueStrength {
        case strong
        case weak
    }

    private struct SegmentAnalysis {
        let identity: String?
        let closingStrength: ClosingCueStrength?
        let substantiveCharacters: Int
        let isSubstantive: Bool
        let hasContinuationCue: Bool
        let duration: TimeInterval
    }

    private static let maximumFarewellExchangeGap: TimeInterval = 30
    private static let minimumMeetingDurationBeforeFarewell: TimeInterval = 60
    private static let minimumExcludedTailDuration: TimeInterval = 45

    static func format(
        fullText: String,
        segments: [TranscriptEntry],
        speakerNames: [String: String] = [:]
    ) -> String {
        format(
            fullText: fullText,
            segments: segments.map {
                Segment(
                    startTime: $0.startTime,
                    endTime: $0.endTime,
                    text: $0.text,
                    speaker: $0.speaker
                )
            },
            speakerNames: speakerNames
        )
    }

    static func format(
        fullText: String,
        segments: [TranscriptEntry],
        speakerMappings: [SpeakerLabelMappingDTO]
    ) -> String {
        format(
            fullText: fullText,
            segments: segments,
            speakerNames: speakerNames(from: speakerMappings)
        )
    }

    static func format(
        fullText: String,
        segments: [TranscriptEntryDTO],
        speakerMappings: [SpeakerLabelMappingDTO]
    ) -> String {
        return format(
            fullText: fullText,
            segments: segments.map {
                Segment(
                    startTime: $0.startTime,
                    endTime: $0.endTime,
                    text: $0.text,
                    speaker: $0.speaker
                )
            },
            speakerNames: speakerNames(from: speakerMappings)
        )
    }

    private static func format(
        fullText: String,
        segments: [Segment],
        speakerNames: [String: String]
    ) -> String {
        let meaningfulSegments = segments.compactMap { segment -> Segment? in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return Segment(
                startTime: segment.startTime,
                endTime: segment.endTime,
                text: text,
                speaker: segment.speaker
            )
        }

        let hasSpeakerLabels = meaningfulSegments.contains { segment in
            guard let speaker = segment.speaker else { return false }
            return !normalizedIdentity(speaker).isEmpty
        }
        guard hasSpeakerLabels else {
            let fallback = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !fallback.isEmpty { return fallback }
            return meaningfulSegments.map(\.text).joined(separator: " ")
        }

        let tailTrim = trimPostMeetingTail(
            from: meaningfulSegments,
            speakerNames: speakerNames
        )
        let summarySegments = tailTrim.segments

        var orderedLabels: [String] = []
        var seenLabels = Set<String>()
        var containsUnlabeledSegment = false
        for segment in summarySegments {
            let label = segment.speaker.map(normalizedIdentity(_:)) ?? ""
            if label.isEmpty {
                containsUnlabeledSegment = true
            } else if seenLabels.insert(label).inserted {
                orderedLabels.append(label)
            }
        }

        var roster = orderedLabels.map { label in
            if let name = speakerNames[label], !name.isEmpty {
                return "\(label)=\(name)"
            }
            return "\(label)=?"
        }
        if containsUnlabeledSegment {
            roster.append("Unknown=?")
        }

        let turns = summarySegments.map { segment in
            let rawLabel = segment.speaker.map(normalizedIdentity(_:)) ?? ""
            let speaker = rawLabel.isEmpty ? "Unknown" : rawLabel
            let start = formatOffset(segment.startTime)
            return "[\(start)] \(speaker): \(segment.text)"
        }

        var context = """
        Speaker labels are stable diarization tokens; roster mappings are authoritative, while ? means unidentified. Multiple raw labels can map to the same real person.
        Speaker roster (raw=mapped): \(roster.joined(separator: "; "))
        """
        if let logicalEndTime = tailTrim.logicalEndTime {
            context += "\nMeeting content boundary: a reciprocal farewell ended the meeting at [\(formatOffset(logicalEndTime))]; later captured audio was excluded."
        }

        return """
        \(context)

        Transcript turns:
        \(turns.joined(separator: "\n\n"))
        """
    }

    /// Conservatively removes a material capture tail after a two-person
    /// meeting has an explicit reciprocal farewell. Requiring exactly two
    /// canonical identities avoids treating one participant leaving a group
    /// meeting as the end. Confirmed mappings collapse diarizer label drift
    /// (for example B...F all mapping to the same person) before that check.
    private static func trimPostMeetingTail(
        from segments: [Segment],
        speakerNames: [String: String]
    ) -> TailTrimResult {
        guard segments.count >= 3 else {
            return TailTrimResult(segments: segments, logicalEndTime: nil)
        }

        let analyses = segments.map { segment in
            let closingStrength = closingCueStrength(in: segment.text)
            let substantiveCharacters = substantiveCharacterCount(segment.text)
            return SegmentAnalysis(
                identity: canonicalIdentity(for: segment, speakerNames: speakerNames),
                closingStrength: closingStrength,
                substantiveCharacters: substantiveCharacters,
                isSubstantive: closingStrength == nil && substantiveCharacters >= 12,
                hasContinuationCue: continuationCue(in: segment.text),
                duration: max(0, segment.endTime - segment.startTime)
            )
        }
        let identities = analyses.map(\.identity)
        let canonicalIdentities = Set(identities.compactMap { $0 })
        let isChronological = zip(segments, segments.dropFirst()).allSatisfy { pair in
            pair.0.startTime <= pair.1.startTime
        }
        guard identities.allSatisfy({ $0 != nil }),
              canonicalIdentities.count == 2,
              isChronological,
              let firstStart = segments.first?.startTime,
              let lastEnd = segments.map({ max($0.startTime, $0.endTime) }).max()
        else {
            return TailTrimResult(segments: segments, logicalEndTime: nil)
        }

        var candidateIndices: [Int] = []

        for currentIndex in segments.indices {
            let current = segments[currentIndex]
            guard current.startTime - firstStart >= minimumMeetingDurationBeforeFarewell,
                  analyses[currentIndex].closingStrength == .strong
            else { continue }

            let windowStart = current.startTime - maximumFarewellExchangeGap
            var closingIndices: [Int] = []
            var index = currentIndex
            while true {
                let segment = segments[index]
                if max(segment.startTime, segment.endTime) < windowStart { break }
                if analyses[index].closingStrength != nil {
                    closingIndices.append(index)
                }
                if index == segments.startIndex { break }
                index -= 1
            }
            let strongIdentities = Set(closingIndices.compactMap { index -> String? in
                guard analyses[index].closingStrength == .strong else { return nil }
                return identities[index]
            })
            if closingIndices.count >= 3,
               strongIdentities == canonicalIdentities {
                candidateIndices.append(currentIndex)
            }
        }

        var clusterBoundaries: [Int] = []
        for candidateIndex in candidateIndices {
            let hasSubstantiveTurnSinceLastCandidate: Bool
            if let lastIndex = clusterBoundaries.last, lastIndex + 1 < candidateIndex {
                hasSubstantiveTurnSinceLastCandidate = analyses[(lastIndex + 1)..<candidateIndex]
                    .contains(where: \.isSubstantive)
            } else {
                hasSubstantiveTurnSinceLastCandidate = false
            }
            if let lastIndex = clusterBoundaries.last,
               segments[candidateIndex].startTime
                - max(segments[lastIndex].startTime, segments[lastIndex].endTime)
                <= maximumFarewellExchangeGap,
               !hasSubstantiveTurnSinceLastCandidate {
                clusterBoundaries[clusterBoundaries.count - 1] = candidateIndex
            } else {
                clusterBoundaries.append(candidateIndex)
            }
        }

        for boundaryIndex in clusterBoundaries {
            guard boundaryIndex + 1 < segments.count else { continue }
            let boundary = segments[boundaryIndex]
            guard lastEnd - max(boundary.startTime, boundary.endTime)
                    >= minimumExcludedTailDuration,
                  !hasCredibleMeetingContinuation(
                    after: boundaryIndex,
                    segments: segments,
                    analyses: analyses,
                    canonicalIdentities: canonicalIdentities
                  )
            else { continue }

            return TailTrimResult(
                segments: Array(segments[...boundaryIndex]),
                logicalEndTime: max(boundary.startTime, boundary.endTime)
            )
        }
        return TailTrimResult(segments: segments, logicalEndTime: nil)
    }

    private static func canonicalIdentity(
        for segment: Segment,
        speakerNames: [String: String]
    ) -> String? {
        guard let speaker = segment.speaker else { return nil }
        let rawLabel = normalizedIdentity(speaker)
        guard !rawLabel.isEmpty else { return nil }
        let mappedName = speakerNames[rawLabel].map(normalizedIdentity(_:)) ?? ""
        let identity = mappedName.isEmpty ? rawLabel : mappedName
        return identity.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    /// Classifies only short, nearly pure closing turns. A sentence such as
    /// "say goodbye to the old API and continue" must not become a boundary.
    private static func closingCueStrength(in text: String) -> ClosingCueStrength? {
        let strongEnglishPattern = #"\b(?:good[\s-]?bye|bye(?:[\s-]?bye)?|see\s+you(?:\s+(?:soon|later))?|talk\s+to\s+you\s+later|take\s+care|have\s+a\s+(?:nice|good|great)\s+(?:day|evening|night|weekend)|good\s*night)\b"#
        if isNearlyPureCue(text, pattern: strongEnglishPattern, maximumSemanticTokens: 1)
            || isNearlyPureChineseClosingCue(text) {
            return .strong
        }

        let weakPattern = #"\b(?:thanks?|thank\s+you|no\s+problem|nice\s+(?:talking|speaking)(?:\s+to\s+you)?|that(?:'s|\s+is)\s+it)\b|(?:谢谢|感谢|辛苦了|就这样)"#
        if isNearlyPureCue(text, pattern: weakPattern, maximumSemanticTokens: 2) {
            return .weak
        }
        return nil
    }

    /// Chinese closing phrases are common verbs inside an otherwise substantive
    /// sentence (for example, "下次见客户时再讨论"). Match the entire compacted
    /// utterance instead of looking for a closing substring, so only an actual
    /// farewell with a small set of conversational fillers is destructive.
    private static func isNearlyPureChineseClosingCue(_ text: String) -> Bool {
        let compact = text.unicodeScalars.compactMap { scalar -> String? in
            CharacterSet.alphanumerics.contains(scalar) ? String(scalar) : nil
        }.joined()
        guard !compact.isEmpty, compact.count <= 40 else { return false }

        let filler = #"(?:好(?:的)?|嗯+|那|那么|谢谢你|谢谢|感谢|大家|你也|我们|啊+|吧|哦+|行|可以|就|先|这样)"#
        let cue = #"(?:再见|拜拜|回头见|下次见|保重)"#
        let pattern = "^(?:\(filler))*(?:\(cue))(?:(?:\(filler))|(?:\(cue)))*$"
        return compact.range(of: pattern, options: .regularExpression) != nil
    }

    private static func isNearlyPureCue(
        _ text: String,
        pattern: String,
        maximumSemanticTokens: Int
    ) -> Bool {
        let folded = text.folding(
            options: [.diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).lowercased()
        guard folded.count <= 120,
              folded.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        else { return false }

        let remainder = folded.replacingOccurrences(
            of: pattern,
            with: " ",
            options: [.regularExpression, .caseInsensitive]
        )
        let normalizedRemainder = remainder.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : " "
        }
        let tokens = String(normalizedRemainder).split(whereSeparator: \.isWhitespace)
        let fillerWords: Set<Substring> = [
            "a", "all", "alright", "and", "course", "everyone", "finally",
            "it", "lot", "me", "nothing", "of", "ok", "okay", "right",
            "same", "sure", "thank", "thanks", "that", "the", "then", "too",
            "uh", "um", "well", "yeah", "yep", "yes", "you",
        ]
        let semanticTokens = tokens.filter { !fillerWords.contains($0) }
        let disallowedCueWords: Set<Substring> = [
            "say", "saying", "said", "discuss", "discussed", "review", "continue",
        ]
        return semanticTokens.allSatisfy { !disallowedCueWords.contains($0) }
            && semanticTokens.count <= maximumSemanticTokens
            && semanticTokens.joined().count <= 24
    }

    private static func hasCredibleMeetingContinuation(
        after boundaryIndex: Int,
        segments: [Segment],
        analyses: [SegmentAnalysis],
        canonicalIdentities: Set<String>
    ) -> Bool {
        let suffixStartIndex = boundaryIndex + 1
        guard suffixStartIndex < segments.count else { return false }
        let suffixStartTime = segments[suffixStartIndex].startTime
        var immediateIdentities = Set<String>()
        var pendingContinuationCues: [(identity: String, endTime: TimeInterval)] = []

        for index in suffixStartIndex..<segments.count {
            let segment = segments[index]
            if segment.startTime - suffixStartTime > 90 { break }
            let analysis = analyses[index]
            guard let identity = analysis.identity else { continue }

            pendingContinuationCues.removeAll {
                segment.startTime - $0.endTime > 30
            }
            if analysis.isSubstantive {
                immediateIdentities.insert(identity)
                if pendingContinuationCues.contains(where: { $0.identity != identity }) {
                    return true
                }
            }
            if analysis.hasContinuationCue {
                pendingContinuationCues.append((
                    identity: identity,
                    endTime: max(segment.startTime, segment.endTime)
                ))
            }
        }
        if immediateIdentities == canonicalIdentities {
            return true
        }

        let substantiveIndices = (suffixStartIndex..<segments.count).filter {
            analyses[$0].isSubstantive && analyses[$0].identity != nil
        }
        guard substantiveIndices.count >= 4 else { return false }

        var transitionPrefix = Array(repeating: 0, count: substantiveIndices.count + 1)
        for index in 1..<substantiveIndices.count {
            transitionPrefix[index + 1] = transitionPrefix[index]
                + (analyses[substantiveIndices[index - 1]].identity
                    == analyses[substantiveIndices[index]].identity ? 0 : 1)
        }

        var stats: [String: (turns: Int, duration: TimeInterval, characters: Int)] = [:]
        var left = 0
        for right in substantiveIndices.indices {
            let rightIndex = substantiveIndices[right]
            guard let rightIdentity = analyses[rightIndex].identity else { continue }
            var added = stats[rightIdentity] ?? (0, 0, 0)
            added.turns += 1
            added.duration += analyses[rightIndex].duration
            added.characters += analyses[rightIndex].substantiveCharacters
            stats[rightIdentity] = added

            while segments[rightIndex].startTime - segments[substantiveIndices[left]].startTime > 120 {
                let removedIndex = substantiveIndices[left]
                if let removedIdentity = analyses[removedIndex].identity,
                   var removed = stats[removedIdentity] {
                    removed.turns -= 1
                    removed.duration -= analyses[removedIndex].duration
                    removed.characters -= analyses[removedIndex].substantiveCharacters
                    if removed.turns == 0 {
                        stats.removeValue(forKey: removedIdentity)
                    } else {
                        stats[removedIdentity] = removed
                    }
                }
                left += 1
            }

            let transitions = transitionPrefix[right + 1] - transitionPrefix[left + 1]
            if Set(stats.keys) == canonicalIdentities,
               transitions >= 2,
               stats.values.allSatisfy({ value in
                   value.turns >= 2 && (value.duration >= 10 || value.characters >= 24)
               }) {
                return true
            }
        }
        return false
    }

    private static func continuationCue(in text: String) -> Bool {
        let pattern = #"\b(?:wait|one\s+more\s+thing|before\s+you\s+go|i\s+forgot)\b|(?:对了|还有|等一下|等等)"#
        return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func substantiveCharacterCount(_ text: String) -> Int {
        text.unicodeScalars.reduce(into: 0) { count, scalar in
            if CharacterSet.alphanumerics.contains(scalar) {
                count += 1
            }
        }
    }

    private static func normalizedIdentity(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func speakerNames(
        from speakerMappings: [SpeakerLabelMappingDTO]
    ) -> [String: String] {
        var speakerNames: [String: String] = [:]
        for mapping in speakerMappings {
            let rawLabel = normalizedIdentity(mapping.rawLabel)
            let profileName = normalizedIdentity(mapping.profileName)
            guard !rawLabel.isEmpty, !profileName.isEmpty, speakerNames[rawLabel] == nil else { continue }
            speakerNames[rawLabel] = profileName
        }
        return speakerNames
    }

    private static func formatOffset(_ seconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int(seconds.rounded(.down)))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let remainingSeconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, remainingSeconds)
        }
        return String(format: "%02d:%02d", minutes, remainingSeconds)
    }
}
