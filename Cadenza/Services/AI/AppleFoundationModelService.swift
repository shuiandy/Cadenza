import Foundation
import FoundationModels

enum AppleFoundationModelFactory {
    static let maxInputCharacters = 2_000

    static var isAvailable: Bool {
        guard #available(macOS 26.0, *) else { return false }
        return AppleFoundationModelService.isAvailable
    }

    static func makeService() -> AIServiceProtocol? {
        guard #available(macOS 26.0, *), AppleFoundationModelService.isAvailable else {
            return nil
        }
        return AppleFoundationModelService()
    }

    static func packChatHistory(_ history: [ChatMessage]) -> String {
        AIContextAssembler.packHistoryMessages(history, maxCharacters: maxInputCharacters)
    }
}

/// On-device AI service using Apple's FoundationModels framework (macOS 26+).
/// Provides summarization and chat without requiring an API key or network connection.
@available(macOS 26.0, *)
final class AppleFoundationModelService: AIServiceProtocol, Sendable {
    let provider: AIProvider = .apple

    /// Apple FM context window is ~4096 tokens total (instructions + prompt + output).
    /// Reserve ~800 tokens for instructions, ~600 for output → ~2600 tokens for input.
    /// At ~3.5 chars/token → ~2000 chars max input per call.
    private static let maxChars = AppleFoundationModelFactory.maxInputCharacters

    // MARK: - Summarization

