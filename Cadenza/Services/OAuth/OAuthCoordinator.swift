import AppKit
import AuthenticationServices
import Foundation

/// Owns the lifetime of a single `ASWebAuthenticationSession`.
///
/// Knows nothing about state, codes, or tokens — callers
/// (`CadenzaAuthService`, `NotionExportService`) build the authorize URL,
/// inspect the callback URL, and own state validation.
///
/// Guarantees:
///   - At most one active session at a time (throws `.alreadyInProgress`).
///   - 5-minute hard timeout (throws `.callbackTimeout`; cancels the session).
///   - On any race-loser error (timeout / propagated cancellation), the
///     driver is asked to `cancel()` so its underlying continuation
///     unblocks. Drivers wrap their continuation in
///     `withTaskCancellationHandler` so external Task cancellation also
///     reaches `cancel()`.
///   - Returns the raw callback URL whose scheme matches
///     `com.shuiandy.cadenza`.
///
/// Note: this coordinator does NOT conform to
/// `ASWebAuthenticationPresentationContextProviding`. The
/// `OneShotAnchorProvider` helper (below) supplies a per-session
/// presentation anchor that's captured immutably before
/// `session.start()`, sidestepping any "delegate fires off-main"
/// concerns about `MainActor.assumeIsolated`.
@MainActor
final class OAuthCoordinator: AuthorizationProvider {
    static let shared = OAuthCoordinator()
    private static let scheme = "com.shuiandy.cadenza"

    /// Test seam — production binds to `ASWebAuthenticationSessionDriver`.
    /// All conformers are `@MainActor`-isolated. `Sendable` is required because
    /// `withTaskCancellationHandler`'s `onCancel` closure must be `@Sendable`,
    /// which necessitates capturing the driver as `Sendable`.
    @MainActor
    protocol SessionDriver: Sendable {
        func start(authorizeURL: URL,
                   callbackScheme: String,
                   anchor: ASPresentationAnchor?) async throws -> URL
        func cancel()
    }

    private let sessionDriver: SessionDriver
    private let timeout: Duration
    private(set) var anchorProvider: @MainActor () -> NSWindow?
    private var inFlight = false

    init(sessionDriver: SessionDriver = ASWebAuthenticationSessionDriver(),
         timeout: Duration = .seconds(300),
         anchorProvider: (@MainActor () -> NSWindow?)? = nil) {
        self.sessionDriver = sessionDriver
        self.timeout = timeout
        self.anchorProvider = anchorProvider ?? { NSApp.keyWindow }
    }

    /// `CadenzaApp` calls this once it has access to `@Environment(\.openWindow)`.
    /// Captured weakly inside the closure (see Task C1) to avoid retain cycles.
    func attachAnchor(_ provider: @escaping @MainActor () -> NSWindow?) {
        self.anchorProvider = provider
    }

    // MARK: - AuthorizationProvider

    func authorize(_ authorizeURL: URL) async throws -> URL {
        try await authorize(authorizeURL: authorizeURL)
    }

    func authorize(authorizeURL: URL) async throws -> URL {
        guard !inFlight else { throw AuthError.alreadyInProgress }
        inFlight = true
        defer { inFlight = false }

        let driver = sessionDriver
        let timeoutDuration = timeout
        let anchor: ASPresentationAnchor? = anchorProvider()

        // Race the driver against a timeout using a checked-throwing continuation
        // so that we own the tear-down sequence explicitly. This avoids Swift 6's
        // `sending` requirement on `withThrowingTaskGroup` closures, which would
        // reject non-Sendable captures such as `ASPresentationAnchor` (NSWindow).
        //
        // `settled` guards the single-resume invariant. Because every closure
        // here is `@MainActor`-isolated, mutation is always serialised — no
        // atomics needed.
        let result: URL = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { outer in
                var settled = false

                func settle(returning url: URL) {
                    guard !settled else { return }
                    settled = true
                    outer.resume(returning: url)
                }

                func settle(throwing error: Error) {
                    guard !settled else { return }
                    settled = true
                    outer.resume(throwing: error)
                }

                // Timeout task — fires after `timeoutDuration`, cancels the
                // driver, then settles `outer` with `.callbackTimeout`.
                let timeoutTask = Task { @MainActor in
                    do {
                        try await Task.sleep(for: timeoutDuration)
                        driver.cancel()
                        settle(throwing: AuthError.callbackTimeout)
                    } catch {
                        // Task was cancelled (driver won the race) — nothing to do.
                    }
                }

                // Driver task — wraps the browser session.
                Task { @MainActor in
                    do {
                        let url = try await driver.start(
                            authorizeURL: authorizeURL,
                            callbackScheme: OAuthCoordinator.scheme,
                            anchor: anchor
                        )
                        timeoutTask.cancel()
                        // Cancel driver so any still-suspended continuation
                        // in the loser branch resumes cleanly (no-op if already done).
                        driver.cancel()
                        settle(returning: url)
                    } catch {
                        timeoutTask.cancel()
                        driver.cancel()
                        settle(throwing: error)
                    }
                }
            }
        } onCancel: {
            // External Task cancellation — settle both sides on MainActor.
            Task { @MainActor in
                driver.cancel()
            }
        }
        return result
    }
}

