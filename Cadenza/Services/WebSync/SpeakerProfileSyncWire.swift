import CryptoKit
import Foundation

// MARK: - Sync records

/// A speaker profile as the speaker sync protocol carries it. Timestamps are
/// whole Unix seconds on the wire, so a local `Date` is rounded before it is
/// compared or sent.
struct SpeakerSyncProfile: Encodable, Sendable, Equatable {
    let profileID: UUID
    var displayName: String
    var aliases: [String]
    var notes: String
    var teamOrOrg: String?
    var createdAt: Int64
    var lastSeenAt: Int64?

    enum CodingKeys: String, CodingKey {
        case profileID = "profile_id"
        case displayName = "display_name"
        case aliases
        case notes
        case teamOrOrg = "team_or_org"
        case createdAt = "created_at"
        case lastSeenAt = "last_seen_at"
    }

    /// Stable across encoders: fields are joined in a fixed order instead of
    /// hashing JSON, whose key order and number spelling are not guaranteed.
    var fingerprint: String {
        SpeakerSyncFingerprint.digest([
            profileID.uuidString.lowercased(),
            displayName,
            aliases.joined(separator: "\u{1E}"),
            notes,
            teamOrOrg ?? "\u{0}",
            String(createdAt),
            lastSeenAt.map(String.init) ?? "\u{0}",
        ])
    }
}

/// Identifies one voice sample across devices. A recording's speaker can hold
/// one sample per embedding model, because vectors from different models are
/// not comparable and each device keeps its own.
struct SpeakerSyncSampleKey: Codable, Sendable, Hashable {
    let recordingID: UUID
    let rawLabel: String
    let modelVersion: String

    enum CodingKeys: String, CodingKey {
        case recordingID = "client_recording_id"
        case rawLabel = "raw_label"
        case modelVersion = "model_version"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(recordingID.uuidString.lowercased(), forKey: .recordingID)
        try container.encode(rawLabel, forKey: .rawLabel)
        try container.encode(modelVersion, forKey: .modelVersion)
    }
}

struct SpeakerSyncSample: Sendable, Equatable {
    let key: SpeakerSyncSampleKey
    var profileID: UUID
    /// Float32 little-endian, exactly `SpeakerVoiceSample.embeddingData`.
    var embedding: Data
    var embeddingDimension: Int
    var sampleDuration: Double
    var nonOverlapRatio: Float
    var qualityScore: Float
    var createdAt: Int64

    var fingerprint: String {
        SpeakerSyncFingerprint.digest([
            key.recordingID.uuidString.lowercased(),
            key.rawLabel,
            key.modelVersion,
            profileID.uuidString.lowercased(),
            embedding.base64EncodedString(),
            String(embeddingDimension),
            String(sampleDuration.bitPattern, radix: 16),
            String(nonOverlapRatio.bitPattern, radix: 16),
            String(qualityScore.bitPattern, radix: 16),
            String(createdAt),
        ])
    }
}

enum SpeakerSyncFingerprint {
    static func digest(_ fields: [String]) -> String {
        let joined = fields.joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func unixSeconds(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970.rounded())
    }
}

// MARK: - Pull

struct SpeakerSyncPullResponse: Decodable, Sendable {
    let identityEnabled: Bool
    let identityGeneration: Int64
    let voiceEnabled: Bool
    let voiceGeneration: Int64
    let profiles: [SpeakerSyncProfileChange]
    let samples: [SpeakerSyncSampleChange]
    let cursor: Int64
    let hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case identityEnabled = "identity_enabled"
        case identityGeneration = "identity_generation"
        case voiceEnabled = "voice_enabled"
        case voiceGeneration = "voice_generation"
        case profiles
        case samples
        case cursor
        case hasMore = "has_more"
    }
}

/// One profile row from a pull. A tombstone carries only its id and `seq`.
struct SpeakerSyncProfileChange: Decodable, Sendable, Equatable {
    let profileID: UUID
    let seq: Int64
    let deleted: Bool
    let displayName: String?
    let aliases: [String]?
    let notes: String?
    let teamOrOrg: String?
    let createdAt: Int64?
    let lastSeenAt: Int64?

    enum CodingKeys: String, CodingKey {
        case profileID = "profile_id"
        case seq
        case deleted
        case displayName = "display_name"
        case aliases
        case notes
        case teamOrOrg = "team_or_org"
        case createdAt = "created_at"
        case lastSeenAt = "last_seen_at"
    }

    /// Nil for a tombstone, or for a live row missing a field it must carry.
    var profile: SpeakerSyncProfile? {
        guard !deleted, let displayName, let createdAt else { return nil }
        return SpeakerSyncProfile(
            profileID: profileID,
            displayName: displayName,
            aliases: aliases ?? [],
            notes: notes ?? "",
            teamOrOrg: teamOrOrg,
            createdAt: createdAt,
            lastSeenAt: lastSeenAt
        )
    }
}

struct SpeakerSyncSampleChange: Decodable, Sendable, Equatable {
    let key: SpeakerSyncSampleKey
    let seq: Int64
    let deleted: Bool
    let profileID: UUID?
    let embedding: Data?
    let embeddingDimension: Int?
    let sampleDuration: Double?
    let nonOverlapRatio: Float?
    let qualityScore: Float?
    let createdAt: Int64?

