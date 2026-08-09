import Foundation
import Network

protocol OAuthCallbackServing: Sendable {
    var redirectURI: String { get }

    /// Waits for one callback attempt. Implementations own cancellation and
    /// must ensure cancellation cannot be lost before listener installation.
    func waitForCallback(
        expectedState: String,
        onListenerReady: (@Sendable () -> Void)?
    ) async throws -> OAuthCallbackServer.CallbackResult
}

/// Lightweight loopback HTTP server to capture OAuth redirect callbacks.
///
/// Binds explicitly to 127.0.0.1 (loopback) so it is not reachable from any
/// other interface. The server stays up until either a callback arrives, the
/// 120s timeout fires, or its attempt is cancelled.
actor OAuthCallbackServer {
    struct Attempt: Hashable, Sendable {
        fileprivate let id = UUID()
    }

    /// Result returned to the caller of `waitForCallback`.
    struct CallbackResult: Sendable {
        let code: String
        /// `state` value as it appeared in the redirect URI (nil if absent).
        let state: String?
    }

    private enum AttemptPhase {
        case pending
        case active
        case cancelled
    }

    // All lifecycle state below is actor-isolated. `networkQueue` only
    // receives Network.framework callbacks and forwards them to this actor.
    private var attempts: [Attempt: AttemptPhase] = [:]
    private var activeAttempt: Attempt?
    private var listener: NWListener?
    private var continuation: CheckedContinuation<CallbackResult, Error>?
    private var readyFired = false
    private var timeoutTask: Task<Void, Never>?
    private let port: UInt16
    private let networkQueue = DispatchQueue(label: "com.shuiandy.Cadenza.oauth-callback")

    nonisolated let redirectURI: String

    init(port: UInt16 = 8484) {
        self.port = port
        self.redirectURI = "http://localhost:\(port)/callback"
    }

    /// Start the loopback server and wait for the OAuth callback.
    /// `onListenerReady` (if provided) is invoked exactly once by this actor
    /// after the listener has successfully bound — that is the safe moment
    /// to launch the user's browser. Times out after 120 seconds.
    func waitForCallback(
        expectedState: String,
        onListenerReady: (@Sendable () -> Void)? = nil
    ) async throws -> CallbackResult {
        let attempt = beginAttempt()
        return try await withTaskCancellationHandler {
            let result = try await waitForCallback(
                for: attempt,
                expectedState: expectedState,
                onListenerReady: onListenerReady
            )
            try Task.checkCancellation()
            return result
        } onCancel: {
            Task { await self.cancel(attempt) }
        }
    }

    /// Registers an attempt before a cancellation handler is installed. The
    /// actor-owned pending phase is what lets cancellation be remembered even
    /// if it wins the race with continuation installation.
    func beginAttempt() -> Attempt {
        let attempt = Attempt()
        attempts[attempt] = .pending
        return attempt
    }

    /// Installs the continuation/listener for a previously registered attempt.
    /// Internal visibility keeps the pre-install cancellation transition
    /// directly testable without opening a real listener or browser.
    func waitForCallback(
        for attempt: Attempt,
        expectedState: String,
        onListenerReady: (@Sendable () -> Void)? = nil
    ) async throws -> CallbackResult {
        return try await withCheckedThrowingContinuation { continuation in
            install(
                attempt,
                expectedState: expectedState,
                continuation: continuation,
                onListenerReady: onListenerReady
            )
        }
    }

    /// Cancels exactly one attempt. If installation has not happened yet, the
    /// cancelled phase is retained and consumed when its continuation arrives.
    func cancel(_ attempt: Attempt) {
        switch attempts[attempt] {
        case .pending:
            attempts[attempt] = .cancelled
        case .active:
            finish(attempt, throwing: CancellationError())
        case .cancelled, nil:
            break
        }
    }

    func isPending(_ attempt: Attempt) -> Bool {
        guard case .pending = attempts[attempt] else { return false }
        return true
    }

    private func install(
        _ attempt: Attempt,
        expectedState: String,
        continuation: CheckedContinuation<CallbackResult, Error>,
        onListenerReady: (@Sendable () -> Void)?
    ) {
        switch attempts[attempt] {
        case .cancelled:
            attempts.removeValue(forKey: attempt)
            continuation.resume(throwing: CancellationError())
            return
        case .pending:
            break
        case .active, nil:
            continuation.resume(throwing: OAuthError.invalidResponse)
            return
        }

        guard activeAttempt == nil else {
            attempts.removeValue(forKey: attempt)
            continuation.resume(throwing: OAuthError.callbackInProgress)
            return
        }

        attempts[attempt] = .active
        activeAttempt = attempt
        self.continuation = continuation
        readyFired = false

        do {
            let params = NWParameters.tcp
            // Restrict to loopback only — never bind 0.0.0.0/::.
            params.requiredInterfaceType = .loopback
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            self.listener = listener

            listener.newConnectionHandler = { [weak self] connection in
                Task {
                    await self?.handleConnection(
                        connection,
                        for: attempt,
                        expectedState: expectedState
                    )
                }
            }

            listener.stateUpdateHandler = { [weak self] state in
                Task {
                    await self?.listenerStateDidChange(
                        state,
                        for: attempt,
                        onListenerReady: onListenerReady
                    )
                }
            }

            listener.start(queue: networkQueue)

            timeoutTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(120))
                } catch {
                    return
                }
                await self?.timeout(attempt)
            }
        } catch {
            finish(attempt, throwing: error)
        }
    }

    private func listenerStateDidChange(
        _ state: NWListener.State,
        for attempt: Attempt,
        onListenerReady: (@Sendable () -> Void)?
    ) {
        guard activeAttempt == attempt else { return }
        switch state {
        case .ready:
            if !readyFired {
                readyFired = true
                onListenerReady?()
            }
        case .failed(let error):
            finish(attempt, throwing: error)
        default:
            break
        }
    }

    private func timeout(_ attempt: Attempt) {
        guard activeAttempt == attempt else { return }
        finish(attempt, throwing: OAuthError.callbackTimeout)
    }

    /// Tears down the listener and resumes the continuation if still pending.
    private func finishActiveAttempt(_ attempt: Attempt, throwing error: Error?) {
        guard activeAttempt == attempt else { return }
        if let error, let cont = continuation {
            cont.resume(throwing: error)
        }
        continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        listener?.cancel()
        listener = nil
        activeAttempt = nil
        attempts.removeValue(forKey: attempt)
    }

    /// Convenience: tear down with a thrown error (continuation gets `error`).
    private func finish(_ attempt: Attempt, throwing error: Error) {
        finishActiveAttempt(attempt, throwing: error)
    }

    /// Convenience: tear down on success — continuation already resumed.
    private func finishSuccess(_ attempt: Attempt) {
        finishActiveAttempt(attempt, throwing: nil)
    }

    private func handleConnection(
        _ connection: NWConnection,
        for attempt: Attempt,
        expectedState: String
    ) {
        guard activeAttempt == attempt else {
            connection.cancel()
            return
        }
        connection.start(queue: networkQueue)

        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, error in
            Task {
                await self?.received(
                    data,
                    error: error,
                    from: connection,
                    for: attempt,
                    expectedState: expectedState
                )
            }
        }
    }

    private func received(
        _ data: Data?,
        error: NWError?,
        from connection: NWConnection,
        for attempt: Attempt,
        expectedState: String
    ) {
        guard activeAttempt == attempt else {
            connection.cancel()
            return
        }
        guard let data, let request = String(data: data, encoding: .utf8) else {
            connection.cancel()
            if let error {
                NSLog(
                    "[OAuthCallbackServer] callback connection failed: %@",
                    error.localizedDescription
                )
            }
            return
        }

        switch parseCallbackRequest(request, expectedState: expectedState) {
        case .success(let parsed):
            let body = OAuthCallbackPage.html(for: .success)
            send(status: "200 OK", httpResponse: body, on: connection)

            continuation?.resume(returning: parsed)
            finishSuccess(attempt)
        case .authorizationDenied:
            let body = OAuthCallbackPage.html(for: .failure)
            send(status: "200 OK", httpResponse: body, on: connection)
            finish(attempt, throwing: OAuthError.authorizationDenied)
        case nil:
            let body = OAuthCallbackPage.html(for: .failure)
            send(status: "400 Bad Request", httpResponse: body, on: connection)
        }
    }

    private func send(status: String, httpResponse htmlBody: String, on connection: NWConnection) {
        let body = Data(htmlBody.utf8)
        let response = """
        HTTP/1.1 \(status)\r\n\
        Content-Type: text/html; charset=utf-8\r\n\
        Content-Length: \(body.count)\r\n\
        Connection: close\r\n\
        \r\n
        """
        var payload = Data(response.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private enum ParsedCallbackRequest {
        case success(CallbackResult)
        case authorizationDenied
    }

    private func parseCallbackRequest(
        _ request: String,
        expectedState: String
    ) -> ParsedCallbackRequest? {
        guard let requestLine = request.components(separatedBy: "\r\n").first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count == 3,
              parts[0] == "GET",
              let components = URLComponents(string: String(parts[1])),
              components.path == "/callback"
        else { return nil }

        let queryItems = components.queryItems ?? []
        let states = queryItems.filter { $0.name == "state" }.compactMap(\.value)
        guard states == [expectedState] else { return nil }

        let codes = queryItems.filter { $0.name == "code" }.compactMap(\.value)
        if codes.count == 1 {
            return .success(CallbackResult(code: codes[0], state: expectedState))
        }
        if queryItems.contains(where: { $0.name == "error" }) {
            return .authorizationDenied
        }
        return nil
    }
}

extension OAuthCallbackServer: OAuthCallbackServing {}

/// Localized, escaped HTML shown in the browser after an OAuth callback.
/// Keeping the renderer separate makes the browser-visible surface directly
/// testable without opening a listener or browser.
enum OAuthCallbackPage {
    enum Outcome {
        case success
        case failure
    }

    static func html(for outcome: Outcome, locale: Locale? = nil) -> String {
        let title: String
        let message: String
        switch outcome {
        case .success:
            title = LocalizedBundle.string("Authorization successful!", locale: locale)
            message = LocalizedBundle.string(
                "You can close this window and return to Cadenza.",
                locale: locale
            )
        case .failure:
            title = LocalizedBundle.string("Sign-in failed.", locale: locale)
            message = LocalizedBundle.string(
                "Security check failed. Please try again.",
                locale: locale
            )
        }
        return render(title: title, message: message)
    }

    static func render(title: String, message: String) -> String {
        """
        <!doctype html>
        <html><head><meta charset="utf-8"><title>\(escape(title))</title></head><body><h2>\(escape(title))</h2><p>\(escape(message))</p></body></html>
        """
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

enum OAuthError: LocalizedError {
    case authorizationDenied
    case tokenExchangeFailed(String)
    case refreshFailed
    case noRefreshToken
    case invalidResponse
    case callbackTimeout
    case callbackInProgress
    case stateMismatch
    case networkFailure

    // Callers render these descriptions directly. Keep the user-facing copy
    // localized and never expose token endpoint response bodies.
    var errorDescription: String? { localizedMessage() }

    func localizedMessage(locale: Locale? = nil) -> String {
        switch self {
        case .authorizationDenied:
            return LocalizedBundle.string("Authorization was denied.", locale: locale)
        case .tokenExchangeFailed:
            return LocalizedBundle.string("Sign-in failed.", locale: locale)
        case .refreshFailed, .noRefreshToken:
            return LocalizedBundle.string(
                "Your session expired — please sign in again.",
                locale: locale
            )
        case .invalidResponse:
            return LocalizedBundle.string(
                "Sign-in completed with an invalid response.",
                locale: locale
            )
        case .callbackTimeout:
            return LocalizedBundle.string("Sign-in timed out.", locale: locale)
        case .callbackInProgress:
            return LocalizedBundle.string(
                "Another sign-in is already in progress.",
                locale: locale
            )
        case .stateMismatch:
            return LocalizedBundle.string(
                "Security check failed. Please try again.",
                locale: locale
            )
        case .networkFailure:
            return LocalizedBundle.string(
                "Network error — please check your connection.",
                locale: locale
            )
        }
    }
}
