import Foundation
import Testing

@testable import Cadenza

// Fixture bodies follow the shapes Gemini and OpenAI use for 429s; the
// limits, tiers, organisations, metrics and links are invented.

@Suite("Provider 429 classification")
struct ProviderRateLimitTests {
    static let longWindowBodies = [
        // Gemini Interactions API: the window in prose, a long retry hint.
        #"{"error":{"message":"Rate limit exceeded for model gemini-3.5-transcribe (limit: 40 requests per day on Tier 7). Please retry in 3h07m12s or upgrade your tier at https://example.invalid/rate-limit.","code":"too_many_requests"}}"#,
        // Gemini generateContent: a per-day quota id, even with a short RetryInfo.
        #"{"error":{"code":429,"message":"Quota exceeded for metric: example_requests, limit: 25. Please retry in 41.2s.","status":"RESOURCE_EXHAUSTED","details":[{"@type":"type.googleapis.com/google.rpc.QuotaFailure","violations":[{"quotaMetric":"example_requests","quotaId":"GenerateRequestsPerDayPerProjectPerModel-ExampleTier"}]},{"@type":"type.googleapis.com/google.rpc.RetryInfo","retryDelay":"41s"}]}}"#,
        #"{"error":{"code":429,"message":"Quota exceeded. Please retry in 2h0m0s.","status":"RESOURCE_EXHAUSTED"}}"#,
        #"{"error":{"code":429,"status":"RESOURCE_EXHAUSTED","details":[{"@type":"type.googleapis.com/google.rpc.RetryInfo","retryDelay":"20568s"}]}}"#,
        #"{"error":{"message":"Too many requests. Please retry in 5m0s.","code":"too_many_requests"}}"#,
        // OpenAI requests-per-day and tokens-per-day limits.
        #"{"error":{"message":"Rate limit reached for gpt-4o-transcribe in organization org-example123 on requests per day (RPD): Limit 50, Used 50, Requested 1. Please try again in 28m48s. Visit https://example.invalid/rate-limits to learn more.","type":"requests","param":null,"code":"rate_limit_exceeded"}}"#,
        #"{"error":{"message":"Rate limit reached for gpt-4o-transcribe in organization org-example123 on tokens per day (TPD): Limit 90000, Used 89950, Requested 300. Please try again in 1m4s.","type":"tokens","param":null,"code":"rate_limit_exceeded"}}"#,
        // OpenAI with no window named but a long wait.
        #"{"error":{"message":"Rate limit reached for gpt-4o-transcribe. Please try again in 12m0s.","type":"requests","param":null,"code":"rate_limit_exceeded"}}"#,
    ]

    static let shortWindowBodies = [
        #"{"error":{"code":429,"message":"Quota exceeded for metric: example_requests, limit: 5. Please retry in 12.5s.","status":"RESOURCE_EXHAUSTED","details":[{"@type":"type.googleapis.com/google.rpc.QuotaFailure","violations":[{"quotaId":"GenerateRequestsPerMinutePerProjectPerModel-ExampleTier"}]},{"@type":"type.googleapis.com/google.rpc.RetryInfo","retryDelay":"12s"}]}}"#,
        // Gemini also says "check your plan and billing" on per-minute limits,
        // so only OpenAI's insufficient_quota code may mean an empty account.
        #"{"error":{"code":429,"message":"You exceeded your current quota, please check your plan and billing details. Quota exceeded for metric: example_requests, limit: 5. Please retry in 9s.","status":"RESOURCE_EXHAUSTED"}}"#,
        #"{"error":{"message":"Too many requests. Please retry in 4m59s.","code":"too_many_requests"}}"#,
        #"{"error":{"code":429,"message":"Resource has been exhausted (e.g. check quota).","status":"RESOURCE_EXHAUSTED"}}"#,
        #"{"error":{"message":"Rate limit reached for gpt-4o-transcribe in organization org-example123 on requests per min (RPM): Limit 3, Used 3, Requested 1. Please try again in 20s. Visit https://example.invalid/rate-limits to learn more.","type":"requests","param":null,"code":"rate_limit_exceeded"}}"#,
        #"{"error":{"message":"Rate limit reached for gpt-4o-transcribe in organization org-example123 on tokens per min (TPM): Limit 40000, Used 39800, Requested 900. Please try again in 1.05s.","type":"tokens","param":null,"code":"rate_limit_exceeded"}}"#,
        "provider failure",
        "HTTP 429",
    ]

