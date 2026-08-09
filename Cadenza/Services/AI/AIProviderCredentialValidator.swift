import Foundation

struct AIProviderCredentialValidator: Sendable {
    private let modelListService: AIChatModelListService

    init(modelListService: AIChatModelListService = AIChatModelListService()) {
        self.modelListService = modelListService
    }

    func validateAPIKey(_ apiKey: String, provider: AIProvider) async -> String? {
        guard provider.requiresAPIKey else {
            return nil
        }

        do {
            try await modelListService.validateCredential(for: provider, apiKey: apiKey)
            return nil
        } catch AIServiceError.httpError(let statusCode, _) {
            switch statusCode {
            case 401:
                return String(localized: "Invalid API key")
            case 403:
                return String(localized: "API key doesn't have required permissions")
            case 429:
                return nil
            default:
                return String(localized: "Server returned HTTP \(statusCode)")
            }
        } catch {
            return String(localized: "Connection failed")
        }
    }
}
