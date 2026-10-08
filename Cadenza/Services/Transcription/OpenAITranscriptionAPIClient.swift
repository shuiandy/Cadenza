import Foundation

protocol OpenAITranscriptionRequesting: Sendable {
    func transcribe(multipartBody: Data, boundary: String) async throws -> Data
}

struct OpenAITranscriptionAPIClient: OpenAITranscriptionRequesting, Sendable {
    private let access: AIProviderAccess
    private let transport: HardenedAITransport

    init(
        access: AIProviderAccess,
        transport: HardenedAITransport = .transcription
    ) {
        self.access = AIProviderAccess(provider: .openai, route: access.route)
        self.transport = transport
    }

    init(
        apiKey: String,
        transport: HardenedAITransport = .transcription
    ) {
        self.init(access: .direct(.openai, apiKey: apiKey), transport: transport)
    }

    func transcribe(multipartBody: Data, boundary: String) async throws -> Data {
        var request = URLRequest(url: try access.url(path: "/v1/audio/transcriptions"))
        request.httpMethod = "POST"
        access.authorize(&request)
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = multipartBody
        request.timeoutInterval = 300

        do {
            return try await transport.data(
                for: request,
                provider: .openai,
                redacting: access.secrets,
                viaCadenza: access.viaCadenza
            )
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw error
        }
    }
}
