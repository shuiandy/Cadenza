import Foundation
import os
import Testing
@testable import Cadenza

@Suite("Google OAuth callback binding", .serialized)
struct GoogleCalendarOAuthTests {
    @MainActor
    @Test func successfulCallbackBindsStateAndPreservesExchangeInputs() async throws {
        let probe = GoogleOAuthProbe()
        let callbackServer = GoogleOAuthCallbackServerFake(
            behavior: .callback {
                let openedURL = try await waitForOpenedURL(in: probe)
                let state = try #require(queryValue(named: "state", in: openedURL))
                return OAuthCallbackServer.CallbackResult(code: "legitimate-code", state: state)
            },
            probe: probe
        )
        let service = makeService(callbackServer: callbackServer, probe: probe)
        service.openURLHandler = { url in probe.recordBrowserOpen(url) }

        try await service.connect()

        let openedURL = try #require(probe.openedURL)
        let state = try #require(queryValue(named: "state", in: openedURL))
        #expect(state.count == 43)
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        #expect(state.unicodeScalars.allSatisfy { allowed.contains($0) })

        let request = try #require(probe.exchangeRequests.first)
        #expect(request.code == "legitimate-code")
        #expect(request.clientID == "google-client-id")
        #expect(request.clientSecret == "google-client-secret")
        #expect(request.redirectURI == callbackServer.redirectURI)
        #expect(request.codeVerifier.count == 43)
        #expect(probe.storedTokens.map(\.accessToken) == ["access-token"])

        let events = probe.events
        let readyIndex = try #require(events.firstIndex(of: "listener-ready"))
        let browserIndex = try #require(events.firstIndex(of: "browser-open"))
        let exchangeIndex = try #require(events.firstIndex(of: "token-exchange"))
        let storeIndex = try #require(events.firstIndex(of: "token-store"))
        #expect(readyIndex < browserIndex)
        #expect(browserIndex < exchangeIndex)
        #expect(exchangeIndex < storeIndex)
        #expect(callbackServer.stopCount == 0)
        #expect(service.isConnecting == false)
    }

    @MainActor
    @Test func callbackWithoutStateIsRejectedBeforeTokenExchange() async throws {
        let probe = GoogleOAuthProbe()
        let callbackServer = GoogleOAuthCallbackServerFake(
            behavior: .callback {
                _ = try await waitForOpenedURL(in: probe)
                return OAuthCallbackServer.CallbackResult(code: "attacker-code", state: nil)
            },
            probe: probe
        )
        let service = makeService(
            callbackServer: callbackServer,
            probe: probe,
            stateGenerator: { "expected-state" }
        )
        service.openURLHandler = { url in probe.recordBrowserOpen(url) }

        await expectStateMismatch { try await service.connect() }

        #expect(probe.exchangeRequests.isEmpty)
        #expect(probe.storedTokens.isEmpty)
        #expect(callbackServer.stopCount == 0)
    }

    @MainActor
    @Test func callbackWithMismatchedStateIsRejectedBeforeTokenExchange() async throws {
        let probe = GoogleOAuthProbe()
        let callbackServer = GoogleOAuthCallbackServerFake(
            behavior: .callback {
                _ = try await waitForOpenedURL(in: probe)
                return OAuthCallbackServer.CallbackResult(code: "attacker-code", state: "attacker-state")
            },
            probe: probe
        )
        let service = makeService(
            callbackServer: callbackServer,
            probe: probe,
            stateGenerator: { "expected-state" }
        )
        service.openURLHandler = { url in probe.recordBrowserOpen(url) }

        await expectStateMismatch { try await service.connect() }

        #expect(probe.exchangeRequests.isEmpty)
        #expect(probe.storedTokens.isEmpty)
        #expect(callbackServer.stopCount == 0)
    }

