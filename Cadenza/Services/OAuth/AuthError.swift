import Foundation

/// Classified error surface for the Cadenza account + OAuth-vault stack.
///
/// Mapped to user-visible UI by `AuthErrorBanner` (account-level cases)
/// or rendered inline by `RequiresSignInConnectionRow` for the
/// integration-specific `.integrationReauthRequired` case.
enum AuthError: LocalizedError, Equatable, Sendable {
    case cancelled
    case browserOpenFailed
    case callbackTimeout
    case alreadyInProgress
    case stateMismatch
    case authorizationDenied
    case invalidCallback
    case localPersistenceFailed(String)
    case decoding(String)
    case sessionExpired
    /// The local session credential could not be durably cleared or
    /// invalidated — the registry disposition write and every Keychain
    /// cleanup failed (session expiry and explicit sign-out share this).
    /// Surfaced explicitly instead of claiming the session ended.
    case sessionCleanupFailed
    /// The active profile has no bound account; sign-in must go through
    /// the profile login flow, which decides binding.
    case bindingFlowRequired
    /// A re-login returned a different account identity than the one the
    /// profile is bound to; nothing was written.
    case accountMismatch
    case integrationReauthRequired(provider: String)
    case server(status: Int)
    case network(URLError.Code)
    case unknown

    // Messages must be localized before they are returned: callers render
    // them via Text(String), which never consults the catalog.
    var errorDescription: String? { localizedMessage() }

    /// Locale-injectable message path (nil = current locale); tests drive
    /// this method directly so a regression to bare literals fails.
    func localizedMessage(locale: Locale? = nil) -> String {
        switch self {
        case .cancelled:
            return LocalizedBundle.string("Sign-in cancelled.", locale: locale)
        case .browserOpenFailed:
            return LocalizedBundle.string("Couldn't open browser.", locale: locale)
        case .callbackTimeout:
            return LocalizedBundle.string("Sign-in timed out.", locale: locale)
        case .alreadyInProgress:
            return LocalizedBundle.string("Another sign-in is already in progress.", locale: locale)
        case .stateMismatch:
            return LocalizedBundle.string("Security check failed. Please try again.", locale: locale)
        case .authorizationDenied:
            return LocalizedBundle.string("Authorization was denied.", locale: locale)
        case .invalidCallback:
            return LocalizedBundle.string("Sign-in completed with an invalid response.", locale: locale)
        case .localPersistenceFailed:
            return LocalizedBundle.string("Couldn't save your session locally.", locale: locale)
        case .decoding:
            return LocalizedBundle.string("Sign-in returned an unexpected format.", locale: locale)
        case .sessionExpired:
            return LocalizedBundle.string("Your session expired — please sign in again.", locale: locale)
        case .sessionCleanupFailed:
            return LocalizedBundle.string(
                "Your session couldn't be securely cleared. Quit and reopen Cadenza, then try again.",
                locale: locale
            )
        case .bindingFlowRequired:
            return LocalizedBundle.string(
                "This profile has no linked account yet — use Sign In from Profiles to link one.",
                locale: locale
            )
        case .accountMismatch:
            return LocalizedBundle.string(
                "That sign-in belongs to a different account than this profile.",
                locale: locale
            )
        case .integrationReauthRequired(let provider):
            return LocalizedBundle.string("Reconnect \(provider) to keep using it.", locale: locale)
        case .server(let status):
            return LocalizedBundle.string("Cadenza server error (\(status)).", locale: locale)
        case .network:
            return LocalizedBundle.string("Network error — please check your connection.", locale: locale)
        case .unknown:
            return LocalizedBundle.string("Sign-in failed.", locale: locale)
        }
    }

    /// Map any `Error` to its closest `AuthError` case. Pass-through for
    /// existing `AuthError` values; named cases for `URLError` /
    /// `DecodingError`; everything else collapses to `.unknown`.
    static func classify(_ error: Error) -> AuthError {
        if let authError = error as? AuthError { return authError }
        if let urlError = error as? URLError {
            if urlError.code == .cancelled { return .cancelled }
            return .network(urlError.code)
        }
        if let decodingError = error as? DecodingError {
            return .decoding(String(describing: decodingError))
        }
        return .unknown
    }
}