    enum CodingKeys: String, CodingKey {
        case recordingID = "client_recording_id"
        case rawLabel = "raw_label"
        case modelVersion = "model_version"
        case seq
        case deleted
        case profileID = "profile_id"
        case embedding
        case embeddingDimension = "embedding_dimension"
        case sampleDuration = "sample_duration"
        case nonOverlapRatio = "non_overlap_ratio"
        case qualityScore = "quality_score"
        case createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = SpeakerSyncSampleKey(
            recordingID: try container.decode(UUID.self, forKey: .recordingID),
            rawLabel: try container.decode(String.self, forKey: .rawLabel),
            modelVersion: try container.decode(String.self, forKey: .modelVersion)
        )
        seq = try container.decode(Int64.self, forKey: .seq)
        deleted = try container.decode(Bool.self, forKey: .deleted)
        profileID = try container.decodeIfPresent(UUID.self, forKey: .profileID)
        embedding = try container.decodeIfPresent(Data.self, forKey: .embedding)
        embeddingDimension = try container.decodeIfPresent(Int.self, forKey: .embeddingDimension)
        sampleDuration = try container.decodeIfPresent(Double.self, forKey: .sampleDuration)
        nonOverlapRatio = try container.decodeIfPresent(Float.self, forKey: .nonOverlapRatio)
        qualityScore = try container.decodeIfPresent(Float.self, forKey: .qualityScore)
        createdAt = try container.decodeIfPresent(Int64.self, forKey: .createdAt)
    }

    /// Nil for a tombstone, or for a live row whose vector does not match its
    /// declared dimension (a corrupt vector must never reach cosine matching).
    var sample: SpeakerSyncSample? {
        guard !deleted,
              let profileID,
              let embedding,
              let embeddingDimension,
              embeddingDimension > 0,
              embedding.count == embeddingDimension * MemoryLayout<Float>.size,
              let sampleDuration,
              let nonOverlapRatio,
              let qualityScore,
              let createdAt else { return nil }
        return SpeakerSyncSample(
            key: key,
            profileID: profileID,
            embedding: embedding,
            embeddingDimension: embeddingDimension,
            sampleDuration: sampleDuration,
            nonOverlapRatio: nonOverlapRatio,
            qualityScore: qualityScore,
            createdAt: createdAt
        )
    }
}

// MARK: - Push

struct SpeakerSyncPushRequest: Encodable, Sendable, Equatable {
    let identityGeneration: Int64
    let voiceGeneration: Int64?
    var profiles: [SpeakerSyncProfile]
    var deletedProfileIDs: [UUID]
    var samples: [SpeakerSyncSample]
    var deletedSamples: [SpeakerSyncSampleKey]

    enum CodingKeys: String, CodingKey {
        case identityGeneration = "identity_generation"
        case voiceGeneration = "voice_generation"
        case profiles
        case deletedProfileIDs = "deleted_profile_ids"
        case samples
        case deletedSamples = "deleted_samples"
    }

    var isEmpty: Bool {
        profiles.isEmpty && deletedProfileIDs.isEmpty && samples.isEmpty && deletedSamples.isEmpty
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(identityGeneration, forKey: .identityGeneration)
        if let voiceGeneration {
            try container.encode(voiceGeneration, forKey: .voiceGeneration)
        }
        try container.encode(profiles, forKey: .profiles)
        try container.encode(deletedProfileIDs.map { $0.uuidString.lowercased() }, forKey: .deletedProfileIDs)
        try container.encode(samples, forKey: .samples)
        try container.encode(deletedSamples, forKey: .deletedSamples)
    }
}

extension SpeakerSyncProfile {
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(profileID.uuidString.lowercased(), forKey: .profileID)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(aliases, forKey: .aliases)
        try container.encode(notes, forKey: .notes)
        if let teamOrOrg {
            try container.encode(teamOrOrg, forKey: .teamOrOrg)
        } else {
            try container.encodeNil(forKey: .teamOrOrg)
        }
        try container.encode(createdAt, forKey: .createdAt)
        if let lastSeenAt {
            try container.encode(lastSeenAt, forKey: .lastSeenAt)
        } else {
            try container.encodeNil(forKey: .lastSeenAt)
        }
    }
}

extension SpeakerSyncSample: Encodable {
    private enum CodingKeys: String, CodingKey {
        case recordingID = "client_recording_id"
        case rawLabel = "raw_label"
        case modelVersion = "model_version"
        case profileID = "profile_id"
        case embedding
        case embeddingDimension = "embedding_dimension"
        case sampleDuration = "sample_duration"
        case nonOverlapRatio = "non_overlap_ratio"
        case qualityScore = "quality_score"
        case createdAt = "created_at"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key.recordingID.uuidString.lowercased(), forKey: .recordingID)
        try container.encode(key.rawLabel, forKey: .rawLabel)
        try container.encode(key.modelVersion, forKey: .modelVersion)
        try container.encode(profileID.uuidString.lowercased(), forKey: .profileID)
        try container.encode(embedding, forKey: .embedding)
        try container.encode(embeddingDimension, forKey: .embeddingDimension)
        try container.encode(sampleDuration, forKey: .sampleDuration)
        try container.encode(nonOverlapRatio, forKey: .nonOverlapRatio)
        try container.encode(qualityScore, forKey: .qualityScore)
        try container.encode(createdAt, forKey: .createdAt)
    }
}

struct SpeakerSyncPushResponse: Decodable, Sendable, Equatable {
    let appliedProfiles: Int
    let appliedSamples: Int
    let skippedProfileIDs: [UUID]
    let skippedSamples: [SpeakerSyncSampleKey]

    enum CodingKeys: String, CodingKey {
        case appliedProfiles = "applied_profiles"
        case appliedSamples = "applied_samples"
        case skippedProfileIDs = "skipped_profile_ids"
        case skippedSamples = "skipped_samples"
    }
}
