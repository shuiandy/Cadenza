import Foundation

// MARK: - Time Range

enum TimeRange: Equatable, Sendable {
    case today
    case yesterday
    case thisWeek
    case lastWeek
    case last7Days
    case last30Days
    /// No date filter — search the entire library. The context token budget
    /// still bounds how much actually ships (newest recordings first).
    case allTime
    case custom(start: Date, end: Date)
}

// MARK: - Query Intent

struct QueryIntent: Sendable {
    var timeRange: TimeRange?
    var speakerQueries: [String]
    var keywords: [String]
    var mentionedRecordingIDs: [UUID]
    var meetingType: MeetingType?
    var prefersMostRecentRecording: Bool
}

// MARK: - Query Analyzer

enum QueryAnalyzer {

    // MARK: - Public API

    static func analyze(
        _ question: String,
        knownSpeakers: [SpeakerNameInfo],
        mentionedRecordingIDs: [UUID] = []
    ) -> QueryIntent {
        var intent = QueryIntent(
            timeRange: nil,
            speakerQueries: [],
            keywords: [],
            mentionedRecordingIDs: mentionedRecordingIDs,
            meetingType: extractMeetingType(from: question),
            prefersMostRecentRecording: prefersMostRecentRecording(from: question)
        )
        intent.timeRange = extractTimeRange(from: question)
        intent.speakerQueries = extractSpeakers(from: question, knownSpeakers: knownSpeakers)
        intent.keywords = extractKeywords(from: question, knownSpeakers: knownSpeakers)
        return intent
    }

    /// Whether a short question naturally refers back to the recording already
    /// established by earlier turns. Retrieval uses this to preserve the
    /// concrete recording scope without re-tokenizing the entire conversation.
    static func isContextualFollowUp(_ question: String) -> Bool {
        let lower = question.lowercased()
        let patterns = [
            #"^\s*(what|how) about\b"#,
            #"\b(more detail|more details|go deeper|this meeting|that meeting|the transcript|exact quote|original words)\b"#,
            #"^\s*(那|那么|还有|继续|现在呢|然后呢)"#,
            #"(详细|具体点|展开说说|这场|这个会议|刚才|上面|原话|原文|逐字稿|完整.{0,3}transcript|看到.{0,3}transcript|看不到.{0,3}transcript)"#,
        ]
        return patterns.contains { lower.range(of: $0, options: .regularExpression) != nil }
    }

    /// Whether the question explicitly points back to the recording already
    /// established by the conversation. This is stronger than a generic
    /// follow-up such as "what about JY?": an explicit "in this meeting"
    /// should keep the concrete recording even when it introduces a speaker
    /// who was not named in the original query.
    static func explicitlyReferencesCurrentRecording(_ question: String) -> Bool {
        let lower = question.lowercased()
        let patterns = [
            #"\b(this|that|the)\s+(meeting|recording|transcript|conversation)\b"#,
            #"(这场|那场|这次|那次|这个|那个|该)(会议|录音|对话|逐字稿)"#,
        ]
        return patterns.contains { lower.range(of: $0, options: .regularExpression) != nil }
    }

    // MARK: - Cached Regex

    private static let speakerLabelRegex = try? NSRegularExpression(pattern: "\\bSpeaker \\d+\\b", options: .caseInsensitive)

    private static let mostRecentPatterns = [
        #"\b(latest|most recent)\b"#,
        #"\b(last|previous)\s+(meeting|recording|1\s*[: -]\s*1|1\s*(?:-\s*)?on(?:\s*-)?\s*1|one[- ]on[- ]one)\b"#,
        #"(上次|最近一次|最新一次|上一场)"#,
    ]

    private static let oneOnOnePatterns = [
        #"1\s*[: -]\s*1"#,
        #"1\s*(?:-\s*)?on(?:\s*-)?\s*1"#,
        #"\bone[- ]on[- ]one\b"#,
        #"(一对一|1对1)"#,
    ]

    private static func prefersMostRecentRecording(from question: String) -> Bool {
        let lower = question.lowercased()
        return mostRecentPatterns.contains {
            lower.range(of: $0, options: .regularExpression) != nil
        }
    }

    private static func extractMeetingType(from question: String) -> MeetingType? {
        let lower = question.lowercased()
        if oneOnOnePatterns.contains(where: {
            lower.range(of: $0, options: .regularExpression) != nil
        }) {
            return .oneOnOne
        }
        return nil
    }

    // MARK: - Time Range Extraction

