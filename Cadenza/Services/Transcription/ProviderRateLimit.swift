import Foundation

/// What an HTTP 429 from a transcription provider says about when a retry
/// could succeed.
///
/// Gemini and OpenAI both answer 429 for a per-minute burst, for a spent
/// daily cap, and (OpenAI) for an account with no credit left, and only the
/// body tells them apart. `HardenedAITransport` keeps that body (at most
/// 2 KB, credentials redacted) in `AIServiceError.httpError` and drops every
/// response header, so `Retry-After` is not available. The body is read here
/// only to classify; it never reaches a user-visible string.
enum ProviderRateLimit: Equatable, Sendable {
    /// A per-minute burst, or a 429 whose body says nothing recognisable.
    /// The transcribers' 2 s and 4 s backoff may outlast it.
    case shortWindow
    /// A daily (or similarly long) window. A live Gemini Tier 1 response
    /// named "100 requests per day" and asked to "retry in 5h42m48s";
    /// retrying spends more of the same cap and still fails.
    case longWindow
    /// OpenAI's `insufficient_quota`: the account is out of credit or over
    /// its spending limit. No wait fixes it.
    case quotaExhausted

    /// Retry hints at least this long outlast any per-minute window and the
    /// few seconds of backoff the transcribers use.
    static let longWindowRetryHint: TimeInterval = 5 * 60

    /// Nil unless `error` is an HTTP 429.
    init?(error: Error) {
        guard case AIServiceError.httpError(429, let body) = error else { return nil }
        self.init(body: body)
    }

    init(body: String) {
        let lowered = body.lowercased()
        if lowered.contains("insufficient_quota") {
            self = .quotaExhausted
        } else if Self.namesDailyWindow(lowered) {
            self = .longWindow
        } else if let hint = Self.retryHint(in: body), hint >= Self.longWindowRetryHint {
            self = .longWindow
        } else {
            self = .shortWindow
        }
    }

    /// The user-facing failure for a limit retrying cannot outlast.
    func transcriptionError(provider: AIProvider) -> TranscriptionError? {
        switch self {
        case .shortWindow: nil
        case .longWindow: .dailyQuotaReached(provider)
        case .quotaExhausted: .accountQuotaExhausted(provider)
        }
    }

    /// Gemini's "requests per day" or a google.rpc.QuotaFailure id such as
    /// `GenerateRequestsPerDayPerProjectPerModel`; OpenAI's "requests per day
    /// (RPD)" or "tokens per day (TPD)".
    private static func namesDailyWindow(_ lowered: String) -> Bool {
        ["per day", "perday", "per_day", "daily"].contains { lowered.contains($0) }
    }

    /// The longest wait the body asks for, in seconds. Gemini writes "retry in
    /// 5h42m48s" and, on generateContent, a google.rpc.RetryInfo
    /// "retryDelay": "20568s"; OpenAI writes "Please try again in 7m12s" or
    /// "in 120ms". All use Go duration notation; anything else yields nil so
    /// an unrecognised 429 keeps the retry behaviour.
    static func retryHint(in body: String) -> TimeInterval? {
        var hints: [TimeInterval] = []
        let phrase = /(?:retry|try again) (?:in|after) ((?:\d+(?:\.\d+)?(?:ms|h|m|s))+)/.ignoresCase()
        for match in body.matches(of: phrase) {
            hints.append(goDurationSeconds(match.1))
        }
        for match in body.matches(of: /"retryDelay"\s*:\s*"(\d+(?:\.\d+)?)s"/) {
            if let seconds = TimeInterval(match.1) { hints.append(seconds) }
        }
        return hints.max()
    }

    private static func goDurationSeconds(_ text: Substring) -> TimeInterval {
        var total: TimeInterval = 0
        for match in text.matches(of: /(\d+(?:\.\d+)?)(ms|h|m|s)/) {
            let value = TimeInterval(match.1) ?? 0
            switch match.2 {
            case "h": total += value * 3_600
            case "m": total += value * 60
            case "s": total += value
            default: total += value / 1_000
            }
        }
        return total
    }
}
