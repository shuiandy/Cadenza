import Foundation
import Observation

/// One provider key in the Cadenza account's vault, as the server lists it.
/// The key itself never leaves the server; the suffix is only for display.
struct CloudAIKey: Codable, Equatable, Sendable {
    let provider: String
    let keySuffix: String
    let status: String

    var isValid: Bool { status == "valid" }

    enum CodingKeys: String, CodingKey {
        case provider
        case keySuffix = "key_suffix"
        case status
    }
}

struct CloudAIKeyList: Decodable, Equatable, Sendable {
    let keys: [CloudAIKey]
    /// Whether the server lets clients use vault keys. An older server omits
    /// it, which reads as false: keep local keys.
    let proxyEnabled: Bool

    init(keys: [CloudAIKey], proxyEnabled: Bool) {
        self.keys = keys
        self.proxyEnabled = proxyEnabled
    }

    enum CodingKeys: String, CodingKey {
        case keys
        case proxyEnabled = "proxy_enabled"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keys = try container.decodeIfPresent([CloudAIKey].self, forKey: .keys) ?? []
        proxyEnabled = try container.decodeIfPresent(Bool.self, forKey: .proxyEnabled) ?? false
    }
}

/// The account side of cloud keys.
@MainActor
protocol CloudAIKeysAccount: AnyObject {
    var cloudAccountID: String? { get }
    func aiRouteCredentials() -> (apiBase: URL, token: String)?
    func listCloudAIKeys() async throws -> CloudAIKeyList
    func storeCloudAIKey(_ apiKey: String, provider: String) async throws
    func deleteCloudAIKey(provider: String) async throws
}

extension CadenzaAuthService: CloudAIKeysAccount {
    var cloudAccountID: String? {
        sessionState == .signedIn ? currentUser?.id : nil
    }

    func listCloudAIKeys() async throws -> CloudAIKeyList {
        let data = try await request(path: "integrations/ai/keys")
        return try JSONDecoder().decode(CloudAIKeyList.self, from: data)
    }

    func storeCloudAIKey(_ apiKey: String, provider: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["api_key": apiKey])
        try await request(path: "integrations/ai/keys/\(provider)", method: "PUT", body: body)
    }

    func deleteCloudAIKey(provider: String) async throws {
        try await request(path: "integrations/ai/keys/\(provider)", method: "DELETE")
    }
}

/// Decides where each AI provider's key comes from, and hands services an
/// `AIProviderAccess` for it.
///
/// Signed out, or while the account's server does not serve cloud keys, keys
/// come from this Mac's Keychain. Signed in to a server that does, they come
/// only from the account's vault: the Mac never falls back to its own key,
/// so the account is always billed and diagnosed through one key. Local keys
/// stay in the Keychain untouched and are used again after signing out.
///
/// The server's answer is remembered per account, so a Mac that cannot reach
/// the server keeps the mode it last saw instead of switching key sources.
@Observable @MainActor
final class AICredentialResolver {
    /// The resolver the app uses. It reads this Mac's keys until AppState
    /// installs one bound to the profile's Cadenza account at launch. Live
    /// dependencies read it at call time, so they always see that one.
    static var shared = AICredentialResolver(
        account: nil,
        localKey: { KeychainManager.shared.readOnlyAPIKey(for: $0) }
    )

    enum Resolution: Equatable {
        case ready(AIProviderAccess)
        /// No key for the provider in the current source.
        case missingKey
        /// The account's key was rejected by the provider.
        case invalidKey
        /// Cloud keys are in use but the session cannot make calls.
        case signInRequired
    }

    /// Keys stored in the signed-in account, by provider.
    private(set) var cloudKeys: [AIProvider: CloudAIKey] = [:]
    private(set) var isRefreshing = false
    private var serverOffersCloudKeys = false
    private var declinedUploads: Set<String> = []

