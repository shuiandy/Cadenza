import Foundation
import Testing

@testable import Cadenza

@MainActor
private final class FakeCloudAccount: CloudAIKeysAccount {
    var accountID: String? = "user-a"
    var route: (apiBase: URL, token: String)? = (testCadenzaAPIBase, "session-token-4f9a2c")
    var list = CloudAIKeyList(keys: [], proxyEnabled: true)
    var listError: Error?
    private(set) var stored: [(provider: String, key: String)] = []
    private(set) var deleted: [String] = []

    var cloudAccountID: String? { accountID }

    func aiRouteCredentials() -> (apiBase: URL, token: String)? { route }

    func listCloudAIKeys() async throws -> CloudAIKeyList {
        if let listError { throw listError }
        return list
    }

    func storeCloudAIKey(_ apiKey: String, provider: String) async throws {
        stored.append((provider, apiKey))
        let others = list.keys.filter { $0.provider != provider }
        list = CloudAIKeyList(keys: others + [CloudAIKey(provider: provider, keySuffix: String(apiKey.suffix(4)), status: "valid")],
                              proxyEnabled: list.proxyEnabled)
    }

    func deleteCloudAIKey(provider: String) async throws {
        deleted.append(provider)
        list = CloudAIKeyList(keys: list.keys.filter { $0.provider != provider }, proxyEnabled: list.proxyEnabled)
    }
}

@Suite("AI credential resolver", .serialized)
@MainActor
struct AICredentialResolverTests {
    private func defaults() -> UserDefaults {
        let name = "AICredentialResolverTests.\(UUID().uuidString)"
        return UserDefaults(suiteName: name)!
    }

    private func key(_ provider: String, _ status: String = "valid") -> CloudAIKey {
        CloudAIKey(provider: provider, keySuffix: "abcd", status: status)
    }

    @Test func signedOutUsesThisMacsKeys() {
        let account = FakeCloudAccount()
        account.accountID = nil
        let resolver = AICredentialResolver(account: account, localKey: { $0 == .openai ? "sk-local" : nil }, defaults: defaults())
        #expect(!resolver.usesCloudKeys)
        #expect(resolver.access(for: .openai) == .direct(.openai, apiKey: "sk-local"))
        #expect(resolver.resolution(for: .claude) == .missingKey)
        #expect(resolver.resolution(for: .apple) == .ready(.direct(.apple, apiKey: "")))
    }

