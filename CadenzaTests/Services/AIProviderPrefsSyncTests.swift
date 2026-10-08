import Foundation
import Testing
@testable import Cadenza

private let ledgerKey = "webSync.aiProviderPrefs.test"

/// A server copy of the defaults that applies patches the way the backend
/// does: set fields replace, and every write moves `updatedAt` forward.
@MainActor
private final class FakeAIPrefsServer: AIProviderPrefsTransport {
    var stored = AIProviderPrefsSnapshot(summaryProvider: "", transcriptionProvider: "", updatedAt: 0)
    var fetchError: Error?
    private(set) var patches: [AIProviderPrefsPatch] = []

    func fetchAIProviderPrefs() async throws -> AIProviderPrefsSnapshot {
        if let fetchError { throw fetchError }
        return stored
    }

    func patchAIProviderPrefs(_ patch: AIProviderPrefsPatch) async throws -> AIProviderPrefsSnapshot {
        patches.append(patch)
        if let summary = patch.summaryProvider { stored.summaryProvider = summary }
        if let transcription = patch.transcriptionProvider { stored.transcriptionProvider = transcription }
        stored.updatedAt += 1
        return stored
    }

    /// An edit made elsewhere, on the web or another Mac.
    func editElsewhere(summary: String? = nil, transcription: String? = nil) {
        if let summary { stored.summaryProvider = summary }
        if let transcription { stored.transcriptionProvider = transcription }
        stored.updatedAt += 1
    }
}

@MainActor
private func makeHarness(
    now: @escaping () -> Date = Date.init
) -> (FakeAIPrefsServer, AIProviderPrefsSync, UserDefaults) {
    let suite = "AIProviderPrefsSyncTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    let server = FakeAIPrefsServer()
    return (server, AIProviderPrefsSync(transport: server, defaults: defaults, now: now), defaults)
}

@MainActor
private func pass(_ sync: AIProviderPrefsSync, force: Bool = true) async -> AIProviderPrefsSync.PassResult {
    await sync.runPassIfDue(ledgerKey: ledgerKey, force: force) { true }
}

private func pickers(_ defaults: UserDefaults) -> (String?, String?) {
    (
        defaults.string(forKey: AIProviderPrefsSync.summaryDefaultsKey),
        defaults.string(forKey: AIProviderPrefsSync.transcriptionDefaultsKey)
    )
}

@MainActor
struct AIProviderPrefsSyncTests {
    @Test func vocabularyRoundTripsBetweenMacAndServerNames() {
        for provider in AIProvider.allCases {
            if let wire = AIProviderPrefsSync.wireSummaryProvider(provider) {
                #expect(AIProviderPrefsSync.summaryProvider(wire: wire) == provider)
            }
            if let wire = AIProviderPrefsSync.wireTranscriptionProvider(provider) {
                #expect(AIProviderPrefsSync.transcriptionProvider(wire: wire) == provider)
            }
        }
        #expect(AIProviderPrefsSync.wireSummaryProvider(.claude) == "anthropic")
        #expect(AIProviderPrefsSync.wireTranscriptionProvider(.whisperLocal) == "whisper_local")
        #expect(AIProviderPrefsSync.wireSummaryProvider(.whisperLocal) == nil)
        #expect(AIProviderPrefsSync.wireTranscriptionProvider(.claude) == nil)
    }

    @Test func anUnsetAccountIsSeededFromThisMac() async {
        let (server, sync, defaults) = makeHarness()
        defaults.set(AIProvider.claude.rawValue, forKey: AIProviderPrefsSync.summaryDefaultsKey)
        // The transcription picker was never touched: its shown default is pushed.

        #expect(await pass(sync) == .pushed)

        #expect(server.patches == [AIProviderPrefsPatch(summaryProvider: "anthropic", transcriptionProvider: "apple")])
        #expect(sync.loadLedger(ledgerKey) == .init(summary: "claude", transcription: "apple", updatedAt: 1))
        #expect(await pass(sync) == .unchanged)
    }

