import Foundation
import Testing
@testable import Cadenza

@Suite("Web sync API client")
struct WebSyncAPIClientTests {
    @MainActor
    private func signedIn(http: FakeAuthHTTP) -> CadenzaAuthService {
        let secrets = InMemoryAuthSecretStore()
        try! writeStoredToken(into: secrets, value: "token", expiresAt: Date().addingTimeInterval(3_600))
        let users = InMemoryUserStore()
        users.user = .init(id: "user-1", email: "u@example.com", displayName: "User", pictureURL: nil)
        return try! CadenzaAuthService.bootstrapped(
            sessionProfile: AuthTestProfile.bound(userID: "user-1"),
            http: http,
            authorizer: FakeAuthorizationProvider(),
            secretStore: secrets,
            sessionUserStore: users,
            registry: ScriptedRegistry(document: makeAuthRegistryDocument(userID: "user-1"))
        )
    }

    @Test @MainActor
    func structuredAndRawAudioRequestsUseExpectedWireContract() async throws {
        let http = FakeAuthHTTP()
        let auth = signedIn(http: http)
        let client = WebSyncAPIClient(auth: auth)
        let upsertJSON = Data(#"{"recording_id":"remote-1","version":1,"content_hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","audio_state":"not_uploaded"}"#.utf8)
        http.enqueue(.success(data: upsertJSON, response: response(status: 201)))
        http.enqueue(.success(data: Data(#"{"received":true,"parts_received":[1]}"#.utf8), response: response(status: 200)))

        let payload = WebSyncPayload(
            protocolVersion: 1,
            contentHash: String(repeating: "a", count: 64),
            title: "Title",
            createdAtLocal: 1,
            durationMs: 1,
            folder: "",
            tags: [],
            trashedAt: nil,
            audioSourceState: .eligible,
            transcript: nil,
            summary: nil,
            calendarEvent: nil
        )
        _ = try await client.upsert(
            clientRecordingID: UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!,
            payloadData: try JSONEncoder().encode(payload)
        )
        try await client.putAudioPart(
            sessionID: "session-1",
            number: 1,
            chunk: .init(data: Data([1, 2, 3]), sha256: "abc")
        )

        #expect(http.requests[0].url?.path.hasSuffix("/sync/recordings/12345678-1234-1234-1234-123456789abc") == true)
        #expect(http.requests[0].value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(http.requests[1].value(forHTTPHeaderField: "Content-Type") == "application/octet-stream")
        #expect(http.requests[1].value(forHTTPHeaderField: "X-Chunk-SHA256") == "abc")
    }

    @Test @MainActor
    func uploadSessionStatusIncludesResumeGeometry() async throws {
        let http = FakeAuthHTTP()
        let client = WebSyncAPIClient(auth: signedIn(http: http))
        http.enqueue(.success(
            data: Data(#"{"session_id":"session-1","recording_id":"remote-1","state":"uploading","total_size":524288,"chunk_size":262144,"parts_received":[{"n":1}]}"#.utf8),
            response: response(status: 200)
        ))

        let status = try await client.getAudioSession(id: "session-1")

        #expect(status.totalSize == 524_288)
        #expect(status.chunkSize == 262_144)
        #expect(status.partsReceived == [1])
    }

    private func response(status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://cadenzapp.test")!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }
}