    @MainActor
    @Test func callbackWithEmptyCodeIsRejectedBeforeTokenExchange() async throws {
        let probe = GoogleOAuthProbe()
        let callbackServer = GoogleOAuthCallbackServerFake(
            behavior: .callback {
                _ = try await waitForOpenedURL(in: probe)
                return OAuthCallbackServer.CallbackResult(code: "", state: "expected-state")
            },
            probe: probe
        )
        let service = makeService(
            callbackServer: callbackServer,
            probe: probe,
            stateGenerator: { "expected-state" }
        )
        service.openURLHandler = { url in probe.recordBrowserOpen(url) }

        do {
            try await service.connect()
            Issue.record("Expected invalid callback response")
        } catch let oauthError as OAuthError {
            guard case .invalidResponse = oauthError else {
                Issue.record("Expected invalidResponse, got \(oauthError)")
                return
            }
        } catch {
            Issue.record("Expected OAuthError.invalidResponse, got \(error)")
        }

        #expect(probe.exchangeRequests.isEmpty)
        #expect(probe.storedTokens.isEmpty)
        #expect(callbackServer.stopCount == 0)
    }

    @MainActor
    @Test func listenerFailureDoesNotOpenBrowserOrExchangeToken() async throws {
        let probe = GoogleOAuthProbe()
        let callbackServer = GoogleOAuthCallbackServerFake(
            behavior: .listenerFailure,
            probe: probe
        )
        let service = makeService(callbackServer: callbackServer, probe: probe)
        service.openURLHandler = { url in probe.recordBrowserOpen(url) }

        do {
            try await service.connect()
            Issue.record("Expected listener failure")
        } catch GoogleOAuthTestError.portInUse {
            // Expected.
        } catch {
            Issue.record("Expected portInUse, got \(error)")
        }

        #expect(probe.openedURL == nil)
        #expect(probe.exchangeRequests.isEmpty)
        #expect(probe.storedTokens.isEmpty)
        #expect(callbackServer.stopCount == 0)
    }

    @MainActor
    @Test func cancellationStopsListenerAndCompletesConnectTask() async throws {
        let probe = GoogleOAuthProbe()
        let callbackServer = GoogleOAuthCallbackServerFake(
            behavior: .suspendAfterReady,
            probe: probe
        )
        let service = makeService(callbackServer: callbackServer, probe: probe)
        service.openURLHandler = { url in probe.recordBrowserOpen(url) }

        let task = Task { @MainActor in
            try await service.connect()
        }
        let didStartWaiting = await waitUntil { callbackServer.isWaiting }
        #expect(didStartWaiting)

        task.cancel()

        do {
            try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }

        #expect(callbackServer.stopCount >= 1)
        #expect(probe.exchangeRequests.isEmpty)
        #expect(probe.storedTokens.isEmpty)
        #expect(service.isConnecting == false)
    }

    @MainActor
    @Test func cancellationDuringNonCooperativeTokenExchangeNeverStoresTokens() async throws {
        let probe = GoogleOAuthProbe()
        let exchangeGate = GoogleOAuthTokenExchangeGate()
        let callbackServer = GoogleOAuthCallbackServerFake(
            behavior: .callback {
                let openedURL = try await waitForOpenedURL(in: probe)
                let state = try #require(queryValue(named: "state", in: openedURL))
                return OAuthCallbackServer.CallbackResult(code: "legitimate-code", state: state)
            },
            probe: probe
        )
        let service = makeService(
            callbackServer: callbackServer,
            probe: probe,
            tokenExchange: { request in
                probe.recordTokenExchange(request)
                return await exchangeGate.wait()
            }
        )
        service.openURLHandler = { url in probe.recordBrowserOpen(url) }

        let task = Task { @MainActor in
            try await service.connect()
        }
        let exchangeStarted = await waitUntil { exchangeGate.isWaiting }
        #expect(exchangeStarted)

        task.cancel()
        exchangeGate.release(
            OAuthTokenManager.TokenData(
                accessToken: "cancelled-access-token",
                refreshToken: "cancelled-refresh-token",
                expiresAt: nil,
                tokenType: "Bearer",
                scope: nil
            )
        )

        do {
            try await task.value
            Issue.record("Expected cancellation after token exchange returned")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }

        #expect(probe.exchangeRequests.count == 1)
        #expect(probe.storedTokens.isEmpty)
        #expect(service.isConnecting == false)
    }

