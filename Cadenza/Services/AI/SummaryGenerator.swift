import Foundation

/// Orchestrates AI summarization across providers.
@Observable @MainActor
final class SummaryGenerator {
    private let defaults = UserDefaults.standard
    /// Scoped-key resolver; the initializer default binds to the active
    /// profile, tests inject an explicit mapping.
    private let preferenceKey: (String) -> String

    init(preferenceKey: @escaping (String) -> String = ActiveProfileDefaults.key) {
        self.preferenceKey = preferenceKey
    }
    private(set) var isGenerating = false
    private(set) var streamedText = ""
    private(set) var result: SummaryResult?
    private(set) var error: String?
    /// Partial result from quick phase (available during enrich phase for UI).
    private(set) var quickResult: SummaryResult?
    /// True when enrich phase is running (quick result already available).
    private(set) var isEnriching = false

    /// Closure to resolve API keys. Defaults to KeychainManager; overridden in XPC Core.
    var apiKeyResolver: (AIProvider) -> String? = { KeychainManager.shared.apiKey(for: $0) }

    /// Resolve API key for provider, returning empty string for local providers.
    private func resolveKey(for provider: AIProvider) -> String? {
        if !provider.requiresAPIKey { return "" }
        guard let key = apiKeyResolver(provider), !key.isEmpty else { return nil }
        return key
    }

    /// Generate a summary using the specified provider.
    func generate(
        transcript: String,
        provider: AIProvider,
        model: String? = nil,
        language: String = "en",
        meetingType: MeetingType? = nil,
        meetingTitle: String? = nil,
        knownTags: [String] = []
    ) async {
        guard !isGenerating else { return }

        guard let apiKey = resolveKey(for: provider) else {
            error = String(localized: "No API key is configured for \(provider.displayName).")
            return
        }

        isGenerating = true
        error = nil
        result = nil
        streamedText = ""

        // Resolve settings on MainActor, then run network I/O off MainActor.
        let modelID = model ?? provider.summaryModel
        let jobTitle = defaults.string(forKey: preferenceKey("userJobTitle"))

        do {
            let summaryResult = try await Self.runGenerate(
                provider: provider, apiKey: apiKey,
                transcript: transcript, language: language,
                model: modelID, jobTitle: jobTitle, meetingType: meetingType,
                meetingTitle: meetingTitle, knownTags: knownTags
            )
            self.result = summaryResult
            self.streamedText = summaryResult.rawText
        } catch {
            self.error = error.localizedDescription
        }

        isGenerating = false
    }

    /// Stream a summary for real-time display.
    func streamGenerate(
        transcript: String,
        provider: AIProvider,
        model: String? = nil,
        language: String = "en",
        meetingType: MeetingType? = nil,
        meetingTitle: String? = nil,
        knownTags: [String] = []
    ) async {
        guard !isGenerating else { return }

        guard let apiKey = resolveKey(for: provider) else {
            error = String(localized: "No API key is configured for \(provider.displayName).")
            return
        }

        isGenerating = true
        error = nil
        result = nil
        streamedText = ""
        quickResult = nil
        isEnriching = false

        // Resolve settings on MainActor, then stream off MainActor.
        let modelID = model ?? provider.summaryModel
        let jobTitle = defaults.string(forKey: preferenceKey("userJobTitle"))

        // Provider callbacks carry only deltas. The coalescer owns one delayed
        // flush at a time and closes it before final state is committed.
        let streamUpdates = SummaryStreamUpdateCoalescer { [weak self] update in
            switch update {
            case .append(let delta):
                self?.streamedText.append(delta)
            case .replace(let text):
                self?.streamedText = text
            }
        }
        let onChunk: @Sendable (String) async -> Void = { delta in
            await streamUpdates.append(delta)
        }
        let onQuickDone: @MainActor @Sendable (SummaryResult) -> Void = { [weak self] quickResult in
            self?.quickResult = quickResult
        }
        let onEnrichStart: @MainActor @Sendable () async -> Void = { [weak self] in
            await streamUpdates.beginReplacementPhase()
            self?.isEnriching = true
        }

        let (text, parsedResult, errorMsg) = await Self.runStreamGenerate(
            provider: provider, apiKey: apiKey,
            transcript: transcript, language: language,
            model: modelID, jobTitle: jobTitle, meetingType: meetingType,
            meetingTitle: meetingTitle, knownTags: knownTags,
            onChunk: onChunk,
            onQuickDone: onQuickDone,
            onEnrichStart: onEnrichStart
        )

        await streamUpdates.finish(finalText: text)
        if let parsedResult { result = parsedResult }
        if let errorMsg { error = errorMsg }
        quickResult = nil
        isEnriching = false
        isGenerating = false
    }

