import Foundation
import Testing

@testable import Cadenza

@MainActor
@Suite("AI provider API key mutation")
struct AIProviderAPIKeyMutationCoordinatorTests {
    @Test func providerRowRenderingUsesPresentationSnapshotInsteadOfKeychain() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repoRoot.appendingPathComponent(
            "Cadenza/Views/Settings/IntegrationsSettingsView.swift"
        )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let providerRowStart = try #require(source.range(of: "private struct ProviderRow: View"))
        let providerRowSource = source[providerRowStart.lowerBound...]

        #expect(providerRowSource.contains("apiKeyPresentation.isConnected"))
        #expect(providerRowSource.contains("apiKeyPresentation.currentAPIKey"))
        #expect(!providerRowSource.contains("KeychainManager.shared"))
    }

    @Test func disconnectFailurePreservesLoadedPresentationSnapshotWithoutAnotherStorageRead() {
        let loader = APIKeyReadOnlyLoaderSpy(value: "existing-openai-key")
        var presentation = AIProviderAPIKeyPresentationState(
            provider: .openai,
            loader: loader
        )

        let result = presentation.applyDisconnectResult(
            .failure(message: "API key could not be removed securely. Please try again.")
        )

        #expect(failureMessage(from: result) != nil)
        #expect(presentation.currentAPIKey == "existing-openai-key")
        #expect(presentation.isConnected)
        #expect(loader.readOnlyReadCount == 1)
        #expect(loader.migratingReadCount == 0)
    }

    @Test func saveFailurePreservesLoadedPresentationSnapshotWithoutAnotherStorageRead() {
        let loader = APIKeyReadOnlyLoaderSpy(value: nil)
        var presentation = AIProviderAPIKeyPresentationState(
            provider: .claude,
            loader: loader
        )

        let result = presentation.applySaveResult(
            .failure(message: "API key could not be saved securely. Please try again."),
            savedAPIKey: "new-claude-key"
        )

        #expect(failureMessage(from: result) != nil)
        #expect(presentation.currentAPIKey == nil)
        #expect(!presentation.isConnected)
        #expect(loader.readOnlyReadCount == 1)
        #expect(loader.migratingReadCount == 0)
    }

    @Test func swiftUIValueReinitializationCanOnlyUseReadOnlyLoaderSeam() {
        let loader = APIKeyReadOnlyLoaderSpy(value: "legacy-key")

        _ = AIProviderAPIKeyPresentationState(provider: .openai, loader: loader)
        _ = AIProviderAPIKeyPresentationState(provider: .openai, loader: loader)

        #expect(loader.readOnlyReadCount == 2)
        #expect(loader.migratingReadCount == 0)
    }

    @Test func successfulPresentationMutationsUseTrimmedSavedKeyThenClearIt() {
        let loader = APIKeyReadOnlyLoaderSpy(value: nil)
        var presentation = AIProviderAPIKeyPresentationState(
            provider: .gemini,
            loader: loader
        )
        let success = AIProviderAPIKeyMutationResult.success(
            AIProviderAPIKeyMutationState(
                hasAnyAPIKey: true,
                replacementDefaultProvider: nil
            )
        )

        _ = presentation.applySaveResult(
            success,
            savedAPIKey: "  gemini-key\n"
        )
        #expect(presentation.currentAPIKey == "gemini-key")
        #expect(presentation.isConnected)

        _ = presentation.applyDisconnectResult(success)
        #expect(presentation.currentAPIKey == nil)
        #expect(!presentation.isConnected)
    }

    @Test func saveFailureReturnsSafeRetryableErrorWithoutRefreshingConnectionState() {
        let secret = "provider-secret-must-not-leak"
        var connectionStateReadCount = 0
        let coordinator = AIProviderAPIKeyMutationCoordinator(
            setAPIKey: { _, _ in
                throw MutationTestError.storageFailure("write echoed \(secret)")
            },
            removeAPIKey: { _ in },
            connectedProviders: {
                connectionStateReadCount += 1
                return [.openai]
            }
        )

        let result = coordinator.saveAPIKey(secret, for: .openai)

        let message = failureMessage(from: result)
        #expect(message != nil)
        #expect(message?.contains(secret) == false)
        #expect(message?.contains("write echoed") == false)
        #expect(connectionStateReadCount == 0)
    }

    @Test func primaryRemoveFailureDoesNotComputeSuccessState() {
        var connectionStateReadCount = 0
        let coordinator = AIProviderAPIKeyMutationCoordinator(
            setAPIKey: { _, _ in },
            removeAPIKey: { _ in
                throw MutationTestError.storageFailure("primary remove failed")
            },
            connectedProviders: {
                connectionStateReadCount += 1
                return []
            }
        )

        let result = coordinator.disconnect(
            provider: .openai,
            currentDefaultProvider: .openai
        )

        #expect(failureMessage(from: result) != nil)
        #expect(connectionStateReadCount == 0)
    }

    @Test func legacyRemoveFailureCannotTriggerStateScanThatRemigratesTheKey() {
        var remigrationCount = 0
        let coordinator = AIProviderAPIKeyMutationCoordinator(
            setAPIKey: { _, _ in },
            removeAPIKey: { _ in
                throw MutationTestError.storageFailure("legacy remove failed")
            },
            connectedProviders: {
                remigrationCount += 1
                return [.openai]
            }
        )

        let result = coordinator.disconnect(
            provider: .openai,
            currentDefaultProvider: .openai
        )

        #expect(failureMessage(from: result) != nil)
        #expect(remigrationCount == 0)
    }

    @Test func successfulDefaultProviderDisconnectReturnsAllUIStateAsOneValue() {
        let coordinator = AIProviderAPIKeyMutationCoordinator(
            setAPIKey: { _, _ in },
            removeAPIKey: { _ in },
            connectedProviders: { [.claude] }
        )

        let result = coordinator.disconnect(
            provider: .openai,
            currentDefaultProvider: .openai
        )

        #expect(
            result == .success(
                AIProviderAPIKeyMutationState(
                    hasAnyAPIKey: true,
                    replacementDefaultProvider: .claude
                )
            )
        )
    }

    @Test func successfulSaveReportsConnectedStateWithoutChangingDefaultProvider() {
        var connectionStateReadCount = 0
        let coordinator = AIProviderAPIKeyMutationCoordinator(
            setAPIKey: { _, _ in },
            removeAPIKey: { _ in },
            connectedProviders: {
                connectionStateReadCount += 1
                return []
            }
        )

        let result = coordinator.saveAPIKey("gemini-key", for: .gemini)

        #expect(
            result == .success(
                AIProviderAPIKeyMutationState(
                    hasAnyAPIKey: true,
                    replacementDefaultProvider: nil
                )
            )
        )
        #expect(connectionStateReadCount == 0)
    }

    @Test func removalBatchContinuesAfterPrimaryFailureAndThrowsTheFailure() {
        var attemptedStores: [String] = []

        #expect(throws: MutationTestError.storageFailure("primary remove failed")) {
            try KeychainMutationBatch.execute([
                {
                    attemptedStores.append("primary")
                    throw MutationTestError.storageFailure("primary remove failed")
                },
                {
                    attemptedStores.append("legacy")
                },
            ])
        }

        #expect(attemptedStores == ["primary", "legacy"])
    }

    @Test func removalBatchPropagatesLegacyFailureAfterTryingEveryStore() {
        var attemptedStores: [String] = []

        #expect(throws: MutationTestError.storageFailure("legacy remove failed")) {
            try KeychainMutationBatch.execute([
                {
                    attemptedStores.append("primary")
                },
                {
                    attemptedStores.append("legacy-one")
                    throw MutationTestError.storageFailure("legacy remove failed")
                },
                {
                    attemptedStores.append("legacy-two")
                },
            ])
        }

        #expect(attemptedStores == ["primary", "legacy-one", "legacy-two"])
    }

    private func failureMessage(from result: AIProviderAPIKeyMutationResult) -> String? {
        guard case .failure(let message) = result else { return nil }
        return message
    }
}

private enum MutationTestError: Error, Equatable {
    case storageFailure(String)
}

private final class APIKeyReadOnlyLoaderSpy: AIProviderAPIKeyReadOnlyLoading {
    private let value: String?
    private(set) var readOnlyReadCount = 0
    private(set) var migratingReadCount = 0

    init(value: String?) {
        self.value = value
    }

    func readOnlyAPIKey(for provider: AIProvider) -> String? {
        readOnlyReadCount += 1
        return value
    }

    /// Deliberately not part of `AIProviderAPIKeyReadOnlyLoading`; a nonzero
    /// count would prove presentation code escaped the no-side-effect seam.
    func migratingAPIKey(for provider: AIProvider) -> String? {
        migratingReadCount += 1
        return value
    }
}