    private static let timePatterns: [(pattern: String, range: TimeRange)] = [
        ("\\btoday\\b", .today),
        ("\\byesterday\\b", .yesterday),
        ("\\bthis week\\b", .thisWeek),
        ("\\blast week\\b", .lastWeek),
        ("\\bpast (7|seven) days\\b", .last7Days),
        ("\\blast (7|seven) days\\b", .last7Days),
        ("\\bpast (30|thirty) days\\b", .last30Days),
        ("\\blast (30|thirty) days\\b", .last30Days),
        ("\\blast month\\b", .last30Days),
        ("\\ball[ -]time\\b", .allTime),
        ("\\bever\\b", .allTime),
        ("\\ball (of )?(my )?(recordings|meetings|history)\\b", .allTime),
        ("\\bentire history\\b", .allTime),
        ("今天", .today),
        ("昨天", .yesterday),
        ("这周|这个星期|本周", .thisWeek),
        ("上周|上个星期|上星期", .lastWeek),
        ("最近[七7]天", .last7Days),
        ("最近三十天|最近30天|这个月|上个月", .last30Days),
        ("所有录音|全部录音|所有会议|全部会议|所有时间|有史以来|历史上", .allTime),
    ]

    private static func extractTimeRange(from question: String) -> TimeRange? {
        let lower = question.lowercased()
        for (pattern, range) in timePatterns {
            if lower.range(of: pattern, options: .regularExpression) != nil {
                return range
            }
        }
        return nil
    }

    // MARK: - Speaker Extraction

    private static func extractSpeakers(
        from question: String,
        knownSpeakers: [SpeakerNameInfo]
    ) -> [String] {
        var matched: [String] = []

        for speaker in knownSpeakers {
            let allNames = [speaker.displayName] + speaker.aliases
            for name in allNames where !name.isEmpty {
                if question.localizedCaseInsensitiveContains(name) {
                    if !matched.contains(speaker.displayName) {
                        matched.append(speaker.displayName)
                    }
                    break
                }
            }
        }

        // Match raw "Speaker N" labels
        if let regex = speakerLabelRegex {
            let nsRange = NSRange(question.startIndex..., in: question)
            let matches = regex.matches(in: question, range: nsRange)
            for match in matches {
                if let range = Range(match.range, in: question) {
                    let label = String(question[range])
                    if !matched.contains(label) {
                        matched.append(label)
                    }
                }
            }
        }

        return matched
    }

    // MARK: - Keyword Extraction

    private static let stopwords: Set<String> = [
        // English
        "the", "a", "an", "is", "are", "was", "were", "what", "who", "how", "when", "where",
        "did", "do", "does", "about", "tell", "me", "can", "you", "please", "said", "say",
        "something", "anything", "mentioned", "happened", "discuss", "discussed", "meeting",
        "in", "on", "at", "to", "for", "of", "with", "from", "by",
        // Chinese
        "的", "了", "吗", "呢", "是", "在", "有", "什么", "哪些", "怎么", "关于", "说",
        "跟", "和", "与", "把", "被", "让", "给", "对", "从", "到",
    ]

    private static let cjkRange = CharacterSet(charactersIn: "\u{4E00}"..."\u{9FFF}")

    private static func extractKeywords(
        from question: String,
        knownSpeakers: [SpeakerNameInfo]
    ) -> [String] {
        var cleaned = question

        // Remove known speaker names
        for speaker in knownSpeakers {
            for name in [speaker.displayName] + speaker.aliases where !name.isEmpty {
                cleaned = cleaned.replacingOccurrences(of: name, with: "", options: .caseInsensitive)
            }
        }

        // Remove time patterns
        for (pattern, _) in timePatterns {
            cleaned = cleaned.replacingOccurrences(
                of: pattern, with: "", options: [.regularExpression, .caseInsensitive]
            )
        }

        // Recording selectors drive recording-level resolution and should not
        // also become noisy transcript keywords.
        for pattern in mostRecentPatterns + oneOnOnePatterns {
            cleaned = cleaned.replacingOccurrences(
                of: pattern, with: "", options: [.regularExpression, .caseInsensitive]
            )
        }

        var tokens: [String] = []
        var cjkRun = ""
        var latinRun = ""

        func flushCJK() {
            guard !cjkRun.isEmpty else { return }
            let chars = Array(cjkRun)
            if chars.count >= 2 {
                for i in 0..<(chars.count - 1) {
                    let bigram = String(chars[i]) + String(chars[i + 1])
                    if !stopwords.contains(bigram) { tokens.append(bigram) }
                }
            } else if !stopwords.contains(cjkRun) {
                tokens.append(cjkRun)
            }
            cjkRun = ""
        }

        func flushLatin() {
            guard !latinRun.isEmpty else { return }
            let lower = latinRun.lowercased()
            if !stopwords.contains(lower) && lower.count > 1 {
                tokens.append(latinRun)
            }
            latinRun = ""
        }

        for scalar in cleaned.unicodeScalars {
            if cjkRange.contains(scalar) {
                flushLatin()
                cjkRun.unicodeScalars.append(scalar)
            } else if CharacterSet.alphanumerics.contains(scalar) {
                flushCJK()
                latinRun.unicodeScalars.append(scalar)
            } else {
                flushCJK()
                flushLatin()
            }
        }
        flushCJK()
        flushLatin()

        return Array(Set(tokens))
    }
}
