import Foundation
import Testing

@testable import Cadenza

@MainActor
@Suite("Google Calendar credential storage", .serialized)
struct GoogleCalendarCredentialStorageTests {
    @Test func saveWritesSecretBeforeReplacingPublicConfiguration() throws {
        let defaults = makeDefaults()
        defaults.set("old-client", forKey: GoogleCalendarService.clientIDDefaultsKey)
        defaults.set("legacy-plaintext", forKey: GoogleCalendarService.clientSecretKey)
        var securelyStoredSecret: String?
        let service = makeService(
            defaults: defaults,
            writeSecret: { securelyStoredSecret = $0 }
        )

        try service.saveCredentials(clientID: " new-client ", clientSecret: " new-secret ")

        #expect(securelyStoredSecret == "new-secret")
        #expect(defaults.string(forKey: GoogleCalendarService.clientIDDefaultsKey) == "new-client")
        #expect(defaults.object(forKey: GoogleCalendarService.clientSecretKey) == nil)
    }

    @Test func failedSecretWritePreservesPreviousConfigurationAndPlaintextForRetry() {
        let defaults = makeDefaults()
        defaults.set("old-client", forKey: GoogleCalendarService.clientIDDefaultsKey)
        defaults.set("legacy-plaintext", forKey: GoogleCalendarService.clientSecretKey)
        let service = makeService(
            defaults: defaults,
            writeSecret: { _ in throw CredentialTestError.writeFailed }
        )

        #expect(throws: CredentialTestError.writeFailed) {
            try service.saveCredentials(clientID: "new-client", clientSecret: "new-secret")
        }

        #expect(defaults.string(forKey: GoogleCalendarService.clientIDDefaultsKey) == "old-client")
        #expect(defaults.string(forKey: GoogleCalendarService.clientSecretKey) == "legacy-plaintext")
    }

    @Test func configuredCredentialsReadSecretOnlyThroughSecureReader() {
        let defaults = makeDefaults()
        defaults.set("client-id", forKey: GoogleCalendarService.clientIDDefaultsKey)
        defaults.set("stale-plaintext", forKey: GoogleCalendarService.clientSecretKey)
        var readCount = 0
        let service = makeService(
            defaults: defaults,
            readSecret: {
                readCount += 1
                return "secure-secret"
            }
        )

        let credentials = service.configuredCredentials()

        #expect(credentials.clientID == "client-id")
        #expect(credentials.clientSecret == "secure-secret")
        #expect(readCount == 1)
    }

    @Test func blankClientIDCannotMutateTheSecureSecret() {
        let defaults = makeDefaults()
        defaults.set("old-client", forKey: GoogleCalendarService.clientIDDefaultsKey)
        var writeCount = 0
        let service = makeService(
            defaults: defaults,
            writeSecret: { _ in writeCount += 1 }
        )

        #expect(throws: GoogleCalendarCredentialError.missingClientID) {
            try service.saveCredentials(clientID: "   ", clientSecret: "replacement")
        }

        #expect(writeCount == 0)
        #expect(defaults.string(forKey: GoogleCalendarService.clientIDDefaultsKey) == "old-client")
    }

    @Test func disconnectFailureIsVisibleEvenWhileTokenStillExists() {
        let presentation = GoogleCalendarConnectionPresentation.make(
            isConnected: true,
            isConnecting: false,
            error: "Keychain token removal failed"
        )

        #expect(presentation.phase == .error)
        #expect(presentation.statusText == "Keychain token removal failed")
    }

    @Test func appStateCredentialFailuresNeverExposeRawKeychainDetails() {
        let rawCanary = #"RAW-KEYCHAIN-CANARY-{\"token\":\"secret-value\"}"#
        let error = CredentialRawDetailError(detail: rawCanary)
        let zh = Locale(identifier: "zh-Hans")
        let messages = [
            AppState.googleCredentialSaveFailureMessage(for: error, locale: zh),
            AppState.googleDisconnectFailureMessage(for: error, locale: zh),
        ]

        for message in messages {
            #expect(!message.isEmpty)
            #expect(!message.contains(rawCanary))
            #expect(!message.contains("secret-value"))
            #expect(
                message.unicodeScalars.contains { scalar in
                    (0x3400...0x9FFF).contains(Int(scalar.value))
                }
            )
        }
    }

    private func makeService(
        defaults: UserDefaults,
        readSecret: @escaping @MainActor () -> String = { "" },
        writeSecret: @escaping @MainActor (String) throws -> Void = { _ in }
    ) -> GoogleCalendarService {
        GoogleCalendarService(
            tokenManager: OAuthTokenManager(),
            defaults: defaults,
            clientSecretReader: readSecret,
            clientSecretWriter: writeSecret
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "GoogleCalendarCredentialStorageTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}

private enum CredentialTestError: Error {
    case writeFailed
}

private struct CredentialRawDetailError: LocalizedError {
    let detail: String
    var errorDescription: String? { detail }
}
