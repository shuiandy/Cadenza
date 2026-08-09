import Foundation

enum WebSyncRetryDisposition: Sendable, Equatable {
    case pauseForAuthentication
    case retry(after: TimeInterval)
    case permanent
}

enum WebSyncRetryPolicy {
    private static let delays: [TimeInterval] = [60, 300, 1_800, 7_200, 43_200]

    static func disposition(
        statusCode: Int,
        attempt: Int,
        isInitialStructuredUpsert: Bool = false
    ) -> WebSyncRetryDisposition {
        if statusCode == 401 { return .pauseForAuthentication }
        if (statusCode == 404 && isInitialStructuredUpsert)
            || statusCode == 408
            || statusCode == 429
            || statusCode >= 500 {
            return .retry(after: delays[min(max(attempt, 0), delays.count - 1)])
        }
        return .permanent
    }
}
