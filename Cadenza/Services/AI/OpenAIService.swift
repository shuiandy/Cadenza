import Foundation

/// OpenAI-compatible chat completion service. Works with OpenAI, MiniMax, and other compatible APIs.
final class OpenAIService: AIServiceProtocol {
    enum RequestPurpose {
        case summary
        case chat
    }

    let provider: AIProvider
    private let apiKey: String
    private let baseURL: String
    private let transport: HardenedAITransport

    init(
        apiKey: String,
        baseURL: String = "https://api.openai.com/v1/chat/completions",
        provider: AIProvider = .openai,
        transport: HardenedAITransport = .shared
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.provider = provider
        self.transport = transport
    }

    func summarize(transcript: String, language: String, model: String?, jobTitle: String? = nil, meetingType: MeetingType? = nil, meetingTitle: String? = nil, knownTags: [String]) async throws -> SummaryResult {
        let modelID = model ?? provider.summaryModel

        let body = Self.makeRequestBody(
            provider: provider,
            modelID: modelID,
            messages: [
                ["role": "system", "content": SummaryPrompt.system(language: language, jobTitle: jobTitle, meetingType: meetingType, meetingTitle: meetingTitle, knownTags: knownTags)],
                ["role": "user", "content": SummaryPrompt.user(transcript: transcript)]
            ],
            purpose: .summary
        )

        let data = try await postJSON(body)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw AIServiceError.invalidResponse
        }

        return SummaryPrompt.parseResponse(content)
    }

    func streamSummarize(transcript: String, language: String, model: String?, jobTitle: String? = nil, meetingType: MeetingType? = nil, meetingTitle: String? = nil, knownTags: [String]) -> AsyncThrowingStream<String, Error> {
        let modelID = model ?? provider.summaryModel

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let body = Self.makeRequestBody(
                        provider: provider,
                        modelID: modelID,
                        messages: [
                            ["role": "system", "content": SummaryPrompt.system(language: language, jobTitle: jobTitle, meetingType: meetingType, meetingTitle: meetingTitle, knownTags: knownTags)],
                            ["role": "user", "content": SummaryPrompt.user(transcript: transcript)]
                        ],
                        purpose: .summary,
                        stream: true
                    )

                    let events = try postStreamJSON(body)

                    for try await payload in events {
                        try Task.checkCancellation()
                        guard payload != "[DONE]",
                              let lineData = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                              let choices = json["choices"] as? [[String: Any]],
                              let delta = choices.first?["delta"] as? [String: Any],
                              let content = delta["content"] as? String else { continue }
                        continuation.yield(content)
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
        let modelID = model ?? provider.chatModel

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let body = Self.makeRequestBody(
                        provider: provider,
                        modelID: modelID,
                        messages: [
                            ["role": "system", "content": systemPrompt],
                            ["role": "user", "content": userMessage]
                        ],
                        purpose: .chat,
                        stream: true
                    )

                    let events = try self.postStreamJSON(body)

                    for try await payload in events {
                        try Task.checkCancellation()
                        guard payload != "[DONE]",
                              let lineData = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                              let choices = json["choices"] as? [[String: Any]],
                              let delta = choices.first?["delta"] as? [String: Any],
                              let content = delta["content"] as? String else { continue }
                        continuation.yield(content)
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

    /// Multi-turn variant: OpenAI auto-caches identical prompt prefixes (≥1024 tokens) without
    /// any explicit marker, so just sending the full messages array as system + alternating
    /// turns gives us cache hits on follow-up questions in the same chat session.
    func streamChat(systemPrompt: String, history: [ChatMessage], model: String?) -> AsyncThrowingStream<String, Error> {
        let modelID = model ?? provider.chatModel
        guard !history.isEmpty else {
            return AsyncThrowingStream { $0.finish() }
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var msgs: [[String: String]] = [["role": "system", "content": systemPrompt]]
                    for msg in history {
                        msgs.append(["role": msg.role == .user ? "user" : "assistant", "content": msg.content])
                    }

                    let body = Self.makeRequestBody(
                        provider: provider,
                        modelID: modelID,
                        messages: msgs,
                        purpose: .chat,
                        stream: true
                    )

                    let events = try self.postStreamJSON(body)

                    for try await payload in events {
                        try Task.checkCancellation()
                        guard payload != "[DONE]",
                              let lineData = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                              let choices = json["choices"] as? [[String: Any]],
                              let delta = choices.first?["delta"] as? [String: Any],
                              let content = delta["content"] as? String else { continue }
                        continuation.yield(content)
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

    // MARK: - HTTP

    static func makeRequestBody(
        provider: AIProvider,
        modelID: String,
        messages: [[String: String]],
        purpose: RequestPurpose,
        stream: Bool = false
    ) -> [String: Any] {
        var body: [String: Any] = [
            "model": modelID,
            "messages": messages
        ]
        if stream {
            body["stream"] = true
        }

        let isOpenAIGPT56 = provider == .openai
            && (modelID == "gpt-5.6" || modelID.hasPrefix("gpt-5.6-"))
        if isOpenAIGPT56 {
            // GPT-5.6 defaults to medium reasoning. Preserve that quality-first
            // default for summaries, while keeping chat at the prior mini
            // model's latency baseline. Sampling parameters are deliberately
            // omitted for the new reasoning family.
            if purpose == .chat {
                body["reasoning_effort"] = "none"
            }
        }

        // OpenAI's remotely discovered model list can include models that only
        // accept the default temperature. Since temperature is optional, omit
        // it for OpenAI so new models remain usable without a client update.
        // MiniMax's compatible endpoint still receives Cadenza's tuned value.
        if provider == .minimax {
            body["temperature"] = 0.3
        }

        return body
    }

    private func postJSON(_ body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: try endpointURL())
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
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
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
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
