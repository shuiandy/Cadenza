import Foundation

/// The account's default AI providers as the backend stores them
/// (`GET/PATCH /me/ai-prefs`). Providers use the server's vocabulary; an
/// empty string was never chosen, and `updatedAt` is 0 until the first write.
struct AIProviderPrefsSnapshot: Codable, Sendable, Equatable {
    var summaryProvider: String
    var transcriptionProvider: String
    var updatedAt: Int64

    enum CodingKeys: String, CodingKey {
        case summaryProvider = "summary_provider"
        case transcriptionProvider = "transcription_provider"
        case updatedAt = "updated_at"
    }
}

/// A partial write: nil fields are left as the server has them.
struct AIProviderPrefsPatch: Encodable, Sendable, Equatable {
    var summaryProvider: String?
    var transcriptionProvider: String?

    enum CodingKeys: String, CodingKey {
        case summaryProvider = "summary_provider"
        case transcriptionProvider = "transcription_provider"
    }

    var isEmpty: Bool { summaryProvider == nil && transcriptionProvider == nil }
}

@MainActor
protocol AIProviderPrefsTransport: AnyObject {
    func fetchAIProviderPrefs() async throws -> AIProviderPrefsSnapshot
    func patchAIProviderPrefs(_ patch: AIProviderPrefsPatch) async throws -> AIProviderPrefsSnapshot
}

/// Keeps the Settings "AI Provider" and transcription "Engine" pickers in step
/// with the account, so the web app and other Macs start from the same
/// defaults instead of asking which provider to use.
///
/// The pickers stay the source of truth on this Mac (`@AppStorage`); this
/// reconciles them with the account copy. A per-account ledger records the
/// values both sides last agreed on, which is what tells a local edit (the
/// picker moved since) from a remote one (the server's `updatedAt` moved
/// since). Writing a pulled value updates the ledger first, so applying it is
/// never mistaken for a local edit and pushed back.
///
/// First contact for an account: an unset server copy is seeded from this
/// Mac; a set one wins over this Mac's values.
@MainActor
final class AIProviderPrefsSync {
    enum PassResult: Equatable, Sendable {
        case notDue
        /// The backend does not serve the defaults yet (404); retried later.
        case unavailable
        case unchanged
        case pushed
        case pulled
        /// Stopped because the session changed or the task was cancelled.
        case abandoned
        case failed
    }

    /// The `@AppStorage` keys behind the Settings pickers.
    nonisolated static let summaryDefaultsKey = "defaultAIProvider"
    nonisolated static let transcriptionDefaultsKey = "transcriptionProvider"
    /// What the pickers show when nothing was ever stored.
    static let pickerDefault: AIProvider = .apple

    static let minimumInterval: TimeInterval = 5 * 60
    static let unavailableBackoff: TimeInterval = 6 * 60 * 60

    struct Ledger: Codable, Equatable {
        var summary: String
        var transcription: String
        var updatedAt: Int64
    }

    private let transport: AIProviderPrefsTransport
    private let defaults: UserDefaults
    private let now: () -> Date
    private var lastPassAt: [String: Date] = [:]
    private var unavailableUntil: Date?

    init(
        transport: AIProviderPrefsTransport,
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init
    ) {
        self.transport = transport
        self.defaults = defaults
        self.now = now
    }

    // MARK: - Vocabulary

    /// Server name for a provider the summary default may hold, nil for one
    /// it may not.
    nonisolated static func wireSummaryProvider(_ provider: AIProvider) -> String? {
        switch provider {
        case .openai: "openai"
        case .claude: "anthropic"
        case .gemini: "gemini"
        case .minimax: "minimax"
        case .apple: "apple"
        case .whisperLocal: nil
        }
    }

    nonisolated static func wireTranscriptionProvider(_ provider: AIProvider) -> String? {
        switch provider {
        case .openai: "openai"
        case .gemini: "gemini"
        case .apple: "apple"
        case .whisperLocal: "whisper_local"
        case .claude, .minimax: nil
        }
    }

    nonisolated static func summaryProvider(wire: String) -> AIProvider? {
        AIProvider.allCases.first { wireSummaryProvider($0) == wire }
    }

    nonisolated static func transcriptionProvider(wire: String) -> AIProvider? {
        AIProvider.allCases.first { wireTranscriptionProvider($0) == wire }
    }

    // MARK: - Passes

    /// True when a picker moved since the last agreed values, so a pass would
    /// push. Cheap enough to call on every defaults change notification.
    func hasLocalEdits(ledgerKey: String) -> Bool {
        guard let ledger = loadLedger(ledgerKey) else { return false }
        let local = localValues()
        return local.summary.rawValue != ledger.summary || local.transcription.rawValue != ledger.transcription
    }

