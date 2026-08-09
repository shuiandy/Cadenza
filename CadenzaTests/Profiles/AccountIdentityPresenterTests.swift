import Foundation
import Testing

@testable import Cadenza

struct AccountIdentityPresenterTests {
    private let official = "https://cadenzapp.com:443"

    private func account(
        email: String = "same@example.com",
        name: String = "Same Name",
        issuerOrigin: String
    ) -> Profile.BoundAccount {
        Profile.BoundAccount(
            userID: "u1", originKey: "k",
            issuerOrigin: issuerOrigin,
            apiBaseURL: "https://irrelevant.example/api",
            displayEmail: email, displayName: name,
            boundAt: Date(timeIntervalSince1970: 1_785_900_000)
        )
    }

    @Test func officialOriginShowsBrandLabel() {
        // The injected constant matches the production official origin.
        #expect(CadenzaBackendConfig.official().origin.normalized == official)
        let presentation = AccountIdentityPresenter.present(
            account(issuerOrigin: official), officialIssuerOrigin: official
        )
        #expect(presentation.identity == "same@example.com")
        #expect(presentation.backend == "Cadenza")
    }

    /// Self-hosted issuers render as the full canonical origin — scheme
    /// and explicit port included — so no two distinct issuers can share
    /// a label, and IPv6 hosts stay unambiguous.
    @Test func selfHostRendersTheFullCanonicalOrigin() {
        let nonDefault = AccountIdentityPresenter.present(
            account(issuerOrigin: "https://notes.example.com:8443"),
            officialIssuerOrigin: official
        )
        #expect(nonDefault.backend == "https://notes.example.com:8443")
        let defaultPort = AccountIdentityPresenter.present(
            account(issuerOrigin: "https://notes.example.com:443"),
            officialIssuerOrigin: official
        )
        #expect(defaultPort.backend == "https://notes.example.com:443")
        let ipv6 = AccountIdentityPresenter.present(
            account(issuerOrigin: "https://[::1]:8443"),
            officialIssuerOrigin: official
        )
        #expect(ipv6.backend == "https://[::1]:8443")
    }

    /// http and https on the same host are distinct token issuers and
    /// can coexist; the same email on both must stay distinguishable.
    @Test func sameEmailHTTPAndHTTPSIssuersOnOneHostAreDistinct() {
        let insecure = AccountIdentityPresenter.present(
            account(issuerOrigin: "http://same.host:80"),
            officialIssuerOrigin: official
        )
        let secure = AccountIdentityPresenter.present(
            account(issuerOrigin: "https://same.host:443"),
            officialIssuerOrigin: official
        )
        #expect(insecure.identity == secure.identity)
        #expect(insecure.backend == "http://same.host:80")
        #expect(secure.backend == "https://same.host:443")
        #expect(insecure != secure)
    }

    /// Frozen data that no longer validates stays visible as recorded —
    /// display never crashes and never guesses a different backend.
    @Test func malformedFrozenOriginFallsBackToTheRawValue() {
        let malformed = AccountIdentityPresenter.present(
            account(issuerOrigin: "not a url"), officialIssuerOrigin: official
        )
        #expect(malformed.backend == "not a url")
        let nonCanonical = AccountIdentityPresenter.present(
            account(issuerOrigin: "https://Cadenzapp.com"), officialIssuerOrigin: official
        )
        #expect(nonCanonical.backend == "https://Cadenzapp.com")
    }

    @Test func emptyEmailFallsBackToNameThenPlaceholder() {
        let named = AccountIdentityPresenter.present(
            account(email: "", name: "Only Name", issuerOrigin: official),
            officialIssuerOrigin: official
        )
        #expect(named.identity == "Only Name")
        let empty = AccountIdentityPresenter.present(
            account(email: "", name: "", issuerOrigin: official),
            officialIssuerOrigin: official
        )
        #expect(empty.identity == "Unknown account")
    }

    @Test func sameEmailOnDifferentOriginsProducesDistinctDescriptors() {
        let officialSide = AccountIdentityPresenter.present(
            account(issuerOrigin: official), officialIssuerOrigin: official
        )
        let selfHost = AccountIdentityPresenter.present(
            account(issuerOrigin: "https://home.example.net:8443"),
            officialIssuerOrigin: official
        )
        #expect(officialSide.identity == selfHost.identity)
        #expect(officialSide != selfHost)
        #expect(officialSide.backend != selfHost.backend)
    }

    /// Source gate over the settings surface: the backend renders on the
    /// current card and on every bound row, the add-or-switch entry sits
    /// behind the bound-active gate with the transition block wired, and
    /// the sheet handles the already-active outcome.
    @Test func settingsSurfaceRendersBackendAndOffersAddOrSwitch() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Cadenza/Views/Settings/ProfilesSettingsSection.swift"),
            encoding: .utf8
        )
        #expect(
            source.components(separatedBy: "AccountIdentityPresenter.present(").count - 1 >= 2
        )
        let entryGate = try #require(source.range(of: "if active.boundAccount != nil {"))
        let entryButton = try #require(source.range(
            of: "Sign In with Another Account…",
            range: entryGate.upperBound..<source.endIndex
        ))
        let entryDisabled = try #require(source.range(
            of: ".disabled(appState.profileTransitionBlockReason != nil)",
            range: entryButton.upperBound..<source.endIndex
        ))
        _ = try #require(source.range(
            of: ".help(appState.profileTransitionBlockReason ??",
            range: entryDisabled.upperBound..<source.endIndex
        ))
        #expect(source.contains("case .alreadyActiveAccount"))
    }
}
