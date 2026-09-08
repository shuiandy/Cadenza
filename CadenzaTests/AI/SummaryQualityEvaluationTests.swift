import Foundation
import Testing
@testable import Cadenza

@Suite("Summary quality evaluation")
struct SummaryQualityEvaluationTests {
    @MainActor @Test func evaluationClaimsSlotSynchronouslyAndKeepsCancellationHandle() async {
        let runner = QualityComparisonRunner()
        var calls = 0
        var wasCancelled = false
        runner.summaryEvaluationOverride = {
            calls += 1
            do { try await Task.sleep(for: .seconds(30)) }
            catch { wasCancelled = Task.isCancelled }
        }
        runner.startSummaryEvaluation()
        runner.startSummaryEvaluation(personalOnly: true)
        #expect(runner.isRunning)
        #expect(runner.isEvaluatingSummary)
        runner.cancelSummaryEvaluation()
        await runner.waitForSummaryEvaluationForTesting()
        #expect(calls == 1)
        #expect(wasCancelled)
        #expect(!runner.isRunning && !runner.isEvaluatingSummary)
        runner.summaryEvaluationOverride = { calls += 1 }
        runner.startSummaryEvaluation()
        await runner.waitForSummaryEvaluationForTesting()
        #expect(calls == 2)
    }

    @Test func fictionalCasesIncludeLongInputAndManualExpectations() {
        let samples = SummaryQualityEvaluation.samples
        #expect(samples.count == 12)
        #expect(Set(samples.map(\.id)).count == samples.count)
        #expect(samples.allSatisfy { !$0.requiredFacts.isEmpty && !$0.prohibitedClaims.isEmpty })
        #expect(SummaryPrompt.splitForMapReduce(samples.last!.transcript).count > 1)
    }

    @Test func traceRecordsUsageWithoutRetainingPrivatePayloads() throws {
        let trace = AIGenerationTrace()
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpBody = Data(#"{"model":"fixture-model","max_tokens":8192,"messages":[{"content":"PRIVATE_PAYLOAD"}]}"#.utf8)
        request.setValue("SECRET", forHTTPHeaderField: "x-api-key")
        let id = trace.begin(request: request, provider: .claude)
        trace.observe(data: Data(#"{"type":"message_start","message":{"usage":{"input_tokens":72,"cache_read_input_tokens":12}}}"#.utf8), requestID: id)
        trace.observe(data: Data(#"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":25}}"#.utf8), requestID: id)
        trace.recordWait(.milliseconds(200))
        trace.finish(id)
        let snapshot = trace.snapshot()
        #expect(snapshot.requests[0].inputTokens == 72)
        #expect(snapshot.requests[0].outputTokens == 25)
        #expect(snapshot.requests[0].cacheReadTokens == 12)
        #expect(snapshot.gateWaitSeconds == 0.2)
        let encoded = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        #expect(!encoded.contains("PRIVATE_PAYLOAD"))
        #expect(!encoded.contains("SECRET"))
        #expect(!encoded.contains("api.anthropic.com"))
    }

    @Test func absentUsageStaysUnknownAndIdentityOverrideIsScoped() async {
        let trace = AIGenerationTrace()
        let id = trace.begin(request: URLRequest(url: URL(string: "https://example.com")!), provider: .openai)
        trace.finish(id)
        #expect(trace.snapshot().requests[0].inputTokens == nil)
        await SummaryPrompt.$evaluationUserName.withValue("") {
            #expect(!SummaryPrompt.system(language: "en").contains("The user's name is:"))
        }
    }
}
