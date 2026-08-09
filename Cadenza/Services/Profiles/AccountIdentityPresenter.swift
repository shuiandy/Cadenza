import Foundation

/// Pure presentation identity for a bound account. The frozen
/// issuerOrigin is the authority — never the mutable backend
/// configuration — so the same email on the official backend and on a
/// self-hosted one stays visibly distinct, and a bound row keeps
/// describing the backend it was actually bound to.
enum AccountIdentityPresenter {
    struct Presentation: Equatable, Sendable {
        /// Email when present, else display name, else a localized
        /// placeholder. Dynamic display data, never a localization key.
        let identity: String
        /// "Cadenza" for the official backend; the full canonical
        /// origin (scheme, host, explicit port) for a self-hosted one,
        /// so http and https issuers on the same host stay distinct and
        /// IPv6 hosts stay unambiguous; the raw frozen string when it
        /// no longer validates — visible, never fatal.
        let backend: String
    }

    static func present(
        _ account: Profile.BoundAccount,
        officialIssuerOrigin: String = CadenzaBackendConfig.official().origin.normalized,
        locale: Locale? = nil
    ) -> Presentation {
        Presentation(
            identity: identity(for: account, locale: locale),
            backend: backendLabel(
                issuerOrigin: account.issuerOrigin,
                officialIssuerOrigin: officialIssuerOrigin
            )
        )
    }

    static func identity(
        for account: Profile.BoundAccount, locale: Locale? = nil
    ) -> String {
        if !account.displayEmail.isEmpty { return account.displayEmail }
        if !account.displayName.isEmpty { return account.displayName }
        return LocalizedBundle.string("Unknown account", locale: locale)
    }

    static func backendLabel(
        issuerOrigin: String, officialIssuerOrigin: String
    ) -> String {
        if AccountIdentity.matches(issuerOrigin, officialIssuerOrigin) {
            return "Cadenza"
        }
        guard let origin = try? IssuerOrigin(validating: issuerOrigin) else {
            // Frozen data that no longer validates stays displayable as
            // recorded; a backend identity is never guessed from it.
            return issuerOrigin
        }
        // Full canonical origin, never abbreviated: dropping the scheme
        // or a default port would collapse distinct token issuers
        // (http vs https on one host) into one label.
        return origin.normalized
    }
}