/// Per-session presentation anchor holder. Created fresh for each
/// `ASWebAuthenticationSession`, holds an immutable anchor captured at
/// init. `ASWebAuthenticationSession.presentationContextProvider` is a
/// `weak` reference per Apple convention, so the driver itself retains
/// this provider via `activeAnchorProvider` for the session's lifetime.
final class OneShotAnchorProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    let anchor: ASPresentationAnchor

    init(anchor: ASPresentationAnchor) {
        self.anchor = anchor
        super.init()
    }

    func presentationAnchor(
        for session: ASWebAuthenticationSession
    ) -> ASPresentationAnchor {
        anchor
    }
}

/// Production `SessionDriver` backed by `ASWebAuthenticationSession`.
@MainActor
final class ASWebAuthenticationSessionDriver: OAuthCoordinator.SessionDriver {
    private var activeSession: ASWebAuthenticationSession?
    private var activeAnchorProvider: OneShotAnchorProvider?

    func start(authorizeURL: URL,
               callbackScheme: String,
               anchor: ASPresentationAnchor?) async throws -> URL {
        let resolvedAnchor = anchor ?? ASPresentationAnchor()
        let provider = OneShotAnchorProvider(anchor: resolvedAnchor)
        activeAnchorProvider = provider

        // Cleanup runs on the @MainActor scope of this function (whether the
        // continuation resumes by success or throw). The completion handler
        // below is invoked by ASWebAuthenticationSession on an NSXPC reply
        // queue (com.apple.SafariLaunchAgent), so it MUST NOT touch
        // @MainActor-isolated state directly — Swift 6 runtime traps with
        // EXC_BREAKPOINT in Release builds. Continuations are Sendable; the
        // `await` resume hops execution back here onto MainActor, where the
        // defer body then runs the actor-isolated cleanup safely.
        defer {
            activeSession = nil
            activeAnchorProvider = nil
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
                // The completion handler is invoked by ASWebAuthenticationSession
                // on com.apple.SafariLaunchAgent's NSXPC reply queue. Without
                // explicit `@Sendable` the closure inherits @MainActor isolation
                // from the enclosing class — Swift 6 then inserts a runtime
                // executor check at closure entry, which trips
                // `_swift_task_checkIsolatedSwift → dispatch_assert_queue` and
                // SIGTRAPs in Release builds. Marking the closure @Sendable
                // declares it as cross-actor-callable so no isolation check
                // happens at entry. The body must touch only Sendable values
                // (cont is Sendable; AuthError factories are non-isolated).
                let handler: @Sendable (URL?, Error?) -> Void = { callbackURL, error in
                    if let error {
                        let nsError = error as NSError
                        if nsError.domain == ASWebAuthenticationSessionError.errorDomain,
                           nsError.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                            cont.resume(throwing: AuthError.cancelled)
                        } else {
                            cont.resume(throwing: AuthError.classify(error))
                        }
                        return
                    }
                    guard let callbackURL else {
                        cont.resume(throwing: AuthError.invalidCallback)
                        return
                    }
                    cont.resume(returning: callbackURL)
                }
                let session = ASWebAuthenticationSession(
                    url: authorizeURL,
                    callbackURLScheme: callbackScheme,
                    completionHandler: handler
                )
                session.presentationContextProvider = provider
                session.prefersEphemeralWebBrowserSession = false
                activeSession = session
                if !session.start() {
                    cont.resume(throwing: AuthError.browserOpenFailed)
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in self?.cancel() }
        }
    }

    func cancel() {
        activeSession?.cancel()
        activeSession = nil
        activeAnchorProvider = nil
    }
}