    @Test func signedInUsesOnlyTheAccountsKeys() async {
        let account = FakeCloudAccount()
        account.list = CloudAIKeyList(keys: [key("anthropic"), key("gemini", "invalid")], proxyEnabled: true)
        let resolver = AICredentialResolver(account: account, localKey: { _ in "sk-local" }, defaults: defaults())
        await resolver.refresh()

        #expect(resolver.usesCloudKeys)
        #expect(resolver.access(for: .claude) == AIProviderAccess(
            provider: .claude, route: .cadenza(apiBase: testCadenzaAPIBase, sessionToken: "session-token-4f9a2c")))
        // A key on this Mac is never a fallback while signed in.
        #expect(resolver.resolution(for: .openai) == .missingKey)
        #expect(resolver.resolution(for: .gemini) == .invalidKey)
        #expect(!resolver.hasUsableKey(for: .gemini))

        account.route = nil
        #expect(resolver.resolution(for: .claude) == .signInRequired)
    }

    @Test func serverWithoutCloudKeysLeavesKeysLocal() async {
        for failure in [nil, CadenzaAPIError.backend(envelope: BackendErrorEnvelope(code: "not_found", message: nil, integration: nil, upstreamStatus: nil, retryAfter: nil), status: 404)] as [Error?] {
            let account = FakeCloudAccount()
            account.list = CloudAIKeyList(keys: [key("openai")], proxyEnabled: false)
            account.listError = failure
            let resolver = AICredentialResolver(account: account, localKey: { _ in "sk-local" }, defaults: defaults())
            await resolver.refresh()
            #expect(!resolver.usesCloudKeys)
            #expect(resolver.access(for: .openai) == .direct(.openai, apiKey: "sk-local"))
        }
    }

    @Test func offlineKeepsTheModeLastSeenForTheAccount() async {
        let store = defaults()
        let account = FakeCloudAccount()
        account.list = CloudAIKeyList(keys: [key("openai")], proxyEnabled: true)
        let first = AICredentialResolver(account: account, localKey: { _ in "sk-local" }, defaults: store)
        await first.refresh()
        #expect(first.usesCloudKeys)

        account.listError = URLError(.notConnectedToInternet)
        let relaunched = AICredentialResolver(account: account, localKey: { _ in "sk-local" }, defaults: store)
        await relaunched.refresh()
        #expect(relaunched.usesCloudKeys)
        #expect(relaunched.access(for: .openai)?.viaCadenza == true)

        // Another account on the same Mac starts from its own state.
        account.accountID = "user-b"
        relaunched.sessionDidChange()
        #expect(!relaunched.usesCloudKeys)
    }

    @Test func offersLocalKeysTheAccountLacks() async throws {
        let account = FakeCloudAccount()
        account.list = CloudAIKeyList(keys: [key("gemini")], proxyEnabled: true)
        let local: [AIProvider: String] = [.openai: "sk-openai-1234", .gemini: "g-local-9999", .claude: "sk-ant-5678"]
        let resolver = AICredentialResolver(account: account, localKey: { local[$0] }, defaults: defaults())
        await resolver.refresh()

        let offered = resolver.localKeysToOffer().map(\.provider)
        #expect(Set(offered) == [.openai, .claude])
        #expect(resolver.localKeysToOffer().first { $0.provider == .openai }?.suffix == "1234")

        resolver.declineUpload(for: .claude)
        try await resolver.uploadLocalKey(for: .openai)
        #expect(account.stored.map(\.provider) == ["openai"])
        #expect(account.stored.first?.key == "sk-openai-1234")
        #expect(resolver.localKeysToOffer().isEmpty)
        #expect(resolver.access(for: .openai)?.viaCadenza == true)

        try await resolver.deleteCloudKey(for: .openai)
        #expect(account.deleted == ["openai"])
        #expect(resolver.resolution(for: .openai) == .missingKey)
    }

    @Test func nothingIsOfferedWhileKeysAreLocal() async {
        let account = FakeCloudAccount()
        account.list = CloudAIKeyList(keys: [], proxyEnabled: false)
        let resolver = AICredentialResolver(account: account, localKey: { _ in "sk-local" }, defaults: defaults())
        await resolver.refresh()
        #expect(resolver.localKeysToOffer().isEmpty)
    }

    @Test func accessFailureNotificationRefreshesTheKeyList() async throws {
        let account = FakeCloudAccount()
        account.list = CloudAIKeyList(keys: [key("openai")], proxyEnabled: true)
        let resolver = AICredentialResolver(account: account, localKey: { _ in nil }, defaults: defaults())
        await resolver.refresh()
        #expect(resolver.hasUsableKey(for: .openai))

        account.list = CloudAIKeyList(keys: [key("openai", "invalid")], proxyEnabled: true)
        NotificationCenter.default.post(name: .cadenzaAIAccessDidFail, object: nil)
        for _ in 0..<100 where resolver.hasUsableKey(for: .openai) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(resolver.resolution(for: .openai) == .invalidKey)
    }

    @Test func keyListDecodesServerShapes() throws {
        let current = try JSONDecoder().decode(CloudAIKeyList.self, from: Data(
            #"{"keys":[{"provider":"anthropic","key_suffix":"wxyz","updated_at":1,"status":"invalid","status_changed_at":2}],"proxy_enabled":true}"#.utf8))
        #expect(current.proxyEnabled)
        #expect(current.keys == [CloudAIKey(provider: "anthropic", keySuffix: "wxyz", status: "invalid")])

        let older = try JSONDecoder().decode(CloudAIKeyList.self, from: Data(
            #"{"keys":[{"provider":"openai","key_suffix":"abcd","updated_at":1,"status":"valid"}]}"#.utf8))
        #expect(!older.proxyEnabled)
    }
}