    // MARK: - Async Chapter Generation

    /// Generate chapters for a transcript asynchronously.
    func generateChapters(
        transcript: String,
        provider: AIProvider,
        language: String = "en"
    ) async -> [ChapterResult] {
        guard let apiKey = resolveKey(for: provider) else { return [] }
        let modelID = provider.summaryModel
        return await Self.runGenerateChapters(
            provider: provider, apiKey: apiKey,
            transcript: transcript, language: language, model: modelID
        )
    }

    private nonisolated static func runGenerateChapters(
        provider: AIProvider, apiKey: String,
        transcript: String, language: String, model: String
    ) async -> [ChapterResult] {
        guard let service = makeService(provider: provider, apiKey: apiKey) else { return [] }
        let systemPrompt = SummaryPrompt.chaptersSystem(language: language)
        let userMessage = SummaryPrompt.user(transcript: transcript)
        do {
            let response = try await AIGenerationGate.shared.run { () async throws -> String in
                var response = ""
                let stream = service.streamChat(
                    systemPrompt: systemPrompt,
                    userMessage: userMessage,
                    model: model
                )
                for try await chunk in stream {
                    response += chunk
                }
                return response
            }
            return SummaryPrompt.parseChaptersResponse(response)
        } catch {
            NSLog("[SummaryGenerator] generateChapters failed: %@", error.localizedDescription)
            return []
        }
    }

    // MARK: - Nonisolated Heavy Work

    /// Non-streaming summary — prompt assembly and network I/O run off MainActor.
    private nonisolated static func runGenerate(
        provider: AIProvider, apiKey: String,
        transcript: String, language: String,
        model: String, jobTitle: String?, meetingType: MeetingType?,
        meetingTitle: String?, knownTags: [String]
    ) async throws -> SummaryResult {
        guard let service = makeService(provider: provider, apiKey: apiKey) else {
            throw AIServiceError.noProvider("\(provider.displayName) is not available on this device")
        }
        return try await service.summarize(
            transcript: transcript,
            language: language,
            model: model,
            jobTitle: jobTitle,
            meetingType: meetingType,
            meetingTitle: meetingTitle,
            knownTags: knownTags
        )
    }

    /// Two-stage summary: quick (overview/keyPoints/actionItems) then enrich (decisions/followUps).
    private nonisolated static func runTwoStageStreamGenerate(
        provider: AIProvider, apiKey: String,
        transcript: String, language: String,
        model: String, jobTitle: String?, meetingType: MeetingType?,
        meetingTitle: String?, knownTags: [String],
        onQuickChunk: @Sendable (String) async -> Void,
        onQuickDone: @MainActor @Sendable (SummaryResult) -> Void,
        onEnrichStart: @MainActor @Sendable () async -> Void,
        onEnrichChunk: @Sendable (String) async -> Void
    ) async -> (String, SummaryResult?, String?) {
        guard let service = makeService(provider: provider, apiKey: apiKey) else {
            return ("", nil, AIServiceError.noProvider(provider.displayName).localizedDescription)
        }

        // --- Quick phase ---
        let quickPrompt = SummaryPrompt.quickSystem(
            language: language, jobTitle: jobTitle,
            meetingType: meetingType, meetingTitle: meetingTitle, knownTags: knownTags
        )
        let quickUserMsg = SummaryPrompt.user(transcript: transcript)

        var quickText = ""
        let quickResult: SummaryResult
        do {
            quickText = try await AIGenerationGate.shared.run { () async throws -> String in
                var quickText = ""
                let stream = service.streamChat(
                    systemPrompt: quickPrompt,
                    userMessage: quickUserMsg,
                    model: model
                )
                for try await token in stream {
                    quickText += token
                    await onQuickChunk(token)
                }
                return quickText
            }
            quickResult = SummaryPrompt.parseQuickResponse(quickText)

            let overviewOK = !quickResult.overview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let keyPointsOK = !quickResult.keyPoints.isEmpty
            guard overviewOK && keyPointsOK else {
                NSLog("[SummaryGenerator] quick phase produced empty result, returning error")
                return (quickText, quickResult, AIServiceError.invalidResponse.localizedDescription)
            }
        } catch {
            return (quickText, nil, error.localizedDescription)
        }

        await onQuickDone(quickResult)
        await onEnrichStart()

        // --- Enrich phase ---
        let enrichPrompt = SummaryPrompt.enrichSystem(language: language)
        let enrichUserMsg = SummaryPrompt.enrichUser(
            transcript: transcript,
            quickSummaryText: quickText
        )

        var enrichText = ""
        do {
            enrichText = try await AIGenerationGate.shared.run { () async throws -> String in
                var enrichText = ""
                let stream = service.streamChat(
                    systemPrompt: enrichPrompt,
                    userMessage: enrichUserMsg,
                    model: model
                )
                for try await token in stream {
                    enrichText += token
                    await onEnrichChunk(token)
                }
                return enrichText
            }
            let (decisions, followUps) = SummaryPrompt.parseEnrichResponse(enrichText)
            let merged = SummaryPrompt.mergeQuickAndEnrich(
                quick: quickResult, decisions: decisions,
                followUps: followUps, enrichRawText: enrichText
            )
            return (merged.rawText, merged, nil)
        } catch {
            NSLog("[SummaryGenerator] enrich phase failed: %@, using quick result only", error.localizedDescription)
            return (quickText, quickResult, nil)
        }
    }

