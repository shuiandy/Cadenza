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
            calendarEvent: .omitted
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

    @Test @MainActor
    func mcpPrefsDecodeUsesServerWireKeys() async throws {
        let http = FakeAuthHTTP()
        let client = WebSyncAPIClient(auth: signedIn(http: http))
        http.mcpPrefsOutcome = .success(
            data: Data(#"{"search_index_enabled":true,"search_index_generation":3,"speaker_identity_enabled":false,"speaker_identity_generation":1,"updated_at":1780000000}"#.utf8),
            response: response(status: 200)
        )

        let prefs = try #require(await client.fetchMCPPrefs())
        #expect(prefs.searchIndexEnabled)
        #expect(prefs.searchIndexGeneration == 3)
        #expect(!prefs.speakerIdentityEnabled)
        #expect(prefs.speakerIdentityGeneration == 1)
        #expect(prefs.updatedAt == 1_780_000_000)
    }

    @Test @MainActor
    func speakerSyncUsesQueryForPullAndSnakeCaseForPush() async throws {
        let http = FakeAuthHTTP()
        let client = WebSyncAPIClient(auth: signedIn(http: http))
        http.enqueue(.success(
            data: Data(#"{"identity_enabled":true,"identity_generation":2,"voice_enabled":false,"voice_generation":1,"profiles":[],"samples":[],"cursor":5,"has_more":false}"#.utf8),
            response: response(status: 200)
        ))
        http.enqueue(.success(
            data: Data(#"{"applied_profiles":1,"applied_samples":0,"skipped_profile_ids":[],"skipped_samples":[]}"#.utf8),
            response: response(status: 200)
        ))
        let profileID = UUID(uuidString: "7C0E0D3E-2F7B-4A57-9D51-3C1F9C3E2A10")!

        let pulled = try await client.pullSpeakerChanges(since: 5, limit: 200, modelVersions: ["model v1"])
        _ = try await client.pushSpeakerChanges(SpeakerSyncPushRequest(
            identityGeneration: 2,
            voiceGeneration: nil,
            profiles: [SpeakerSyncProfile(
                profileID: profileID, displayName: "Ada Example", aliases: [], notes: "",
                teamOrOrg: nil, createdAt: 1_789_000_000, lastSeenAt: nil
            )],
            deletedProfileIDs: [],
            samples: [],
            deletedSamples: []
        ))

        let pullURL = try #require(http.requests[0].url)
        let query = URLComponents(url: pullURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(pullURL.path.hasSuffix("/speakers/changes"))
        #expect(query == [
            URLQueryItem(name: "since", value: "5"),
            URLQueryItem(name: "limit", value: "200"),
            URLQueryItem(name: "model_version", value: "model v1"),
        ])
        #expect(pulled.identityGeneration == 2 && !pulled.voiceEnabled && pulled.cursor == 5)

        #expect(http.requests[1].httpMethod == "POST")
        let body = try #require(http.requests[1].httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["voice_generation"] == nil)
        #expect(object["identity_generation"] as? Int == 2)
        let profile = try #require((object["profiles"] as? [[String: Any]])?.first)
        #expect(profile["profile_id"] as? String == "7c0e0d3e-2f7b-4a57-9d51-3c1f9c3e2a10")
        #expect(profile["display_name"] as? String == "Ada Example")
        #expect(profile["team_or_org"] is NSNull)
    }

    private func response(status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://cadenzapp.test")!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }
}