    @ObservationIgnored private let account: (any CloudAIKeysAccount)?
    @ObservationIgnored private let localKey: (AIProvider) -> String?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var loadedAccountID: String?
    @ObservationIgnored private var failureObserver: NSObjectProtocol?
    @ObservationIgnored private var pendingRefresh: Task<Void, Never>?
    @ObservationIgnored private var lastRefresh: Date?

    init(
        account: (any CloudAIKeysAccount)?,
        localKey: @escaping (AIProvider) -> String?,
        defaults: UserDefaults = .standard
    ) {
        self.account = account
        self.localKey = localKey
        self.defaults = defaults
        loadSnapshot(for: account?.cloudAccountID)
        failureObserver = NotificationCenter.default.addObserver(
            forName: .cadenzaAIAccessDidFail, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRefresh() }
        }
    }

    /// Resolves keys from this Mac only; for tests and previews.
    static func localOnly(localKey: @escaping (AIProvider) -> String?) -> AICredentialResolver {
        AICredentialResolver(account: nil, localKey: localKey, defaults: UserDefaults(suiteName: "AICredentialResolver.localOnly") ?? .standard)
    }

    // MARK: - Mode

    /// Whether keys come from the signed-in account rather than this Mac.
    var usesCloudKeys: Bool {
        guard let accountID = account?.cloudAccountID, accountID == loadedAccountID else { return false }
        return serverOffersCloudKeys
    }

    /// Follows sign-in, sign-out and account changes: loads what was last
    /// seen for the account and asks the server again.
    func sessionDidChange() {
        let accountID = account?.cloudAccountID
        if accountID != loadedAccountID {
            loadSnapshot(for: accountID)
        }
        if accountID != nil {
            scheduleRefresh()
        }
    }

    // MARK: - Resolution

    func resolution(for provider: AIProvider) -> Resolution {
        guard provider.requiresAPIKey else {
            return .ready(.direct(provider, apiKey: ""))
        }
        if usesCloudKeys {
            guard let route = account?.aiRouteCredentials() else { return .signInRequired }
            guard let key = cloudKeys[provider] else { return .missingKey }
            guard key.isValid else { return .invalidKey }
            return .ready(AIProviderAccess(
                provider: provider,
                route: .cadenza(apiBase: route.apiBase, sessionToken: route.token)
            ))
        }
        guard let key = localKey(provider), !key.isEmpty else { return .missingKey }
        return .ready(.direct(provider, apiKey: key))
    }

    func access(for provider: AIProvider) -> AIProviderAccess? {
        if case .ready(let access) = resolution(for: provider) { return access }
        return nil
    }

    /// Whether features that need the provider's key can run now.
    func hasUsableKey(for provider: AIProvider) -> Bool {
        access(for: provider) != nil
    }

    // MARK: - Refresh

    /// Reloads the account's key list and whether the server serves cloud
    /// keys. A failure keeps what was last seen.
    func refresh() async {
        guard let account, let accountID = account.cloudAccountID else { return }
        if accountID != loadedAccountID {
            loadSnapshot(for: accountID)
        }
        isRefreshing = true
        lastRefresh = Date()
        defer { isRefreshing = false }
        do {
            let list = try await account.listCloudAIKeys()
            guard account.cloudAccountID == accountID else { return }
            apply(list)
        } catch CadenzaAPIError.backend(_, let status) where status == 404 {
            // A server without the vault: cloud keys are not offered.
            guard account.cloudAccountID == accountID else { return }
            apply(CloudAIKeyList(keys: [], proxyEnabled: false))
        } catch {
            // Offline or a server error: keep the last known state.
        }
    }

    /// Refreshes at most every few minutes; for app activation, which can be
    /// frequent.
    func refreshIfStale(maxAge: TimeInterval = 300) {
        if let lastRefresh, Date().timeIntervalSince(lastRefresh) < maxAge { return }
        scheduleRefresh()
    }

    /// Coalesces refresh requests, such as a burst of failed calls.
    func scheduleRefresh() {
        guard pendingRefresh == nil else { return }
        pendingRefresh = Task { [weak self] in
            await self?.refresh()
            self?.pendingRefresh = nil
        }
    }

    // MARK: - Account keys

    /// Stores a key in the account's vault. The server checks it with the
    /// provider first and refuses a rejected key.
    func storeCloudKey(_ apiKey: String, for provider: AIProvider) async throws {
        guard let account, let name = AIProviderAccess.cadenzaName(for: provider) else {
            throw CadenzaAPIError.notSignedIn
        }
        try await account.storeCloudAIKey(apiKey, provider: name)
        await refresh()
    }

    func deleteCloudKey(for provider: AIProvider) async throws {
        guard let account, let name = AIProviderAccess.cadenzaName(for: provider) else {
            throw CadenzaAPIError.notSignedIn
        }
        try await account.deleteCloudAIKey(provider: name)
        await refresh()
    }

    // MARK: - Offering local keys to the account

    /// Providers with a key on this Mac but none in the account, which the
    /// user has not declined to upload.
    func localKeysToOffer() -> [(provider: AIProvider, suffix: String)] {
        guard usesCloudKeys else { return [] }
        return AIProvider.allCases.compactMap { provider in
            guard provider.requiresAPIKey,
                  AIProviderAccess.cadenzaName(for: provider) != nil,
                  cloudKeys[provider] == nil,
                  !declinedUploads.contains(provider.rawValue),
                  let key = localKey(provider), !key.isEmpty else {
                return nil
            }
            return (provider, String(key.suffix(4)))
        }
    }

    /// Uploads this Mac's key for the provider. The local copy stays in the
    /// Keychain, unused while signed in.
    func uploadLocalKey(for provider: AIProvider) async throws {
        guard let key = localKey(provider), !key.isEmpty else { return }
        try await storeCloudKey(key, for: provider)
    }

    func declineUpload(for provider: AIProvider) {
        declinedUploads.insert(provider.rawValue)
        persistSnapshot()
    }

    // MARK: - Persistence

    private struct Snapshot: Codable {
        var serverOffersCloudKeys: Bool
        var keys: [CloudAIKey]
        var declinedUploads: [String]
    }

    private func apply(_ list: CloudAIKeyList) {
        serverOffersCloudKeys = list.proxyEnabled
        var keys: [AIProvider: CloudAIKey] = [:]
        for key in list.keys {
            if let provider = AIProvider.allCases.first(where: { AIProviderAccess.cadenzaName(for: $0) == key.provider }) {
                keys[provider] = key
            }
        }
        cloudKeys = keys
        persistSnapshot()
    }

    private func snapshotKey(for accountID: String) -> String {
        "aiCloudKeys.\(accountID)"
    }

    /// Loads the remembered state of an account.
    private func loadSnapshot(for accountID: String?) {
        loadedAccountID = accountID
        guard let accountID,
              let data = defaults.data(forKey: snapshotKey(for: accountID)),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            serverOffersCloudKeys = false
            cloudKeys = [:]
            declinedUploads = []
            return
        }
        serverOffersCloudKeys = snapshot.serverOffersCloudKeys
        declinedUploads = Set(snapshot.declinedUploads)
        var keys: [AIProvider: CloudAIKey] = [:]
        for key in snapshot.keys {
            if let provider = AIProvider.allCases.first(where: { AIProviderAccess.cadenzaName(for: $0) == key.provider }) {
                keys[provider] = key
            }
        }
        cloudKeys = keys
    }

    private func persistSnapshot() {
        guard let accountID = loadedAccountID else { return }
        let snapshot = Snapshot(
            serverOffersCloudKeys: serverOffersCloudKeys,
            keys: Array(cloudKeys.values),
            declinedUploads: declinedUploads.sorted()
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: snapshotKey(for: accountID))
        }
    }
}