    @MainActor
    @Test func concurrentConnectCannotClearTheActiveAttemptState() async throws {
        let probe = GoogleOAuthProbe()
        let callbackServer = GoogleOAuthCallbackServerFake(
            behavior: .suspendAfterReady,
            probe: probe
        )
        let service = makeService(callbackServer: callbackServer, probe: probe)
        service.openURLHandler = { url in probe.recordBrowserOpen(url) }

        let activeTask = Task { @MainActor in
            try await service.connect()
        }
        let firstAttemptIsWaiting = await waitUntil { callbackServer.isWaiting }
        #expect(firstAttemptIsWaiting)

        do {
            try await service.connect()
            Issue.record("Expected concurrent callback rejection")
        } catch let oauthError as OAuthError {
            guard case .callbackInProgress = oauthError else {
                Issue.record("Expected callbackInProgress, got \(oauthError)")
                return
            }
        } catch {
            Issue.record("Expected OAuthError.callbackInProgress, got \(error)")
        }

        #expect(service.isConnecting)
        #expect(callbackServer.isWaiting)
        #expect(probe.events.filter { $0 == "browser-open" }.count == 1)

        activeTask.cancel()
        do {
            try await activeTask.value
            Issue.record("Expected active attempt cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }

        #expect(service.isConnecting == false)
    }

    @Test func cancellationBeforeContinuationInstallationIsRemembered() async throws {
        let callbackServer = OAuthCallbackServer(port: 48484)
        let attempt = await callbackServer.beginAttempt()

        // Deterministically exercise the pre-install window: cancellation is
        // delivered after the attempt exists but before wait installs its
        // checked continuation or creates an NWListener.
        await callbackServer.cancel(attempt)

        do {
            _ = try await callbackServer.waitForCallback(
                for: attempt,
                expectedState: "unused-state",
                onListenerReady: {
                    Issue.record("Cancelled attempt must not bind or become ready")
                }
            )
            Issue.record("Expected cancellation before listener installation")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
    }

    @Test func spoofedLoopbackRequestsCannotTerminateActiveAttempt() async throws {
        let expectedState = "expected-state"
        let callbackServer = OAuthCallbackServer(port: 48486)
        let (readyEvents, readyContinuation) = AsyncStream<Void>.makeStream()
        let callback = Task {
            try await callbackServer.waitForCallback(expectedState: expectedState) {
                readyContinuation.yield()
                readyContinuation.finish()
            }
        }
        defer { callback.cancel() }

        var readyIterator = readyEvents.makeAsyncIterator()
        _ = await readyIterator.next()

        let wrongState = URL(
            string: "http://localhost:48486/callback?error=access_denied&state=attacker-state"
        )!
        #expect(try await callbackHTTPStatus(for: wrongState) == 400)

        let wrongPath = URL(
            string: "http://localhost:48486/not-callback?code=attacker-code&state=expected-state"
        )!
        #expect(try await callbackHTTPStatus(for: wrongPath) == 400)

        let legitimate = URL(
            string: "http://localhost:48486/callback?code=legitimate-code&state=expected-state"
        )!
        #expect(try await callbackHTTPStatus(for: legitimate) == 200)

        let result = try await callback.value
        #expect(result.code == "legitimate-code")
        #expect(result.state == expectedState)
    }

    @Test func matchingStateAuthorizationDenialStillEndsAttempt() async throws {
        let expectedState = "expected-state"
        let callbackServer = OAuthCallbackServer(port: 48487)
        let (readyEvents, readyContinuation) = AsyncStream<Void>.makeStream()
        let callback = Task {
            try await callbackServer.waitForCallback(expectedState: expectedState) {
                readyContinuation.yield()
                readyContinuation.finish()
            }
        }
        defer { callback.cancel() }

        var readyIterator = readyEvents.makeAsyncIterator()
        _ = await readyIterator.next()

        let denial = URL(
            string: "http://localhost:48487/callback?error=access_denied&state=expected-state"
        )!
        #expect(try await callbackHTTPStatus(for: denial) == 200)

        do {
            _ = try await callback.value
            Issue.record("Expected authorization denial")
        } catch let error as OAuthError {
            guard case .authorizationDenied = error else {
                Issue.record("Expected authorizationDenied, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected OAuthError.authorizationDenied, got \(error)")
        }
    }

    @Test func staleCancellationCannotCancelReplacementAttempt() async {
        let callbackServer = OAuthCallbackServer(port: 48484)
        let firstAttempt = await callbackServer.beginAttempt()
        await callbackServer.cancel(firstAttempt)
        await expectCancelledAttempt(firstAttempt, on: callbackServer)

        let replacementAttempt = await callbackServer.beginAttempt()
        await callbackServer.cancel(firstAttempt)

        let replacementRemainsPending = await callbackServer.isPending(replacementAttempt)
        #expect(replacementRemainsPending)

        await callbackServer.cancel(replacementAttempt)
        await expectCancelledAttempt(replacementAttempt, on: callbackServer)
    }

    @MainActor
    @Test func consecutiveSuccessfulOAuthAttemptsRemainIndependent() async throws {
        let probe = GoogleOAuthProbe()
        let stateSequence = GoogleOAuthStateSequence(["state-1", "state-2"])
        let callbackServer = SequentialGoogleOAuthCallbackServerFake(probe: probe)
        let service = makeService(
            callbackServer: callbackServer,
            probe: probe,
            stateGenerator: { stateSequence.next() }
        )
        service.openURLHandler = { url in probe.recordBrowserOpen(url) }

        try await service.connect()
        try await service.connect()

        #expect(probe.exchangeRequests.map(\.code) == ["code-1", "code-2"])
        #expect(probe.storedTokens.count == 2)
    }

    // MARK: - Helpers

    private func expectCancelledAttempt(
        _ attempt: OAuthCallbackServer.Attempt,
        on callbackServer: OAuthCallbackServer
    ) async {
        do {
            _ = try await callbackServer.waitForCallback(
                for: attempt,
                expectedState: "unused-state"
            )
            Issue.record("Expected attempt cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
    }

    @MainActor
    private func makeService(
        callbackServer: any OAuthCallbackServing,
        probe: GoogleOAuthProbe,
        stateGenerator: @escaping @Sendable () -> String = PKCE.generateVerifier,
        tokenExchange: GoogleCalendarService.TokenExchange? = nil
    ) -> GoogleCalendarService {
        GoogleCalendarService(
            tokenManager: OAuthTokenManager(),
            callbackServer: callbackServer,
            credentialsProvider: {
                GoogleCalendarService.OAuthCredentials(
                    clientID: "google-client-id",
                    clientSecret: "google-client-secret"
                )
            },
            stateGenerator: stateGenerator,
            tokenExchange: tokenExchange ?? { request in
                probe.recordTokenExchange(request)
                return OAuthTokenManager.TokenData(
                    accessToken: "access-token",
                    refreshToken: "refresh-token",
                    expiresAt: nil,
                    tokenType: "Bearer",
                    scope: nil
                )
            },
            tokenStore: { tokens in
                probe.recordTokenStore(tokens)
            }
        )
    }

    @MainActor
    private func expectStateMismatch(
        _ operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            Issue.record("Expected state mismatch")
        } catch let oauthError as OAuthError {
            guard case .stateMismatch = oauthError else {
                Issue.record("Expected stateMismatch, got \(oauthError)")
                return
            }
        } catch {
            Issue.record("Expected OAuthError.stateMismatch, got \(error)")
        }
    }
}

private enum GoogleOAuthTestError: Error, Sendable {
    case portInUse
    case browserDidNotOpen
}

private final class GoogleOAuthStateSequence: Sendable {
    private let values: OSAllocatedUnfairLock<[String]>

    init(_ values: [String]) {
        self.values = OSAllocatedUnfairLock(initialState: values)
    }

    func next() -> String {
        values.withLock { values in
            precondition(!values.isEmpty, "No OAuth state value configured")
            return values.removeFirst()
        }
    }
}

private final class GoogleOAuthProbe: Sendable {
    private struct State {
        var events: [String] = []
        var openedURL: URL?
        var exchangeRequests: [GoogleCalendarService.TokenExchangeRequest] = []
        var storedTokens: [OAuthTokenManager.TokenData] = []
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    var events: [String] {
        lock.withLock { $0.events }
    }

    var openedURL: URL? {
        lock.withLock { $0.openedURL }
    }

    var exchangeRequests: [GoogleCalendarService.TokenExchangeRequest] {
        lock.withLock { $0.exchangeRequests }
    }

    var storedTokens: [OAuthTokenManager.TokenData] {
        lock.withLock { $0.storedTokens }
    }

    func record(_ event: String) {
        lock.withLock { $0.events.append(event) }
    }

    func recordBrowserOpen(_ url: URL) {
        lock.withLock {
            $0.openedURL = url
            $0.events.append("browser-open")
        }
    }

    func recordTokenExchange(_ request: GoogleCalendarService.TokenExchangeRequest) {
        lock.withLock {
            $0.exchangeRequests.append(request)
            $0.events.append("token-exchange")
        }
    }

    func recordTokenStore(_ tokens: OAuthTokenManager.TokenData) {
        lock.withLock {
            $0.storedTokens.append(tokens)
            $0.events.append("token-store")
        }
    }
}

private final class GoogleOAuthTokenExchangeGate: Sendable {
    private struct State {
        var continuation: CheckedContinuation<OAuthTokenManager.TokenData, Never>?
        var releasedTokens: OAuthTokenManager.TokenData?
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    var isWaiting: Bool {
        lock.withLock { $0.continuation != nil }
    }

    func wait() async -> OAuthTokenManager.TokenData {
        await withCheckedContinuation { continuation in
            let releasedTokens: OAuthTokenManager.TokenData? = lock.withLock { state in
                if let releasedTokens = state.releasedTokens {
                    state.releasedTokens = nil
                    return releasedTokens
                }
                state.continuation = continuation
                return nil
            }
            if let releasedTokens {
                continuation.resume(returning: releasedTokens)
            }
        }
    }

    func release(_ tokens: OAuthTokenManager.TokenData) {
        let continuation = lock.withLock { state in
            let continuation = state.continuation
            state.continuation = nil
            if continuation == nil {
                state.releasedTokens = tokens
            }
            return continuation
        }
        continuation?.resume(returning: tokens)
    }
}

private final class GoogleOAuthCallbackServerFake: OAuthCallbackServing {
    enum Behavior: Sendable {
        case callback(@Sendable () async throws -> OAuthCallbackServer.CallbackResult)
        case listenerFailure
        case suspendAfterReady
    }

    private struct State {
        var stopCount = 0
        var waitInProgress = false
        var pendingAttempts: Set<UUID> = []
        var cancelledAttempts: Set<UUID> = []
        var waitingAttempt: UUID?
        var waitingContinuation: CheckedContinuation<OAuthCallbackServer.CallbackResult, Error>?
    }

    let redirectURI = "http://localhost:48484/callback"

    private let behavior: Behavior
    private let probe: GoogleOAuthProbe
    private let lock = OSAllocatedUnfairLock(initialState: State())

    init(behavior: Behavior, probe: GoogleOAuthProbe) {
        self.behavior = behavior
        self.probe = probe
    }

    var stopCount: Int {
        lock.withLock { $0.stopCount }
    }

    var isWaiting: Bool {
        lock.withLock { $0.waitingContinuation != nil }
    }

    func waitForCallback(
        expectedState: String,
        onListenerReady: (@Sendable () -> Void)?
    ) async throws -> OAuthCallbackServer.CallbackResult {
        let accepted = lock.withLock { state in
            guard !state.waitInProgress else { return false }
            state.waitInProgress = true
            return true
        }
        guard accepted else { throw OAuthError.callbackInProgress }

        let attempt = UUID()
        _ = lock.withLock { $0.pendingAttempts.insert(attempt) }
        defer {
            finish(attempt)
            lock.withLock { $0.waitInProgress = false }
        }

        probe.record("wait-for-callback")

        return try await withTaskCancellationHandler {
            switch behavior {
            case .callback(let result):
                probe.record("listener-ready")
                onListenerReady?()
                let callback = try await result()
                try Task.checkCancellation()
                return callback
            case .listenerFailure:
                throw GoogleOAuthTestError.portInUse
            case .suspendAfterReady:
                probe.record("listener-ready")
                onListenerReady?()
                return try await withCheckedThrowingContinuation { continuation in
                    let wasCancelled = lock.withLock { state in
                        state.pendingAttempts.remove(attempt)
                        if state.cancelledAttempts.remove(attempt) != nil {
                            return true
                        }
                        state.waitingAttempt = attempt
                        state.waitingContinuation = continuation
                        return false
                    }
                    if wasCancelled {
                        continuation.resume(throwing: CancellationError())
                    }
                }
            }
        } onCancel: {
            cancel(attempt)
        }
    }

    private func cancel(_ attempt: UUID) {
        let continuation: CheckedContinuation<OAuthCallbackServer.CallbackResult, Error>? = lock.withLock { state in
            state.stopCount += 1
            if state.pendingAttempts.remove(attempt) != nil {
                state.cancelledAttempts.insert(attempt)
                return nil
            }
            guard state.waitingAttempt == attempt else { return nil }
            state.waitingAttempt = nil
            let continuation = state.waitingContinuation
            state.waitingContinuation = nil
            return continuation
        }
        continuation?.resume(throwing: CancellationError())
    }

    private func finish(_ attempt: UUID) {
        lock.withLock { state in
            _ = state.pendingAttempts.remove(attempt)
            _ = state.cancelledAttempts.remove(attempt)
            if state.waitingAttempt == attempt {
                state.waitingAttempt = nil
                state.waitingContinuation = nil
            }
        }
    }
}

private final class SequentialGoogleOAuthCallbackServerFake: OAuthCallbackServing {
    private struct State {
        var callbackCount = 0
    }

    let redirectURI = "http://localhost:48484/callback"

    private let probe: GoogleOAuthProbe
    private let lock = OSAllocatedUnfairLock(initialState: State())

    init(probe: GoogleOAuthProbe) {
        self.probe = probe
    }

    func waitForCallback(
        expectedState: String,
        onListenerReady: (@Sendable () -> Void)?
    ) async throws -> OAuthCallbackServer.CallbackResult {
        let callbackNumber = lock.withLock { state in
            state.callbackCount += 1
            return state.callbackCount
        }

        probe.record("listener-ready")
        onListenerReady?()
        await Task.yield()
        return OAuthCallbackServer.CallbackResult(
            code: "code-\(callbackNumber)",
            state: expectedState
        )
    }
}

private func callbackHTTPStatus(for url: URL) async throws -> Int {
    let (_, response) = try await URLSession.shared.data(from: url)
    return (response as? HTTPURLResponse)?.statusCode ?? -1
}

private func queryValue(named name: String, in url: URL) -> String? {
    URLComponents(url: url, resolvingAgainstBaseURL: false)?
        .queryItems?
        .first(where: { $0.name == name })?
        .value
}

private func waitForOpenedURL(in probe: GoogleOAuthProbe) async throws -> URL {
    let didOpen = await waitUntil { probe.openedURL != nil }
    guard didOpen, let openedURL = probe.openedURL else {
        throw GoogleOAuthTestError.browserDidNotOpen
    }
    return openedURL
}

private func waitUntil(
    timeout: Duration = .seconds(1),
    condition: @escaping @Sendable () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return true }
        await Task.yield()
    }
    return condition()
}
