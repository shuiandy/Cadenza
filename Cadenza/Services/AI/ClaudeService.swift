import Foundation

/// Anthropic Claude API for meeting summarization.
final class ClaudeService: AIServiceProtocol {
    let provider: AIProvider = .claude
    private let apiKey: String
    private let baseURL = "https://api.anthropic.com/v1/messages"
    private let transport: HardenedAITransport

    init(apiKey: String, transport: HardenedAITransport = .shared) {
        self.apiKey = apiKey
        self.transport = transport
    }

    func summarize(transcript: String, language: String, model: String?, jobTitle: String? = nil, meetingType: MeetingType? = nil, meetingTitle: String? = nil, knownTags: [String], detailLevel: SummaryDetailLevel = SummaryDetailLevel.load()) async throws -> SummaryResult {
        let modelID = model ?? provider.summaryModel
        let systemPrompt = SummaryPrompt.system(language: language, jobTitle: jobTitle, meetingType: meetingType, meetingTitle: meetingTitle, knownTags: knownTags, detailLevel: detailLevel)

        var body: [String: Any] = [
            "model": modelID,
            "max_tokens": Self.summaryOutputBudget(model: modelID, detailLevel: detailLevel),
            "system": Self.cacheableSystem(systemPrompt),
            "messages": [
                ["role": "user", "content": SummaryPrompt.user(transcript: transcript)]
            ]
        ]
        body.merge(Self.thinkingFields(model: modelID, effort: Self.summaryEffort)) { _, new in new }

        let data = try await postJSON(body)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let textBlock = content.first(where: { ($0["type"] as? String) == "text" }),
              let text = textBlock["text"] as? String else {
            throw AIServiceError.invalidResponse
        }

        try Self.validateStopReason(json["stop_reason"] as? String)
        return SummaryPrompt.parseResponse(text)
    }

    func streamSummarize(transcript: String, language: String, model: String?, jobTitle: String? = nil, meetingType: MeetingType? = nil, meetingTitle: String? = nil, knownTags: [String], detailLevel: SummaryDetailLevel = SummaryDetailLevel.load()) -> AsyncThrowingStream<String, Error> {
        streamSummaryCompletion(
            systemPrompt: SummaryPrompt.system(language: language, jobTitle: jobTitle, meetingType: meetingType, meetingTitle: meetingTitle, knownTags: knownTags, detailLevel: detailLevel),
            userMessage: SummaryPrompt.user(transcript: transcript), model: model, detailLevel: detailLevel
        )
    }

    func streamSummaryCompletion(systemPrompt: String, userMessage: String, model: String?, detailLevel: SummaryDetailLevel) -> AsyncThrowingStream<String, Error> {
        let modelID = model ?? provider.summaryModel
        return streamMessages(systemPrompt: systemPrompt, messages: [["role": "user", "content": userMessage]], model: modelID,
                              maxTokens: Self.summaryOutputBudget(model: modelID, detailLevel: detailLevel),
                              effort: Self.summaryEffort, requireCompleteSummary: true)
    }

    func streamChat(systemPrompt: String, userMessage: String, model: String?) -> AsyncThrowingStream<String, Error> {
        let modelID = model ?? provider.summaryModel
        return streamMessages(systemPrompt: systemPrompt, messages: [["role": "user", "content": userMessage]],
                              model: modelID, maxTokens: Self.chatOutputBudget(model: modelID), effort: Self.chatEffort)
    }

    func streamChat(systemPrompt: String, history: [ChatMessage], model: String?) -> AsyncThrowingStream<String, Error> {
        guard !history.isEmpty else { return AsyncThrowingStream { $0.finish() } }
        let modelID = model ?? provider.summaryModel
        return streamMessages(systemPrompt: systemPrompt, messages: Self.encodeMessages(history),
                              model: modelID, maxTokens: Self.chatOutputBudget(model: modelID), effort: Self.chatEffort)
    }

    // MARK: - Model request shape

    /// Generations verified to share one request surface: omitting `thinking`
    /// runs adaptive thinking, `output_config.effort` is accepted, sampling
    /// parameters are rejected and output reaches 128K. Exact IDs only, so a
    /// new model has to be checked before it inherits this shape.
    /// https://platform.claude.com/docs/en/about-claude/models/overview
    static let adaptiveThinkingModels: Set<String> = [
        "claude-sonnet-5", "claude-sonnet-5-5", "claude-opus-5", "claude-opus-5-5",
        "claude-fable-5", "claude-fable-5-1",
    ]

    /// Sonnet 5 at medium effort matched Sonnet 4.6 at its default high effort,
    /// which is what summaries were tuned on. Sonnet 5.5 recalibrates effort, so
    /// it was re-measured on hour-long fictional meetings (2026-09-28): high
    /// thought about 70% more and cost 27% more with no gain in rubric coverage,
    /// so medium stays.
    static let summaryEffort = "medium"
    /// Chat is latency-first; low effort still thinks on hard questions.
    static let chatEffort = "low"

    static func usesAdaptiveThinking(_ model: String) -> Bool {
        adaptiveThinkingModels.contains(model)
    }

    /// Makes the thinking and effort choice explicit for adaptive models; other
    /// models keep the thinking-off request they were tuned with.
    static func thinkingFields(model: String, effort: String) -> [String: Any] {
        guard usesAdaptiveThinking(model) else { return [:] }
        return ["thinking": ["type": "adaptive"], "output_config": ["effort": effort]]
    }