    @Test func aSetAccountWinsOverANewMac() async {
        let (server, sync, defaults) = makeHarness()
        defaults.set(AIProvider.openai.rawValue, forKey: AIProviderPrefsSync.summaryDefaultsKey)
        server.stored = .init(summaryProvider: "gemini", transcriptionProvider: "whisper_local", updatedAt: 7)

        #expect(await pass(sync) == .pulled)

        #expect(server.patches.isEmpty)
        #expect(pickers(defaults) == ("gemini", "whisperLocal"))
        #expect(sync.hasLocalEdits(ledgerKey: ledgerKey) == false)
    }

    @Test func aPickerMovedHereIsPushedAndAnEditElsewhereIsPulled() async {
        let (server, sync, defaults) = makeHarness()
        server.stored = .init(summaryProvider: "anthropic", transcriptionProvider: "openai", updatedAt: 3)
        _ = await pass(sync)

        defaults.set(AIProvider.minimax.rawValue, forKey: AIProviderPrefsSync.summaryDefaultsKey)
        #expect(sync.hasLocalEdits(ledgerKey: ledgerKey))
        #expect(await pass(sync) == .pushed)
        #expect(server.patches.last == AIProviderPrefsPatch(summaryProvider: "minimax", transcriptionProvider: nil))
        #expect(server.stored.summaryProvider == "minimax")

        server.editElsewhere(transcription: "gemini")
        #expect(await pass(sync) == .pulled)
        #expect(pickers(defaults) == ("minimax", "gemini"))
        #expect(server.patches.count == 1)
    }

    // The server copy is the user's own choice even when this build cannot
    // show it; the picker keeps its value instead of being overwritten.
    @Test func aValueThisBuildDoesNotKnowLeavesThePickerAlone() async {
        let (server, sync, defaults) = makeHarness()
        defaults.set(AIProvider.gemini.rawValue, forKey: AIProviderPrefsSync.summaryDefaultsKey)
        server.stored = .init(summaryProvider: "future-provider", transcriptionProvider: "openai", updatedAt: 2)

        _ = await pass(sync)

        #expect(pickers(defaults).0 == "gemini")
        #expect(server.patches.isEmpty)
        #expect(await pass(sync) == .unchanged)
    }

    @Test func aBackendWithoutTheEndpointBacksOff() async {
        var clock = Date(timeIntervalSince1970: 1_790_000_000)
        let (server, sync, _) = makeHarness(now: { clock })
        server.fetchError = AuthError.server(status: 404)

        #expect(await pass(sync) == .unavailable)
        server.fetchError = nil
        #expect(await pass(sync) == .unavailable)
        clock = clock.addingTimeInterval(AIProviderPrefsSync.unavailableBackoff + 1)
        #expect(await pass(sync) == .pushed)
    }

    @Test func unforcedPassesWaitOutTheInterval() async {
        var clock = Date(timeIntervalSince1970: 1_790_000_000)
        let (_, sync, _) = makeHarness(now: { clock })
        #expect(await pass(sync, force: false) == .pushed)
        #expect(await pass(sync, force: false) == .notDue)
        clock = clock.addingTimeInterval(AIProviderPrefsSync.minimumInterval + 1)
        #expect(await pass(sync, force: false) == .unchanged)
    }

    @Test func aSessionThatEndsMidPassWritesNothing() async {
        let (server, sync, defaults) = makeHarness()
        server.stored = .init(summaryProvider: "gemini", transcriptionProvider: "openai", updatedAt: 4)
        // Compared with what was there, not nil: the test host may register
        // defaults for the pickers, and those are visible through any suite.
        let before = pickers(defaults)

        let result = await sync.runPassIfDue(ledgerKey: ledgerKey, force: true) { false }

        #expect(result == .abandoned)
        #expect(pickers(defaults) == before)
        #expect(sync.loadLedger(ledgerKey) == nil)
    }
}