    func summarize(
        transcript: String,
        language: String,
        model: String?,
        jobTitle: String?,
        meetingType: MeetingType?,
        meetingTitle: String?,
        knownTags: [String],
        detailLevel: SummaryDetailLevel = SummaryDetailLevel.load()
    ) async throws -> SummaryResult {
        do {
            // Always use map-reduce for Apple FM due to small context window
            let chunks = splitIntoChunks(transcript)

            if chunks.count == 1, chunks[0].count <= Self.maxChars {
                let response = try await generate(
                    instructions: compactSummaryPrompt(
                        language: language,
                        knownTags: knownTags,
                        jobTitle: jobTitle,
                        meetingType: meetingType,
                        meetingTitle: meetingTitle, detailLevel: detailLevel
                    ),
                    prompt: chunks[0]
                )
                return SummaryPrompt.parseResponse(response)
            }

            return try await mapReduceSummarize(
                chunks: chunks, language: language,
                jobTitle: jobTitle, meetingType: meetingType,
                meetingTitle: meetingTitle, knownTags: knownTags, detailLevel: detailLevel
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            NSLog("[AppleFM] summary request failed: %@", String(describing: error))
            throw Self.userVisibleError(from: error)
        }
    }

    func streamSummarize(
        transcript: String,
        language: String,
        model: String?,
        jobTitle: String?,
        meetingType: MeetingType?,
        meetingTitle: String?,
        knownTags: [String],
        detailLevel: SummaryDetailLevel = SummaryDetailLevel.load()
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // For streaming, use non-streaming summarize and yield the result at once
                    let result = try await self.summarize(
                        transcript: transcript, language: language,
                        model: model, jobTitle: jobTitle,
                        meetingType: meetingType, meetingTitle: meetingTitle,
                        knownTags: knownTags, detailLevel: detailLevel
                    )
                    try Task.checkCancellation()
                    continuation.yield(result.rawText)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    NSLog("[AppleFM] chat request failed: %@", String(describing: error))
                    continuation.finish(throwing: Self.userVisibleError(from: error))
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    // MARK: - Chat

    func streamChat(
        systemPrompt: String,
        userMessage: String,
        model: String?
    ) -> AsyncThrowingStream<String, Error> {
        // Truncate user message to fit context window
        let truncatedSystem = String(systemPrompt.prefix(800))
        let truncatedUser = String(userMessage.prefix(Self.maxChars))

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let session = LanguageModelSession(instructions: truncatedSystem)
                    let stream = session.streamResponse(to: truncatedUser)
                    // Apple FM emits cumulative snapshots; downstream expects deltas.
                    // Compare on unicodeScalars to stay correct when a snapshot extends
                    // the previous last grapheme (e.g., "cafe" → "café" via combining mark,
                    // "👍" → "👍🏻" via emoji modifier) — those break String.hasPrefix.
                    var emittedScalars = String.UnicodeScalarView()
                    for try await partial in stream {
                        try Task.checkCancellation()
                        let full = partial.content.unicodeScalars
                        if full.count == emittedScalars.count,
                           full.elementsEqual(emittedScalars) { continue }
                        guard full.starts(with: emittedScalars) else {
                            // Truly non-monotonic; skip to avoid duplicating already-yielded text.
                            // Append-only consumers can't honor a rewrite; the corrected segment is
                            // dropped and downstream text will diverge from the model's intent.
                            // Apple FM has not been observed doing this in practice; if you hit this
                            // log in the wild, the streaming contract needs to switch to snapshot mode.
                            NSLog("[AppleFM] non-monotonic snapshot dropped (had %lld scalars, got %lld)",
                                  Int64(emittedScalars.count), Int64(full.count))
                            emittedScalars = full
                            continue
                        }
                        let deltaScalars = full.dropFirst(emittedScalars.count)
                        if !deltaScalars.isEmpty {
                            continuation.yield(String(String.UnicodeScalarView(deltaScalars)))
                        }
                        emittedScalars = full
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    Self.finishChatStream(continuation, throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    /// Preserve the current question and the untrusted-data boundary when adapting native
    /// multi-turn packets to Apple's much smaller local context window.
    func streamChat(
        systemPrompt: String,
        history: [ChatMessage],
        model: String?
    ) -> AsyncThrowingStream<String, Error> {
        streamChat(
            systemPrompt: systemPrompt,
            userMessage: AppleFoundationModelFactory.packChatHistory(history),
            model: model
        )
    }

    // MARK: - Private Helpers

    private func generate(instructions: String, prompt: String) async throws -> String {
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: String(prompt.prefix(Self.maxChars)))
        return response.content
    }

    /// Preserve already-reviewed service/transport categories while
    /// collapsing FoundationModels-native diagnostics into stable UI copy.
    /// Callers log the original error before invoking this mapper.
    static func userVisibleError(from error: Error) -> any Error {
        if let serviceError = error as? AIServiceError {
            return serviceError
        }
        if let transportError = error as? AITransportError {
            return transportError
        }
        return AIServiceError.onDeviceModelFailed
    }

    /// The single user-facing exit for native FoundationModels stream errors.
    /// Keep the original diagnostic in the log while exposing only stable,
    /// localized service categories to stream consumers.
    static func finishChatStream(
        _ continuation: AsyncThrowingStream<String, Error>.Continuation,
        throwing error: Error
    ) {
        NSLog("[AppleFM] chat request failed: %@", String(describing: error))
        continuation.finish(throwing: userVisibleError(from: error))
    }

    /// Compact prompt optimized for Apple FM's small context window.
    private func compactSummaryPrompt(
        language: String,
        knownTags: [String],
        jobTitle: String?,
        meetingType: MeetingType?,
        meetingTitle: String?,
        detailLevel: SummaryDetailLevel
    ) -> String {
        let outputLanguage = SummaryPrompt.languageName(language)
        let userName = SummaryPrompt.evaluationUserName ?? UserDefaults.standard.string(forKey: ActiveProfileDefaults.key("userName")) ?? ""
        var context: [String] = []
        if !userName.isEmpty {
            var identity = "Configured user: \(userName)"
            if let jobTitle, !jobTitle.isEmpty { identity += " (\(jobTitle))" }
            identity += ". Put only explicitly evidenced tasks for this person in your_tasks."
            context.append(identity)
        }
        if let meetingTitle, !meetingTitle.isEmpty { context.append("Meeting title: \(meetingTitle).") }
        if let meetingType, meetingType != .general { context.append("Meeting type: \(meetingType.rawValue).") }
        // Best-effort reuse within Apple FM's tiny context window: feed a trimmed vocabulary.
        let reuse = knownTags.isEmpty ? "" : "Reuse an existing tag when one fits: \(knownTags.prefix(20).joined(separator: ", ")). "
        return """
        Summarize this meeting transcript. Respond in \(outputLanguage). Output ONLY valid JSON:
        \(SummaryPrompt.compactSpeakerAttributionRules)
        \(SummaryPrompt.compactSummaryCoverageRules)
        \(detailLevel.compactPromptGuidance)
        \(context.joined(separator: " "))
        {"title":"...","overview":"...","key_points":["..."],"action_items":[{"assignee":null,"task":"...","deadline":null}],"decisions":["..."],"follow_ups":["..."],"your_tasks":["..."],"tags":["..."],"meeting_type":"general"}
        Write the title in \(outputLanguage). \(reuse)Tags in the same language as the summary; avoid tags obvious from the user's role.
        Empty arrays for missing sections. Be concise.
        """
    }

    /// Split transcript into small chunks suitable for Apple FM's context window.
    private func splitIntoChunks(_ text: String) -> [String] {
        SummaryPrompt.splitForModelInput(text, maxChars: Self.maxChars)
    }

    // MARK: - Map-Reduce

    private func mapReduceSummarize(
        chunks: [String],
        language: String,
        jobTitle: String?,
        meetingType: MeetingType?,
        meetingTitle: String?,
        knownTags: [String],
        detailLevel: SummaryDetailLevel = SummaryDetailLevel.load()
    ) async throws -> SummaryResult {
        // Map phase: summarize each chunk with a minimal prompt
        let outputLanguage = SummaryPrompt.languageName(language)
        let mapPrompt = "Summarize this meeting segment concisely. \(SummaryPrompt.compactSpeakerAttributionRules) \(SummaryPrompt.compactSummaryCoverageRules) \(detailLevel.compactPromptGuidance) Include key points, decisions, action items. Respond in \(outputLanguage). Use plain text."

        var chunkSummaries: [String] = []
        for chunk in chunks {
            let summary = try await generate(
                instructions: mapPrompt,
                prompt: chunk
            )
            chunkSummaries.append(summary)
        }

        let reduceInput = try await reduceChunkSummaries(
            chunkSummaries,
            outputLanguage: outputLanguage, detailLevel: detailLevel
        )

        let response = try await generate(
            instructions: compactSummaryPrompt(
                language: language,
                knownTags: knownTags,
                jobTitle: jobTitle,
                meetingType: meetingType,
                meetingTitle: meetingTitle, detailLevel: detailLevel
            ),
            prompt: reduceInput
        )
        return SummaryPrompt.parseResponse(response)
    }

    private func reduceChunkSummaries(
        _ summaries: [String],
        outputLanguage: String,
        detailLevel: SummaryDetailLevel,
        depth: Int = 0
    ) async throws -> String {
        let combined = summaries.enumerated().map { index, summary in
            "[\(index + 1)] \(summary)"
        }.joined(separator: "\n\n")
        guard combined.count > Self.maxChars else { return combined }
        guard depth < 8 else { throw AppleSummaryError.reductionDidNotConverge }

        let batches = SummaryPrompt.splitForModelInput(combined, maxChars: Self.maxChars)
        var reduced: [String] = []
        for batch in batches {
            let result = try await generate(
                instructions: "Condense all supplied segment summaries to at most 500 characters without dropping facts or changing speaker attribution. \(SummaryPrompt.compactSpeakerAttributionRules) \(SummaryPrompt.compactSummaryCoverageRules) \(detailLevel.compactPromptGuidance) Respond in \(outputLanguage). Use plain text.",
                prompt: batch
            )
            reduced.append(result)
        }
        return try await reduceChunkSummaries(
            reduced,
            outputLanguage: outputLanguage, detailLevel: detailLevel,
            depth: depth + 1
        )
    }

    private enum AppleSummaryError: LocalizedError {
        case reductionDidNotConverge

        var errorDescription: String? {
            "Apple summary reduction did not converge within the context limit."
        }
    }

    // MARK: - Availability

    fileprivate static var isAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }
}