    /// `max_tokens` bounds thinking and answer together on adaptive models.
    static func chatOutputBudget(model: String) -> Int {
        usesAdaptiveThinking(model) ? 16384 : 4096
    }

    /// Explicitly verified model families; unknown/older models keep the conservative limit.
    /// Adaptive models get headroom for thinking, and their tokenizer counts
    /// about 30% more tokens for the same summary text.
    /// https://platform.claude.com/docs/en/models/sonnet-4-6/overview
    /// https://platform.claude.com/docs/en/models/haiku-4-5/overview
    static func summaryOutputBudget(model: String, detailLevel: SummaryDetailLevel) -> Int {
        if usesAdaptiveThinking(model) {
            switch detailLevel {
            case .highlights: return 16384
            case .detailed: return 24576
            case .fullBreakdown: return 32768
            }
        }
        let supported = ["claude-sonnet-4-6", "claude-haiku-4-5"]
            .contains { model == $0 || model.hasPrefix($0 + "-") }
        guard supported else { return 4096 }
        switch detailLevel {
        case .highlights: return 4096
        case .detailed: return 8192
        case .fullBreakdown: return 16384
        }
    }

    static func validateStopReason(_ reason: String?) throws {
        // Missing termination, refusals and length-limited JSON must not become successful summaries.
        guard reason == "end_turn" || reason == "stop_sequence" else {
            throw AIServiceError.incompleteResponse
        }
    }

    private func streamMessages(systemPrompt: String, messages: [[String: Any]], model: String, maxTokens: Int, effort: String, requireCompleteSummary: Bool = false) -> AsyncThrowingStream<String, Error> {
        // Serialize before crossing into the task: [String: Any] is not Sendable.
        let events: AsyncThrowingStream<String, Error>
        do {
            var body: [String: Any] = [
                "model": model, "max_tokens": maxTokens,
                "system": Self.cacheableSystem(systemPrompt), "messages": messages, "stream": true
            ]
            body.merge(Self.thinkingFields(model: model, effort: effort)) { _, new in new }
            events = try postStreamJSON(body)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var stopped = false
                    var reason: String?
                    for try await payload in events {
                        try Task.checkCancellation()
                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let type = json["type"] as? String else { continue }
                        if type == "error" { throw AIServiceError.invalidResponse }
                        if type == "content_block_delta",
                           let delta = json["delta"] as? [String: Any],
                           let text = delta["text"] as? String { continuation.yield(text) }
                        if type == "message_delta", let delta = json["delta"] as? [String: Any],
                           let terminalReason = delta["stop_reason"] as? String {
                            reason = terminalReason
                        }
                        if type == "message_stop" { stopped = true; break }
                    }
                    try Task.checkCancellation()
                    if requireCompleteSummary {
                        guard stopped else { throw AIServiceError.incompleteResponse }
                        try Self.validateStopReason(reason)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    // MARK: - Prompt Caching

    /// Wrap a system prompt as a single cacheable text block.
    /// Anthropic prompt-caching is a prefix match — repeated requests with an identical
    /// system prefix served from cache cost ~0.1× and skip first-token latency.
    /// Minimum cacheable prefix differs by model:
    ///   Sonnet 5.5 (summary default):     ≥512 tokens
    ///   Sonnet 5:                         ≥1024 tokens
    ///   Haiku 4.5  (chat default):        ≥4096 tokens
    /// Shorter prefixes silently don't cache (no error). Chat system prompts typically
    /// run 2-5K tokens including RECORDING SUMMARIES, so on Haiku we may miss cache for
    /// small-scope queries — still net win because Haiku is ~5x cheaper / ~3-5x faster
    /// than Sonnet, but the cache amortization story is weaker than on Sonnet.
    private static func cacheableSystem(_ text: String) -> [[String: Any]] {
        [
            [
                "type": "text",
                "text": text,
                "cache_control": ["type": "ephemeral"]
            ]
        ]
    }

    /// Encode a ChatMessage array into Anthropic messages format. Marks the LAST message with
    /// cache_control to create a breakpoint covering all prior turns (and the system prefix).
    /// Anthropic allows max 4 cache_control breakpoints per request — we use 2 (system + last message).
    private static func encodeMessages(_ messages: [ChatMessage]) -> [[String: Any]] {
        let lastIdx = messages.count - 1
        return messages.enumerated().map { idx, msg in
            let role = msg.role == .user ? "user" : "assistant"
            if idx == lastIdx {
                return [
                    "role": role,
                    "content": [
                        [
                            "type": "text",
                            "text": msg.content,
                            "cache_control": ["type": "ephemeral"]
                        ]
                    ]
                ]
            }
            return ["role": role, "content": msg.content]
        }
    }

    // MARK: - HTTP

    private func postJSON(_ body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: try endpointURL())
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        return try await transport.data(
            for: request,
            provider: provider,
            redacting: [apiKey]
        )
    }

    private func postStreamJSON(_ body: [String: Any]) throws -> AsyncThrowingStream<String, Error> {
        var request = URLRequest(url: try endpointURL())
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        return transport.serverSentEvents(
            for: request,
            provider: provider,
            redacting: [apiKey]
        )
    }

    private func endpointURL() throws -> URL {
        guard let url = URL(string: baseURL) else {
            throw AITransportError.unsafeEndpoint
        }
        return url
    }
}
