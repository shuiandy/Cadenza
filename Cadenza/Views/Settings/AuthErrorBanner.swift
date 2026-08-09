import SwiftUI

/// Renders the account-level `AuthError` returned by `CadenzaAuthService`.
/// Filters out `.integrationReauthRequired` — that case is per-integration
/// and rendered inside `RequiresSignInConnectionRow` for the affected
/// service.
struct AuthErrorBanner: View {    @Environment(\.uiScale) private var uiScale: CGFloat

    let error: AuthError?

    var body: some View {
        if let error, !shouldFilter(error) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: iconName(for: error))
                    .foregroundStyle(tint(for: error))
                Text(error.errorDescription ?? String(localized: "Sign-in failed."))
                    .foregroundStyle(.primary)
                    .font(.cadenza(.subheadline, scale: uiScale))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(tint(for: error).opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityElement(children: .combine)
        }
    }

    private func shouldFilter(_ error: AuthError) -> Bool {
        if case .integrationReauthRequired = error { return true }
        return false
    }

    private func iconName(for error: AuthError) -> String {
        switch error {
        case .cancelled: return "xmark.circle"
        case .browserOpenFailed: return "safari"
        case .callbackTimeout, .sessionExpired: return "clock.badge.exclamationmark"
        case .sessionCleanupFailed: return "exclamationmark.lock"
        case .alreadyInProgress, .integrationReauthRequired: return "arrow.triangle.2.circlepath"
        case .stateMismatch: return "shield.lefthalf.filled.badge.checkmark"
        case .authorizationDenied: return "xmark.shield"
        case .bindingFlowRequired: return "person.crop.circle.badge.questionmark"
        case .accountMismatch: return "person.crop.circle.badge.xmark"
        case .invalidCallback: return "link.badge.plus"
        case .localPersistenceFailed: return "key.slash"
        case .decoding: return "ladybug"
        case .server: return "exclamationmark.triangle"
        case .network: return "wifi.slash"
        case .unknown: return "questionmark.circle"
        }
    }

    private func tint(for error: AuthError) -> Color {
        switch error {
        case .cancelled, .alreadyInProgress: return .secondary
        case .callbackTimeout, .sessionExpired, .integrationReauthRequired, .network: return .orange
        default: return .red
        }
    }
}
