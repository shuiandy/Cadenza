import AuthenticationServices
import Foundation
import Testing
@testable import Cadenza

@Suite("OAuthCoordinator")
struct OAuthCoordinatorTests {
    @MainActor
    @Test func secondCallWhileSessionInFlightThrowsAlreadyInProgress() async throws {
        let driver = HangingSessionDriver()
        let coordinator = OAuthCoordinator(
            sessionDriver: driver,
            timeout: .seconds(60),
            anchorProvider: { nil }
        )
        let url = URL(string: "https://cadenzapp.com/auth/desktop/start")!

        let firstCall = Task { @MainActor in try await coordinator.authorize(authorizeURL: url) }
        // Yield so the first task starts and grabs the active-session slot.
        try await Task.sleep(nanoseconds: 50_000_000)

        do {
            _ = try await coordinator.authorize(authorizeURL: url)
            Issue.record("expected .alreadyInProgress")
        } catch let error as AuthError {
            #expect(error == .alreadyInProgress)
        }

        // Free the first call: cancellation propagates into the driver's
        // `withTaskCancellationHandler`, which calls `cancel()` and resumes
        // the suspended continuation with `.cancelled`.
        firstCall.cancel()
        _ = try? await firstCall.value
        #expect(driver.cancelCount >= 1)
    }

    @MainActor
    @Test func sessionThatNeverCompletesThrowsCallbackTimeout() async throws {
        let driver = HangingSessionDriver()
        let coordinator = OAuthCoordinator(
            sessionDriver: driver,
            timeout: .milliseconds(150),
            anchorProvider: { nil }
        )
        let url = URL(string: "https://cadenzapp.com/auth/desktop/start")!

        do {
            _ = try await coordinator.authorize(authorizeURL: url)
            Issue.record("expected .callbackTimeout")
        } catch let error as AuthError {
            #expect(error == .callbackTimeout)
        }

        #expect(driver.cancelCount >= 1)  // coordinator cancelled the underlying session
    }
}

/// Test seam: a `SessionDriver` whose `start` never resolves until
/// `cancel()` runs (either via the coordinator's catch or via task
/// cancellation propagating through `withTaskCancellationHandler`).
@MainActor
final class HangingSessionDriver: OAuthCoordinator.SessionDriver {
    private(set) var cancelCount = 0
    private var continuations: [CheckedContinuation<URL, Error>] = []

    func start(authorizeURL: URL,
               callbackScheme: String,
               anchor: ASPresentationAnchor?) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
                continuations.append(cont)
            }
        } onCancel: { [weak self] in
            Task { @MainActor in self?.cancel() }
        }
    }

    func cancel() {
        cancelCount += 1
        for cont in continuations {
            cont.resume(throwing: AuthError.cancelled)
        }
        continuations.removeAll()
    }
}