    /// Map-reduce streaming summary for long transcripts.
    private nonisolated static func runMapReduceStreamGenerate(
        provider: AIProvider, apiKey: String,
        chunks: [String], language: String,
        model: String, jobTitle: String?, meetingType: MeetingType?,
        meetingTitle: String?, knownTags: [String],
        onChunk: @Sendable (String) async -> Void
    ) async -> (String, SummaryResult?, String?) {
        guard let service = makeService(provider: provider, apiKey: apiKey) else {
            return ("", nil, AIServiceError.noProvider(provider.displayName).localizedDescription)
        }
        let mapPrompt = SummaryPrompt.mapSystem(language: language)

        // Map phase: parallel chunk summaries
        let chunkSummaries: [String]
        do {
            chunkSummaries = try await withThrowingTaskGroup(of: (Int, String).self) { group in
                let maxConcurrent = 3
                var nextIndex = 0

                // Seed initial batch
                while nextIndex < min(maxConcurrent, chunks.count) {
                    let index = nextIndex
                    let chunk = chunks[index]
                    group.addTask {
                        let text = try await AIGenerationGate.shared.run { () async throws -> String in
                            var text = ""
                            let stream = service.streamChat(
                                systemPrompt: mapPrompt,
                                userMessage: "Summarize this meeting segment:\n\n\(chunk)",
                                model: model
                            )
                            for try await token in stream {
                                text += token
                            }
                            return text
                        }
                        return (index, text)
                    }
                    nextIndex += 1
                }

                // As each completes, add next
                var results = [(Int, String)]()
                for try await result in group {
                    results.append(result)
                    if nextIndex < chunks.count {
                        let index = nextIndex
                        let chunk = chunks[index]
                        group.addTask {
                            let text = try await AIGenerationGate.shared.run { () async throws -> String in
                                var text = ""
                                let stream = service.streamChat(
                                    systemPrompt: mapPrompt,
                                    userMessage: "Summarize this meeting segment:\n\n\(chunk)",
                                    model: model
                                )
                                for try await token in stream {
                                    text += token
                                }
                                return text
                            }
                            return (index, text)
                        }
                        nextIndex += 1
                    }
                }
                return results.sorted(by: { $0.0 < $1.0 }).map(\.1)
            }
        } catch {
            NSLog("[SummaryGenerator] map phase failed: %@, falling back to single prompt", error.localizedDescription)
            return ("", nil, nil) // signal fallback
        }

        NSLog("[SummaryGenerator] map-reduce: %d chunks summarized, starting reduce", chunkSummaries.count)

        // Reduce phase: combine into final summary (streaming)
        let combinedInput = chunkSummaries.enumerated().map { (i, summary) in
            "## Segment \(i + 1)\n\(summary)"
        }.joined(separator: "\n\n")

        let reducePrompt = SummaryPrompt.reduceSystem(
            language: language, jobTitle: jobTitle,
            meetingType: meetingType, meetingTitle: meetingTitle, knownTags: knownTags
        )

        var finalText = ""
        do {
            finalText = try await AIGenerationGate.shared.run { () async throws -> String in
                var finalText = ""
                let stream = service.streamChat(
                    systemPrompt: reducePrompt,
                    userMessage: combinedInput,
                    model: model
                )
                for try await token in stream {
                    finalText += token
                    await onChunk(token)
                }
                return finalText
            }
            let parsed = SummaryPrompt.parseResponse(finalText)
            return (finalText, parsed, nil)
        } catch {
            return (finalText, nil, error.localizedDescription)
        }
    }