    /// Runs a pass unless one ran for this ledger within `minimumInterval`.
    /// `force` skips the interval (session start, a local edit) but not the
    /// unavailable backoff.
    func runPassIfDue(
        ledgerKey: String,
        force: Bool = false,
        isCurrent: @escaping @MainActor () -> Bool
    ) async -> PassResult {
        let start = now()
        if let unavailableUntil, start < unavailableUntil { return .unavailable }
        if !force, let last = lastPassAt[ledgerKey], start.timeIntervalSince(last) < Self.minimumInterval {
            return .notDue
        }
        lastPassAt[ledgerKey] = start
        do {
            return try await runPass(ledgerKey: ledgerKey, isCurrent: isCurrent)
        } catch {
            return classify(error)
        }
    }

    private func runPass(
        ledgerKey: String,
        isCurrent: @MainActor () -> Bool
    ) async throws -> PassResult {
        let remote = try await transport.fetchAIProviderPrefs()
        try ensureCurrent(isCurrent)
        let local = localValues()
        let ledger = loadLedger(ledgerKey)

        // Per field: push this Mac's value, take the server's, or leave both.
        var patch = AIProviderPrefsPatch()
        var pulledSummary: AIProvider?
        var pulledTranscription: AIProvider?

        let remoteMoved = ledger.map { remote.updatedAt != $0.updatedAt } ?? true
        let localSummaryEdited = ledger.map { local.summary.rawValue != $0.summary } ?? false
        let localTranscriptionEdited = ledger.map { local.transcription.rawValue != $0.transcription } ?? false

        if remote.summaryProvider.isEmpty || localSummaryEdited {
            patch.summaryProvider = local.summaryWire
        } else if remoteMoved, remote.summaryProvider != local.summaryWire,
                  let provider = Self.summaryProvider(wire: remote.summaryProvider) {
            pulledSummary = provider
        }
        if remote.transcriptionProvider.isEmpty || localTranscriptionEdited {
            patch.transcriptionProvider = local.transcriptionWire
        } else if remoteMoved, remote.transcriptionProvider != local.transcriptionWire,
                  let provider = Self.transcriptionProvider(wire: remote.transcriptionProvider) {
            pulledTranscription = provider
        }

        var agreed = remote
        if !patch.isEmpty {
            agreed = try await transport.patchAIProviderPrefs(patch)
            try ensureCurrent(isCurrent)
        }

        // The ledger lands before the pickers change, so the defaults change
        // notification sees no local edit and does not push the pulled value
        // straight back.
        let summary = pulledSummary ?? local.summary
        let transcription = pulledTranscription ?? local.transcription
        saveLedger(
            Ledger(summary: summary.rawValue, transcription: transcription.rawValue, updatedAt: agreed.updatedAt),
            key: ledgerKey
        )
        if let pulledSummary { defaults.set(pulledSummary.rawValue, forKey: Self.summaryDefaultsKey) }
        if let pulledTranscription { defaults.set(pulledTranscription.rawValue, forKey: Self.transcriptionDefaultsKey) }

        if !patch.isEmpty { return .pushed }
        if pulledSummary != nil || pulledTranscription != nil { return .pulled }
        return .unchanged
    }

    // MARK: - Local state

    private struct LocalValues {
        let summary: AIProvider
        let transcription: AIProvider

        var summaryWire: String? { AIProviderPrefsSync.wireSummaryProvider(summary) }
        var transcriptionWire: String? { AIProviderPrefsSync.wireTranscriptionProvider(transcription) }
    }

    private func localValues() -> LocalValues {
        LocalValues(
            summary: storedProvider(Self.summaryDefaultsKey),
            transcription: storedProvider(Self.transcriptionDefaultsKey)
        )
    }

    private func storedProvider(_ key: String) -> AIProvider {
        defaults.string(forKey: key).flatMap(AIProvider.init(rawValue:)) ?? Self.pickerDefault
    }

    func loadLedger(_ key: String) -> Ledger? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Ledger.self, from: data)
    }

    private func saveLedger(_ ledger: Ledger, key: String) {
        guard let data = try? JSONEncoder().encode(ledger) else { return }
        defaults.set(data, forKey: key)
    }

    private func ensureCurrent(_ isCurrent: @MainActor () -> Bool) throws {
        guard isCurrent(), !Task.isCancelled else { throw CancellationError() }
    }

    private func classify(_ error: Error) -> PassResult {
        switch error {
        case is CancellationError:
            return .abandoned
        case CadenzaAPIError.backend(_, let status) where status == 404,
             AuthError.server(let status) where status == 404:
            unavailableUntil = now().addingTimeInterval(Self.unavailableBackoff)
            NSLog("[AIPrefsSync] backend does not serve AI provider defaults yet")
            return .unavailable
        default:
            NSLog("[AIPrefsSync] pass failed: %@", String(describing: error))
            return .failed
        }
    }
}
