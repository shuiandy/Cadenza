import Foundation

protocol OpenAITranscriptionRequesting: Sendable {
    func transcribe(multipartBody: Data, boundary: String) async throws -> Data
}

struct OpenAITranscriptionAPIClient: OpenAITranscriptionRequesting, Sendable {
    private static let endpoint = URL(
        string: "https://api.openai.com/v1/audio/transcriptions"
    )!

    private let apiKey: String
    private let transport: HardenedAITransport

    init(
        apiKey: String,
        transport: HardenedAITransport = .transcription
    ) {
        self.apiKey = apiKey
        self.transport = transport
    }

    func transcribe(multipartBody: Data, boundary: String) async throws -> Data {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
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
                redacting: [apiKey]
            )
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw error
        }
    }
}
