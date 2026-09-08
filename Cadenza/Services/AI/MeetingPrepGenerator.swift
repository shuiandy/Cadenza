import Foundation

enum PrepGenerationError: Error {
    case noAPIKey          // → Phase 4 maps to ArtifactErrorClass.permanent
    case provider(Error)   // → retryable
}

/// 生成会前 prep brief markdown。仿 RecapGenerator:固定 system prompt + streamChat 增量收集。
/// 核心 generate(contextText:service:model:) 接受注入 service,可脱离网络单测。
@MainActor
final class MeetingPrepGenerator {
    var apiKeyResolver: (AIProvider) -> String? = { KeychainManager.shared.apiKey(for: $0) }
    var serviceFactory: (AIProvider, String) -> AIServiceProtocol? = { $0.makeChatService(apiKey: $1) }
    var gate: AIGenerationGate = .shared

    nonisolated static let systemPrompt = """
    You are a meeting-prep assistant. Using ONLY the provided context, write a concise pre-meeting brief in Markdown for the current user. Do not invent facts. Match the language of the context.

    Structure (omit a section if there's nothing to say):
    ## TL;DR
    One or two sentences: what this meeting is about and what the user should aim to get out of it.
    ## Where we left off
    The most relevant points from recent related meetings.
    ## Open items to follow up
    Unresolved action items relevant to this meeting or these people.
    ## Attendees
    For each key attendee: who they are and what they last committed to / care about.
    ## Suggested agenda & questions to ask
    A short bulleted list.
    ## Links
    Any relevant recordings or projects mentioned in the context.
    """

    /// 核心:给定已就绪的 service + context 文本,生成 markdown。经 gate 串行。
    func generate(contextText: String, service: AIServiceProtocol, model: String?) async throws -> String {
        try await gate.run(provider: service.provider) {
            var full = ""
            let stream = service.streamChat(
                systemPrompt: Self.systemPrompt, userMessage: contextText, model: model)
            for try await chunk in stream { full += chunk }
            return full
        }
    }

    /// 薄 glue:解析 provider→key→service,分类失败。
    func generatePrep(contextText: String, provider: AIProvider,
                      model: String?) async -> Result<String, PrepGenerationError> {
        guard let key = resolveKey(for: provider),
              let service = serviceFactory(provider, key) else {
            return .failure(.noAPIKey)
        }
        let modelID = model ?? provider.summaryModel
        do {
            return .success(try await generate(contextText: contextText, service: service, model: modelID))
        } catch {
            return .failure(.provider(error))
        }
    }

    private func resolveKey(for provider: AIProvider) -> String? {
        if !provider.requiresAPIKey { return "" }
        guard let k = apiKeyResolver(provider), !k.isEmpty else { return nil }
        return k
    }
}