    /// Streaming summary — prompt assembly, network I/O, and response parsing run off MainActor.
    private nonisolated static func runStreamGenerate(
        provider: AIProvider, apiKey: String,
        transcript: String, language: String,
        model: String, jobTitle: String?, meetingType: MeetingType?,
        meetingTitle: String?, knownTags: [String],
        onChunk: @Sendable (String) async -> Void,
        onQuickDone: @MainActor @Sendable (SummaryResult) -> Void,
        onEnrichStart: @MainActor @Sendable () async -> Void
    ) async -> (String, SummaryResult?, String?) {
        // Local providers (Apple FM) have tiny context windows — use their own
        // summarize() which has compact prompts and built-in chunking.
        if !provider.requiresAPIKey {
            guard let service = makeService(provider: provider, apiKey: apiKey) else {
                return ("", nil, AIServiceError.noProvider(provider.displayName).localizedDescription)
            }
            do {
                let result = try await service.summarize(
                    transcript: transcript, language: language,
                    model: model, jobTitle: jobTitle,
                    meetingType: meetingType, meetingTitle: meetingTitle,
                    knownTags: knownTags
                )
                await onChunk(result.rawText)
                return (result.rawText, result, nil)
            } catch {
                return ("", nil, error.localizedDescription)
            }
        }

        // Auto map-reduce for long transcripts (no two-stage — reduce already outputs full JSON)
        let chunks = SummaryPrompt.splitForMapReduce(transcript)
        if chunks.count > 1 {
            NSLog("[SummaryGenerator] transcript %d chars → map-reduce with %d chunks", transcript.count, chunks.count)
            let (text, result, error) = await runMapReduceStreamGenerate(
                provider: provider, apiKey: apiKey,
                chunks: chunks, language: language,
                model: model, jobTitle: jobTitle,
                meetingType: meetingType, meetingTitle: meetingTitle,
                knownTags: knownTags,
                onChunk: onChunk
            )
            if result != nil || error != nil {
                return (text, result, error)
            }
            NSLog("[SummaryGenerator] map-reduce fallback to single prompt")
        }

        // Standard path: two-stage (quick + enrich)
        return await runTwoStageStreamGenerate(
            provider: provider, apiKey: apiKey,
            transcript: transcript, language: language,
            model: model, jobTitle: jobTitle,
            meetingType: meetingType, meetingTitle: meetingTitle,
            knownTags: knownTags,
            onQuickChunk: onChunk,
            onQuickDone: onQuickDone,
            onEnrichStart: onEnrichStart,
            onEnrichChunk: onChunk
        )
    }

    private nonisolated static func makeService(provider: AIProvider, apiKey: String) -> AIServiceProtocol? {
        provider.makeChatService(apiKey: apiKey)
    }
}

// MARK: - Errors

enum AIServiceError: Error, LocalizedError {
    case invalidResponse
    case httpError(Int, String)
    case noAPIKey
    case noProvider(String)
    case onDeviceModelFailed

    // These messages are rendered through Text(String) in several UI paths,
    // so they must be localized before leaving the error boundary. Provider
    // response bodies are intentionally never included here.
    var errorDescription: String? { localizedMessage() }

    func localizedMessage(locale: Locale? = nil) -> String {
        switch self {
        case .invalidResponse:
            return LocalizedBundle.string(
                "The AI provider returned an invalid response. Try again or choose another provider in Settings.",
                locale: locale
            )
        case .httpError(let code, _):
            return LocalizedBundle.string(
                "The AI provider request failed (HTTP \(code)). Check your API key, provider status, and network connection.",
                locale: locale
            )
        case .noAPIKey:
            return LocalizedBundle.string(
                "No AI provider configured. Add an API key in Settings.",
                locale: locale
            )
        case .noProvider:
            return LocalizedBundle.string(
                "The selected AI provider is unavailable on this Mac. Choose another provider in Settings.",
                locale: locale
            )
        case .onDeviceModelFailed:
            return LocalizedBundle.string(
                "Apple Intelligence couldn't complete the request. Try again or choose another AI provider in Settings.",
                locale: locale
            )
        }
    }
}
