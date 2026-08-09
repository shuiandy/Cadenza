import Foundation

struct AIProviderAPIKeyMutationState: Equatable, Sendable {
    let hasAnyAPIKey: Bool
    let replacementDefaultProvider: AIProvider?
}

enum AIProviderAPIKeyMutationResult: Equatable, Sendable {
    case success(AIProviderAPIKeyMutationState)
    case failure(message: String)
}

/// Narrow storage seam for UI snapshots. It deliberately exposes no migrating
/// lookup, so rebuilding a SwiftUI value cannot write to Keychain.
protocol AIProviderAPIKeyReadOnlyLoading {
    func readOnlyAPIKey(for provider: AIProvider) -> String?
}

extension KeychainManager: AIProviderAPIKeyReadOnlyLoading {}

/// Value snapshot used by settings rows so rendering never reads from Keychain.
/// Storage is consulted only when a row is initialized or deliberately rebuilt.
struct AIProviderAPIKeyPresentationState: Equatable, Sendable {
    private(set) var currentAPIKey: String?

    var isConnected: Bool {
        guard let currentAPIKey else { return false }
        return !currentAPIKey.isEmpty
    }

    init(
        provider: AIProvider,
        loader: any AIProviderAPIKeyReadOnlyLoading = KeychainManager.shared
    ) {
        currentAPIKey = loader.readOnlyAPIKey(for: provider)
    }

    @discardableResult
    mutating func applySaveResult(
        _ result: AIProviderAPIKeyMutationResult,
        savedAPIKey: String
    ) -> AIProviderAPIKeyMutationResult {
        if case .success = result {
            currentAPIKey = savedAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    @discardableResult
    mutating func applyDisconnectResult(
        _ result: AIProviderAPIKeyMutationResult
    ) -> AIProviderAPIKeyMutationResult {
        if case .success = result {
            currentAPIKey = nil
        }
        return result
    }
}

@MainActor
struct AIProviderAPIKeyMutationCoordinator {
    typealias SetAPIKey = (String, AIProvider) throws -> Void
    typealias RemoveAPIKey = (AIProvider) throws -> Void
    typealias ConnectedProviders = () -> [AIProvider]

    private let setAPIKey: SetAPIKey
    private let removeAPIKey: RemoveAPIKey
    private let connectedProviders: ConnectedProviders

    init(
        setAPIKey: @escaping SetAPIKey = { key, provider in
            try KeychainManager.shared.setAPIKey(key, for: provider)
        },
        removeAPIKey: @escaping RemoveAPIKey = { provider in
            try KeychainManager.shared.removeAPIKey(for: provider)
        },
        connectedProviders: @escaping ConnectedProviders = {
            AIProvider.allCases.filter {
                $0.requiresAPIKey && KeychainManager.shared.hasAPIKey(for: $0)
            }
        }
    ) {
        self.setAPIKey = setAPIKey
        self.removeAPIKey = removeAPIKey
        self.connectedProviders = connectedProviders
    }

    func saveAPIKey(_ apiKey: String, for provider: AIProvider) -> AIProviderAPIKeyMutationResult {
        do {
            try setAPIKey(apiKey, provider)
            return .success(AIProviderAPIKeyMutationState(
                hasAnyAPIKey: true,
                replacementDefaultProvider: nil
            ))
        } catch {
            NSLog("[APIKeyMutation] secure API key write failed for %@", provider.rawValue)
            return .failure(message: String(localized: "API key could not be saved securely. Please try again."))
        }
    }

    func disconnect(
        provider: AIProvider,
        currentDefaultProvider: AIProvider?
    ) -> AIProviderAPIKeyMutationResult {
        do {
            try removeAPIKey(provider)
            let remainingProviders = connectedProviders()
            let replacement = currentDefaultProvider == provider
                ? (remainingProviders.first ?? .apple)
                : nil
            return .success(AIProviderAPIKeyMutationState(
                hasAnyAPIKey: !remainingProviders.isEmpty,
                replacementDefaultProvider: replacement
            ))
        } catch {
            NSLog("[APIKeyMutation] secure API key removal failed for %@", provider.rawValue)
            return .failure(message: String(localized: "API key could not be removed securely. Please try again."))
        }
    }
}