    static let insufficientQuotaBody = #"{"error":{"message":"You exceeded your current quota, please check your plan and billing details. For more information on this error, read the docs: https://example.invalid/error-codes.","type":"insufficient_quota","param":null,"code":"insufficient_quota"}}"#

    @Test(arguments: longWindowBodies)
    func longWindow429IsNeverRetried(_ body: String) {
        #expect(ProviderRateLimit(body: body) == .longWindow)
        #expect(!Self.eitherTranscriberRetries(AIServiceError.httpError(429, body)))
    }

    @Test(arguments: shortWindowBodies)
    func shortWindow429StaysRetryable(_ body: String) {
        #expect(ProviderRateLimit(body: body) == .shortWindow)
        let error = AIServiceError.httpError(429, body)
        #expect(GeminiTranscriber.isRetryableRequestError(error))
        #expect(WhisperTranscriber.isRetryableRequestError(error))
    }

    @Test func insufficientQuotaIsAnEmptyAccountNotAWindow() {
        #expect(ProviderRateLimit(body: Self.insufficientQuotaBody) == .quotaExhausted)
        #expect(!Self.eitherTranscriberRetries(AIServiceError.httpError(429, Self.insufficientQuotaBody)))
    }

    @Test func onlyA429IsClassified() throws {
        let daily = try #require(Self.longWindowBodies.first)
        #expect(ProviderRateLimit(error: AIServiceError.httpError(503, daily)) == nil)
        #expect(ProviderRateLimit(error: AITransportError.requestFailed) == nil)
        #expect(GeminiTranscriber.isRetryableRequestError(AIServiceError.httpError(503, daily)))
        #expect(WhisperTranscriber.isRetryableRequestError(AIServiceError.httpError(503, daily)))
        #expect(!Self.eitherTranscriberRetries(AIServiceError.httpError(400, daily)))
    }

    @Test func limitsMapToProviderNamedErrors() {
        #expect(ProviderRateLimit.shortWindow.transcriptionError(provider: .gemini) == nil)
        guard case .dailyQuotaReached(.gemini)? =
                ProviderRateLimit.longWindow.transcriptionError(provider: .gemini) else {
            Issue.record("a long window should become dailyQuotaReached(.gemini)")
            return
        }
        guard case .accountQuotaExhausted(.openai)? =
                ProviderRateLimit.quotaExhausted.transcriptionError(provider: .openai) else {
            Issue.record("an empty account should become accountQuotaExhausted(.openai)")
            return
        }
    }

    @Test func quotaMessagesNameTheProviderAndNothingFromTheBody() throws {
        let english = Locale(identifier: "en")
        let geminiDaily = TranscriptionError.dailyQuotaReached(.gemini).localizedMessage(locale: english)
        let openAIDaily = TranscriptionError.dailyQuotaReached(.openai).localizedMessage(locale: english)
        let openAIAccount = TranscriptionError.accountQuotaExhausted(.openai).localizedMessage(locale: english)

        #expect(geminiDaily.hasPrefix("The Gemini daily transcription quota has been reached."))
        #expect(!geminiDaily.contains("(Google)"))
        #expect(openAIDaily.hasPrefix("The OpenAI daily transcription quota has been reached."))
        #expect(openAIAccount.hasPrefix("The OpenAI account for this API key has run out of credit"))
        for message in [geminiDaily, openAIDaily, openAIAccount] {
            for providerText in ["per day", "RPD", "org-example123", "insufficient_quota", "example.invalid"] {
                #expect(!message.contains(providerText))
            }
        }
    }

    @Test(arguments: [
        ("Please retry in 5h42m48s or upgrade.", 20_568 as TimeInterval?),
        ("Please retry in 38.5s.", 38.5),
        ("retry in 500ms", 0.5),
        ("Retry after 1m30s", 90),
        ("Please try again in 28m48s. Visit", 1_728),
        ("Please try again in 120ms.", 0.12),
        (#""retryDelay": "20568s""#, 20_568),
        (#"retry in 12s, "retryDelay":"7200s""#, 7_200),
        ("retry in 6 hours", nil),
        ("rate limited", nil),
    ])
    func retryHintReadsGoDurations(_ body: String, _ expected: TimeInterval?) {
        #expect(ProviderRateLimit.retryHint(in: body) == expected)
    }

    private static func eitherTranscriberRetries(_ error: Error) -> Bool {
        GeminiTranscriber.isRetryableRequestError(error)
            || WhisperTranscriber.isRetryableRequestError(error)
    }
}
