import os
import Testing

@testable import Cadenza

@Suite("Zoom secure disconnect")
@MainActor
struct ZoomDisconnectTests {
    private enum RemovalError: Error, LocalizedError {
        case failed

        var errorDescription: String? { "test keychain removal failure" }
    }

    @Test func tokenRemovalFailureRemainsVisibleWhileConnectionStillExists() {
        let service = ZoomMeetingService(
            tokenManager: OAuthTokenManager(),
            tokenRemover: { throw RemovalError.failed }
        )

        #expect(throws: RemovalError.failed) {
            try service.disconnect()
        }
        #expect(service.error?.contains("secure tokens could not be removed") == true)

        let presentation = GoogleCalendarConnectionPresentation.make(
            isConnected: true,
            isConnecting: false,
            error: service.error
        )
        #expect(presentation.phase == .error)
    }

    @Test func successfulRetryClearsThePreviousFailure() throws {
        let shouldFail = OSAllocatedUnfairLock(initialState: true)
        let service = ZoomMeetingService(
            tokenManager: OAuthTokenManager(),
            tokenRemover: {
                if shouldFail.withLock({ $0 }) { throw RemovalError.failed }
            }
        )

        #expect(throws: RemovalError.failed) {
            try service.disconnect()
        }
        shouldFail.withLock { $0 = false }
        try service.disconnect()

        #expect(service.error == nil)
    }
}
