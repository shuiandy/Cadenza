import Foundation

/// Google Gemini API for meeting summarization.
final class GeminiService: AIServiceProtocol {
    let provider: AIProvider = .gemini
    private let apiKey: String
    private let baseURL = "https://generativelanguage.googleapis.com/v1beta/models"
    private let transport: HardenedAITransport

    init(apiKey: String, transport: HardenedAITransport = .shared) {
        self.apiKey = apiKey
        self.transport = transport
    }

    func summarize(transcript: String, language: String, model: String?, jobTitle: String? = nil, meetingType: MeetingType? = nil, meetingTitle: String? = nil, knownTags: [String], detailLevel: SummaryDetailLevel = SummaryDetailLevel.load()) async throws -> SummaryResult {
        let modelID = model ?? provider.summaryModel
        let url = try endpointURL(modelID: modelID, streaming: false)

        let body: [String: Any] = [
            "system_instruction": [
                "parts": [["text": SummaryPrompt.system(language: language, jobTitle: jobTitle, meetingType: meetingType, meetingTitle: meetingTitle, knownTags: knownTags, detailLevel: detailLevel)]]
            ],
            "contents": [
                ["role": "user", "parts": [["text": SummaryPrompt.user(transcript: transcript)]]]
            ],
            "generationConfig": [
                "temperature": 0.3
            ]
        ]

        let data = try await postJSON(url: url, body: body)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let text = parts.first?["text"] as? String else {
            throw AIServiceError.invalidResponse
        }

        guard candidates.first?["finishReason"] as? String == "STOP" else { throw AIServiceError.incompleteResponse }
        return SummaryPrompt.parseResponse(text)
    }

    func streamSummarize(transcript: String, language: String, model: String?, jobTitle: String? = nil, meetingType: MeetingType? = nil, meetingTitle: String? = nil, knownTags: [String], detailLevel: SummaryDetailLevel = SummaryDetailLevel.load()) -> AsyncThrowingStream<String, Error> {
        streamSummaryCompletion(systemPrompt: SummaryPrompt.system(language: language, jobTitle: jobTitle, meetingType: meetingType, meetingTitle: meetingTitle, knownTags: knownTags, detailLevel: detailLevel),
            userMessage: SummaryPrompt.user(transcript: transcript), model: model, detailLevel: detailLevel)
    }

    func streamSummaryCompletion(systemPrompt: String, userMessage: String, model: String?, detailLevel: SummaryDetailLevel) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let url = try endpointURL(modelID: model ?? provider.summaryModel, streaming: true)
                    let body: [String: Any] = [
                        "system_instruction": ["parts": [["text": systemPrompt]]],
                        "contents": [["role": "user", "parts": [["text": userMessage]]]],
                        "generationConfig": ["temperature": 0.3]
                    ]
                    var reason: String?
                    for try await payload in try postStreamJSON(url: url, body: body) {
                        try Task.checkCancellation()
                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        if json["error"] != nil { throw AIServiceError.invalidResponse }
                        guard let candidate = (json["candidates"] as? [[String: Any]])?.first else { continue }
                        if let terminal = candidate["finishReason"] as? String { reason = terminal }
                        if let content = candidate["content"] as? [String: Any], let parts = content["parts"] as? [[String: Any]] {
                            for part in parts where part["thought"] as? Bool != true {
                                if let text = part["text"] as? String { continuation.yield(text) }
                            }
                        }
                    }
                    try Task.checkCancellation()
                    guard reason == "STOP" else { throw AIServiceError.incompleteResponse }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    func streamChat(systemPrompt: String, userMessage: String, model: String?) -> AsyncThrowingStream<String, Error> {
        let modelID = model ?? provider.summaryModel

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let url = try self.endpointURL(modelID: modelID, streaming: true)

                    let body: [String: Any] = [
                        "system_instruction": [
                            "parts": [["text": systemPrompt]]
                        ],
                        "contents": [
                            ["role": "user", "parts": [["text": userMessage]]]
                        ],
                        "generationConfig": [
                            "temperature": 0.3
                        ]
                    ]

                    let events = try self.postStreamJSON(url: url, body: body)

                    for try await payload in events {
                        try Task.checkCancellation()
                        guard let lineData = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                              let candidates = json["candidates"] as? [[String: Any]],
                              let content = candidates.first?["content"] as? [String: Any],
                              let parts = content["parts"] as? [[String: Any]],
                              let text = parts.first?["text"] as? String else { continue }
                        continuation.yield(text)
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

    private func postJSON(url: URL, body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        return try await transport.data(
            for: request,
            provider: provider,
            redacting: [apiKey]
        )
    }

    private func postStreamJSON(
        url: URL,
        body: [String: Any]
    ) throws -> AsyncThrowingStream<String, Error> {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        return transport.serverSentEvents(
            for: request,
            provider: provider,
            redacting: [apiKey]
        )
    }

    private func endpointURL(modelID: String, streaming: Bool) throws -> URL {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard !modelID.isEmpty,
              modelID.utf8.count <= 256,
              modelID.unicodeScalars.allSatisfy(allowed.contains),
              var components = URLComponents(string: baseURL) else {
            throw AITransportError.unsafeEndpoint
        }
        components.path += "/\(modelID):\(streaming ? "streamGenerateContent" : "generateContent")"
        components.queryItems = streaming ? [URLQueryItem(name: "alt", value: "sse")] : nil
        guard let url = components.url else {
            throw AITransportError.unsafeEndpoint
        }
        return url
    }
}
