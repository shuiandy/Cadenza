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

    func summarize(transcript: String, language: String, model: String?, jobTitle: String? = nil, meetingType: MeetingType? = nil, meetingTitle: String? = nil, knownTags: [String]) async throws -> SummaryResult {
        let modelID = model ?? provider.summaryModel
        let systemPrompt = SummaryPrompt.system(language: language, jobTitle: jobTitle, meetingType: meetingType, meetingTitle: meetingTitle, knownTags: knownTags)

        let body: [String: Any] = [
            "model": modelID,
            "max_tokens": 4096,
            "system": Self.cacheableSystem(systemPrompt),
            "messages": [
                ["role": "user", "content": SummaryPrompt.user(transcript: transcript)]
            ]
        ]

        let data = try await postJSON(body)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let textBlock = content.first(where: { ($0["type"] as? String) == "text" }),
              let text = textBlock["text"] as? String else {
            throw AIServiceError.invalidResponse
        }

        return SummaryPrompt.parseResponse(text)
    }

    func streamSummarize(transcript: String, language: String, model: String?, jobTitle: String? = nil, meetingType: MeetingType? = nil, meetingTitle: String? = nil, knownTags: [String]) -> AsyncThrowingStream<String, Error> {
        let modelID = model ?? provider.summaryModel
        let systemPrompt = SummaryPrompt.system(language: language, jobTitle: jobTitle, meetingType: meetingType, meetingTitle: meetingTitle, knownTags: knownTags)

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let body: [String: Any] = [
                        "model": modelID,
                        "max_tokens": 4096,
                        "system": Self.cacheableSystem(systemPrompt),
                        "messages": [
                            ["role": "user", "content": SummaryPrompt.user(transcript: transcript)]
                        ],
                        "stream": true
                    ]

                    let events = try self.postStreamJSON(body)

                    for try await payload in events {
                        try Task.checkCancellation()
                        guard let lineData = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                              let type = json["type"] as? String else { continue }

                        if type == "content_block_delta",
                           let delta = json["delta"] as? [String: Any],
                           let text = delta["text"] as? String {
                            continuation.yield(text)
                        }

                        if type == "message_stop" {
                            break
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    func streamChat(systemPrompt: String, userMessage: String, model: String?) -> AsyncThrowingStream<String, Error> {
        let modelID = model ?? provider.summaryModel

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let body: [String: Any] = [
                        "model": modelID,
                        "max_tokens": 4096,
                        "system": Self.cacheableSystem(systemPrompt),
                        "messages": [
                            ["role": "user", "content": userMessage]
                        ],
                        "stream": true
                    ]

                    let events = try self.postStreamJSON(body)

                    for try await payload in events {
                        try Task.checkCancellation()
                        guard let lineData = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                              let type = json["type"] as? String else { continue }

                        if type == "content_block_delta",
                           let delta = json["delta"] as? [String: Any],
                           let text = delta["text"] as? String {
                            continuation.yield(text)
                        }

                        if type == "message_stop" {
                            break
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    /// Multi-turn variant: takes a full history and lets Anthropic cache turn 1..N-1.
    /// The cache_control on the LAST user message creates a breakpoint covering all prior turns,
    /// so a follow-up question only re-processes the new user turn (and the new assistant output).
    func streamChat(systemPrompt: String, history: [ChatMessage], model: String?) -> AsyncThrowingStream<String, Error> {
        let modelID = model ?? provider.summaryModel
        guard !history.isEmpty else {
            return AsyncThrowingStream { $0.finish() }
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let messagesArray = Self.encodeMessages(history)
                    let body: [String: Any] = [
                        "model": modelID,
                        "max_tokens": 4096,
                        "system": Self.cacheableSystem(systemPrompt),
                        "messages": messagesArray,
                        "stream": true
                    ]

                    let events = try self.postStreamJSON(body)

                    for try await payload in events {
                        try Task.checkCancellation()
                        guard let lineData = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                              let type = json["type"] as? String else { continue }

                        if type == "content_block_delta",
                           let delta = json["delta"] as? [String: Any],
                           let text = delta["text"] as? String {
                            continuation.yield(text)
                        }

                        if type == "message_stop" {
                            break
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    // MARK: - Prompt Caching

    /// Wrap a system prompt as a single cacheable text block.
    /// Anthropic prompt-caching is a prefix match — repeated requests with an identical
    /// system prefix served from cache cost ~0.1× and skip first-token latency.
    /// Minimum cacheable prefix differs by model:
    ///   Sonnet 4.6 (summary default):     ≥2048 tokens
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
