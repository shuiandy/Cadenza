import Testing
@testable import Cadenza

@Suite("OpenAI Request Body")
struct OpenAIRequestBodyTests {
    private let messages = [["role": "user", "content": "Hello"]]

    @Test func gpt56SummaryUsesQualityDefaultWithoutLegacySampling() {
        let body = OpenAIService.makeRequestBody(
            provider: .openai,
            modelID: "gpt-5.6",
            messages: messages,
            purpose: .summary
        )

        #expect(body["model"] as? String == "gpt-5.6")
        #expect(body["temperature"] == nil)
        #expect(body["reasoning_effort"] == nil)
        #expect(body["stream"] == nil)
    }

    @Test func gpt56TerraChatPreservesNoReasoningLatencyBaseline() {
        let body = OpenAIService.makeRequestBody(
            provider: .openai,
            modelID: "gpt-5.6-terra",
            messages: messages,
            purpose: .chat,
            stream: true
        )

        #expect(body["reasoning_effort"] as? String == "none")
        #expect(body["temperature"] == nil)
        #expect(body["stream"] as? Bool == true)
    }

    @Test func gpt6SolKeepsDefaultReasoningForSummaryAndDropsItForChat() {
        let summary = OpenAIService.makeRequestBody(
            provider: .openai,
            modelID: "gpt-6-sol",
            messages: messages,
            purpose: .summary
        )
        #expect(summary["reasoning_effort"] == nil)
        #expect(summary["temperature"] == nil)

        let chat = OpenAIService.makeRequestBody(
            provider: .openai,
            modelID: "gpt-6-sol",
            messages: messages,
            purpose: .chat,
            stream: true
        )
        #expect(chat["reasoning_effort"] as? String == "none")
        #expect(chat["temperature"] == nil)
    }

    @Test func gpt6AstraChatUsesLowBecauseItRejectsNone() {
        let body = OpenAIService.makeRequestBody(
            provider: .openai,
            modelID: "gpt-6-astra",
            messages: messages,
            purpose: .chat
        )

        #expect(body["reasoning_effort"] as? String == "low")
        #expect(body["temperature"] == nil)
    }

    @Test func unverifiedOpenAIModelGetsNoReasoningField() {
        #expect(OpenAIService.lowestReasoningEffort(modelID: "gpt-6-terra") == nil)
        #expect(OpenAIService.lowestReasoningEffort(modelID: "gpt-6-sol-preview") == nil)
        #expect(OpenAIService.lowestReasoningEffort(modelID: "gpt-5.6-sol") == "none")
    }

    @Test func legacyOpenAIModelOmitsOptionalSampling() {
        let body = OpenAIService.makeRequestBody(
            provider: .openai,
            modelID: "gpt-5.5",
            messages: messages,
            purpose: .summary
        )

        #expect(body["temperature"] == nil)
        #expect(body["reasoning_effort"] == nil)
    }

    @Test func minimaxCompatibleEndpointIsNotGivenOpenAIReasoningFields() {
        let body = OpenAIService.makeRequestBody(
            provider: .minimax,
            modelID: "MiniMax-M3",
            messages: messages,
            purpose: .chat,
            stream: true
        )

        #expect(body["temperature"] as? Double == 0.3)
        #expect(body["reasoning_effort"] == nil)
    }
}
