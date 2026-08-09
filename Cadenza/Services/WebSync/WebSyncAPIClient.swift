import Foundation

struct WebSyncUpsertResponse: Decodable, Sendable {
    let recordingID: String
    let version: Int
    let contentHash: String
    let audioState: String

    enum CodingKeys: String, CodingKey {
        case recordingID = "recording_id"
        case version
        case contentHash = "content_hash"
        case audioState = "audio_state"
    }
}

struct WebSyncAudioSessionRequest: Encodable, Sendable {
    let idempotencyKey: String
    let totalSize: Int64
    let chunkSize: Int64
    let codec: String
    let container: String
    let sourceFingerprint: String

    enum CodingKeys: String, CodingKey {
        case idempotencyKey = "idempotency_key"
        case totalSize = "total_size"
        case chunkSize = "chunk_size"
        case codec
        case container
        case sourceFingerprint = "source_fingerprint"
    }
}

struct WebSyncAudioSessionResponse: Decodable, Sendable {
    let sessionID: String
    let recordingID: String
    let expiresAt: Int64

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case recordingID = "recording_id"
        case expiresAt = "expires_at"
    }
}

struct WebSyncAudioSessionStatus: Sendable {
    let sessionID: String
    let recordingID: String
    let state: String
    let totalSize: Int64
    let chunkSize: Int64
    let partsReceived: Set<Int>
}

struct WebSyncAudioManifest: Encodable, Sendable {
    struct Part: Encodable, Sendable {
        let n: Int
        let sizePlaintext: Int64
        let sha256Plaintext: String

        enum CodingKeys: String, CodingKey {
            case n
            case sizePlaintext = "size_plaintext"
            case sha256Plaintext = "sha256_plaintext"
        }
    }

    let codec: String
    let container: String
    let durationMs: Int64
    let chunks: [Part]
}

struct WebSyncAudioCommitResponse: Decodable, Sendable {
    let recordingID: String
    let version: Int
    let ready: Bool

    enum CodingKeys: String, CodingKey {
        case recordingID = "recording_id"
        case version
        case ready
    }
}

@MainActor
final class WebSyncAPIClient {
    private let auth: CadenzaAuthService
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    init(auth: CadenzaAuthService) {
        self.auth = auth
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    }

    func upsert(clientRecordingID: UUID, payloadData: Data) async throws -> WebSyncUpsertResponse {
        let response = try await auth.request(
            path: "sync/recordings/\(clientRecordingID.uuidString.lowercased())",
            method: "PUT",
            body: payloadData
        )
        return try decoder.decode(WebSyncUpsertResponse.self, from: response)
    }

    func createAudioSession(
        remoteRecordingID: String,
        request: WebSyncAudioSessionRequest
    ) async throws -> WebSyncAudioSessionResponse {
        let response = try await auth.request(
            path: "sync/recordings/\(remoteRecordingID)/audio/sessions",
            method: "POST",
            body: try encoder.encode(request)
        )
        return try decoder.decode(WebSyncAudioSessionResponse.self, from: response)
    }

    func getAudioSession(id: String) async throws -> WebSyncAudioSessionStatus {
        let data = try await auth.request(path: "uploads/sessions/\(id)")
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let object,
              let sessionID = object["session_id"] as? String,
              let recordingID = object["recording_id"] as? String,
              let state = object["state"] as? String,
              let totalSize = (object["total_size"] as? NSNumber)?.int64Value,
              let chunkSize = (object["chunk_size"] as? NSNumber)?.int64Value else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid upload session"))
        }
        let rawParts = object["parts_received"] as? [Any] ?? []
        let numbers = rawParts.compactMap { value -> Int? in
            if let number = value as? Int { return number }
            if let dictionary = value as? [String: Any] { return dictionary["n"] as? Int }
            return nil
        }
        return WebSyncAudioSessionStatus(
            sessionID: sessionID,
            recordingID: recordingID,
            state: state,
            totalSize: totalSize,
            chunkSize: chunkSize,
            partsReceived: Set(numbers)
        )
    }

    func putAudioPart(sessionID: String, number: Int, chunk: WebSyncAudioChunk) async throws {
        _ = try await auth.requestResponse(
            path: "uploads/sessions/\(sessionID)/parts/\(number)",
            method: "PUT",
            body: chunk.data,
            contentType: "application/octet-stream",
            headers: ["X-Chunk-SHA256": chunk.sha256]
        )
    }

    func commitAudio(sessionID: String, manifest: WebSyncAudioManifest) async throws -> WebSyncAudioCommitResponse {
        struct Body: Encodable {
            struct Manifest: Encodable {
                struct Audio: Encodable {
                    let codec: String
                    let container: String
                    let chunks: [WebSyncAudioManifest.Part]
                }
                let version: Int
                let audio: Audio
                let durationMs: Int64

                enum CodingKeys: String, CodingKey {
                    case version
                    case audio
                    case durationMs = "duration_ms"
                }
            }
            let manifest: Manifest
        }
        let body = Body(manifest: .init(
            version: 1,
            audio: .init(codec: manifest.codec, container: manifest.container, chunks: manifest.chunks),
            durationMs: manifest.durationMs
        ))
        let data = try await auth.request(
            path: "uploads/sessions/\(sessionID)/commit",
            method: "POST",
            body: try encoder.encode(body)
        )
        return try decoder.decode(WebSyncAudioCommitResponse.self, from: data)
    }

    /// Fetches the entitlement snapshot through the authenticated request
    /// path, classifying the outcome with the frozen contract.
    ///
    /// Every failure shape becomes a resolution rather than an error, because
    /// the caller's answer to all of them is the same: learn nothing and keep
    /// what it already had. The status is what reaches the classifier, so a
    /// missing endpoint is read against the caller-proven service identity
    /// instead of being guessed from the body.
    func fetchEntitlements(service: EntitlementsService) async -> EntitlementsResolution {
        do {
            let (data, response) = try await auth.requestResponse(path: "me/entitlements")
            return EntitlementsResolution.classify(
                status: response.statusCode, body: data, service: service
            )
        } catch CadenzaAPIError.backend(_, let status) {
            return EntitlementsResolution.classify(status: status, body: Data(), service: service)
        } catch AuthError.server(let status) {
            return EntitlementsResolution.classify(status: status, body: Data(), service: service)
        } catch CadenzaAPIError.unauthorized {
            return .unavailable(status: 401)
        } catch {
            // Transport failures and a session that cannot issue requests carry
            // no status of their own.
            return .unavailable(status: 0)
        }
    }

    func delete(clientRecordingID: UUID) async throws {
        _ = try await auth.request(
            path: "sync/recordings/\(clientRecordingID.uuidString.lowercased())",
            method: "DELETE"
        )
    }
}
