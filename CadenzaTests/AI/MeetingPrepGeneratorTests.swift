import Testing
import Foundation
@testable import Cadenza

/// 只实现 streamChat(systemPrompt:userMessage:model:);其余协议要求给最小 stub。
struct MockAIService: AIServiceProtocol {
    var provider: AIProvider = .claude
    var chunks: [String] = []
    var errorToThrow: Error? = nil

    func summarize(transcript: String, language: String, model: String?, jobTitle: String?,
                   meetingType: MeetingType?, meetingTitle: String?, knownTags: [String], detailLevel: SummaryDetailLevel) async throws -> SummaryResult {
        throw PrepGenerationError.noAPIKey // unused in these tests
    }
    func streamSummarize(transcript: String, language: String, model: String?, jobTitle: String?,
                         meetingType: MeetingType?, meetingTitle: String?, knownTags: [String], detailLevel: SummaryDetailLevel) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func streamChat(systemPrompt: String, userMessage: String, model: String?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { cont in
            if let e = errorToThrow { cont.finish(throwing: e); return }
            for c in chunks { cont.yield(c) }   // yield DELTAS
            cont.finish()
        }
    }
}

@Suite("MeetingPrepGenerator")
struct MeetingPrepGeneratorTests {

    @Test @MainActor func collectsStreamedDeltasIntoMarkdown() async throws {
        let gen = MeetingPrepGenerator()
        let svc = MockAIService(chunks: ["## TL;DR\n", "- point one\n", "- point two"])
        let out = try await gen.generate(contextText: "ctx", service: svc, model: "m")
        #expect(out == "## TL;DR\n- point one\n- point two")
    }

    @Test @MainActor func noAPIKeyIsPermanentFailure() async {
        let gen = MeetingPrepGenerator()
        gen.apiKeyResolver = { _ in nil }
        let r = await gen.generatePrep(contextText: "ctx", provider: .claude, model: nil)
        guard case .failure(.noAPIKey) = r else { Issue.record("expected .noAPIKey, got \(r)"); return }
    }

    @Test @MainActor func providerErrorIsRetryableFailure() async {
        let gen = MeetingPrepGenerator()
        gen.apiKeyResolver = { _ in "key" }
        gen.serviceFactory = { _, _ in MockAIService(errorToThrow: URLError(.timedOut)) }
        let r = await gen.generatePrep(contextText: "ctx", provider: .claude, model: nil)
        guard case .failure(.provider) = r else { Issue.record("expected .provider, got \(r)"); return }
    }

    @Test @MainActor func generatePrepSuccessReturnsMarkdown() async {
        let gen = MeetingPrepGenerator()
        gen.apiKeyResolver = { _ in "key" }
        gen.serviceFactory = { _, _ in MockAIService(chunks: ["ready ", "brief"]) }
        let r = await gen.generatePrep(contextText: "ctx", provider: .claude, model: nil)
        guard case .success(let md) = r else { Issue.record("expected success, got \(r)"); return }
        #expect(md == "ready brief")
    }
}
