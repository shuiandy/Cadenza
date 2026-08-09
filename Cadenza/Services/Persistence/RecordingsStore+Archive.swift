import Foundation
import SwiftData

/// Per-recording payload for the Portable Archive — the detail DTO plus the
/// fields it doesn't carry (trash state, crash-recovery segments directory).
/// Audio locations are resolved to URLs at the store boundary; the writer
/// never interprets stored path strings.
struct ArchiveRecordingRecord: Sendable {
    var detail: RecordingDetailDTO
    var trashedDate: Date?
    var audioFileURL: URL?
    var audioSegmentsDirectoryURL: URL?
    var calendarAutoLinkState: String? = nil
    var audioOwnership: String? = nil
}

/// Lightweight per-recording sizing row for disk preflight — id + the two
/// resolved locations only, so estimating never loads transcripts into
/// memory.
struct ArchiveSizingInfo: Sendable {
    let recordingID: UUID
    let audioFileURL: URL?
    let audioSegmentsDirectoryURL: URL?
}

/// Voice sample including raw embedding bytes (the existing
/// `VoiceSampleSnapshot` deliberately omits them; the archive needs them
/// when the user opts in).
struct ArchiveVoiceSampleRecord: Sendable {
    var recordingID: UUID
    var rawLabel: String
    var profileID: UUID?
    var embeddingData: Data
    var embeddingDimension: Int
    var sampleDuration: TimeInterval
    var nonOverlapRatio: Float
    var qualityScore: Float
    var modelVersion: String
    var createdAt: Date
}

/// Store-level entities captured in ONE actor call, so folders / recaps /
/// artifacts / speaker profiles and the recording list are mutually
/// consistent (catalog-atomic). Recordings themselves are still fetched
/// one-by-one afterwards for memory reasons; a recording that references a
/// folder missing from this catalog is surfaced as an export failure, never
/// silently archived as a dangling reference.
struct ArchiveCatalog: Sendable {
    var sizing: [ArchiveSizingInfo]
    var folders: [ArchiveFolder]
    var recaps: [ArchiveRecap]
    var artifacts: [ArchiveAgentArtifact]
    var speakerProfiles: [ArchiveSpeakerProfile]
}

extension RecordingsStore {

    /// Every recording (including trashed), oldest first — archive-only API.
    /// Throwing on purpose: a failed SwiftData fetch must abort the archive,
    /// not silently produce a "successful" empty one.
    func fetchArchiveRecordingIDs() throws -> [UUID] {
        var descriptor = FetchDescriptor<Recording>(
            sortBy: [SortDescriptor(\.startDate, order: .forward)]
        )
        descriptor.propertiesToFetch = [\.id, \.startDate]
        return try modelContext.fetch(descriptor)
            .map { (startDate: $0.startDate, id: $0.id) }
            .sorted { ($0.startDate, $0.id.uuidString) < ($1.startDate, $1.id.uuidString) }
            .map(\.id)
    }

    /// One-shot consistent snapshot of everything except per-recording
    /// content. See `ArchiveCatalog`.
    func fetchArchiveCatalog() throws -> ArchiveCatalog {
        var sizingDescriptor = FetchDescriptor<Recording>(
            sortBy: [SortDescriptor(\.startDate, order: .forward)]
        )
        sizingDescriptor.propertiesToFetch = [\.id, \.startDate, \.audioFilePath, \.audioSegmentsDirectory]
        let sizing = try modelContext.fetch(sizingDescriptor).map {
            (startDate: $0.startDate, info: ArchiveSizingInfo(
                recordingID: $0.id,
                audioFileURL: resolveURL($0.audioFileReference),
                audioSegmentsDirectoryURL: resolveURL($0.segmentsDirectoryReference)
            ))
        }.sorted {
            ($0.startDate, $0.info.recordingID.uuidString) < ($1.startDate, $1.info.recordingID.uuidString)
        }.map(\.info)

        // 非唯一键排序一律加 UUID tie-breaker，保证枚举顺序确定性。
        let folders = try modelContext.fetch(
            FetchDescriptor<Folder>(sortBy: [SortDescriptor(\.sortOrder)])
        ).map {
            ArchiveFolder(
                id: $0.id, name: $0.name, parentFolderID: $0.parentFolder?.id,
                icon: $0.icon, iconColor: $0.iconColor, colorHex: $0.colorHex,
                status: $0.status, createdAt: $0.createdAt, sortOrder: $0.sortOrder
            )
        }.sorted { ($0.sortOrder, $0.id.uuidString) < ($1.sortOrder, $1.id.uuidString) }

        let recaps = try modelContext.fetch(
            FetchDescriptor<Recap>(sortBy: [SortDescriptor(\.startDate, order: .forward)])
        ).map {
            ArchiveRecap(
                id: $0.id, period: $0.period, startDate: $0.startDate, endDate: $0.endDate,
                title: $0.title, overview: $0.overview, recordingIDs: $0.recordingIDs,
                allActionItems: $0.allActionItems, allDecisions: $0.allDecisions,
                sectionsJSON: String(decoding: $0.sectionsJSON, as: UTF8.self),
                statsJSON: String(decoding: $0.statsJSON, as: UTF8.self),
                provider: $0.provider, createdAt: $0.createdAt
            )
        }.sorted { ($0.startDate, $0.id.uuidString) < ($1.startDate, $1.id.uuidString) }

        // slotKey 的 unique 约束是字节级（SQLite），canonical-equivalent 的
        // 不同表示可以并存——同样按 UTF-8 code units 排序，不依赖 String 语义。
        let artifacts = try modelContext.fetch(
            FetchDescriptor<AgentArtifact>(sortBy: [SortDescriptor(\.slotKey, order: .forward)])
        ).map {
            ArchiveAgentArtifact(
                id: $0.id, kind: $0.kind, targetType: $0.targetType, targetKey: $0.targetKey,
                slotKey: $0.slotKey, bodyMarkdown: $0.bodyMarkdown,
                provenanceSource: $0.provenanceSource, provenanceDetail: $0.provenanceDetail,
                status: $0.status, generationID: $0.generationID,
                generatingStartedAt: $0.generatingStartedAt, errorClass: $0.errorClass,
                errorMessage: $0.errorMessage, lastAttemptedAt: $0.lastAttemptedAt,
                retryAfter: $0.retryAfter, targetStartDate: $0.targetStartDate,
                targetEndDate: $0.targetEndDate, targetFingerprint: $0.targetFingerprint,
                contextBuiltAt: $0.contextBuiltAt, staleReason: $0.staleReason,
                createdAt: $0.createdAt, updatedAt: $0.updatedAt
            )
        }.sorted { Self.utf8Less($0.slotKey, $1.slotKey) }

        let profiles = try modelContext.fetch(
            FetchDescriptor<SpeakerProfile>(sortBy: [SortDescriptor(\.createdAt, order: .forward)])
        ).map {
            ArchiveSpeakerProfile(
                id: $0.id, displayName: $0.displayName, aliases: $0.aliases,
                notes: $0.notes, teamOrOrg: $0.teamOrOrg,
                createdAt: $0.createdAt, lastSeenAt: $0.lastSeenAt
            )
        }.sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }

        return ArchiveCatalog(
            sizing: sizing, folders: folders, recaps: recaps,
            artifacts: artifacts, speakerProfiles: profiles
        )
    }

    /// Resolved audio URLs for a selected id set (batch-export preflight).
    /// In-memory filter — the NULL-tags #Predicate 铁律 also means we never
    /// put a constant-array `contains` into a predicate lightly.
    func fetchAudioPaths(recordingIDs: [UUID]) throws -> [UUID: URL] {
        let wanted = Set(recordingIDs)
        var descriptor = FetchDescriptor<Recording>()
        descriptor.propertiesToFetch = [\.id, \.audioFilePath]
        let recordings = try modelContext.fetch(descriptor)
        var result: [UUID: URL] = [:]
        for recording in recordings where wanted.contains(recording.id) {
            if let url = resolveURL(recording.audioFileReference) {
                result[recording.id] = url
            }
        }
        return result
    }

    func fetchArchiveRecording(recordingID: UUID) throws -> ArchiveRecordingRecord? {
        guard let bundle = try fetchArchiveDetailBundle(recordingID: recordingID) else { return nil }
        return ArchiveRecordingRecord(
            detail: bundle.detail,
            trashedDate: bundle.trashedDate,
            audioFileURL: resolveURL(bundle.detail.audioFile),
            audioSegmentsDirectoryURL: resolveURL(bundle.segmentsDirectory),
            calendarAutoLinkState: bundle.calendarAutoLinkState,
            audioOwnership: bundle.audioOwnership
        )
    }

    /// 排序必须是**真全序**（SpeakerVoiceSample 无 unique id，SwiftData 枚举
    /// 顺序未定义，embeddings.json 的字节级确定性依赖它）：
    /// - **逐字段 lexicographic 比较，不做字符串拼接**——拼接键不是可注入
    ///   编码，字段内容含分隔符时两条不同记录会碰撞出同一个 key。
    /// - 浮点字段按 bitPattern 比较：这是包含 NaN/±0 的总序（保证 strict
    ///   weak ordering），且位型不同的"等值"在 JSON 输出里本就是不同字节
    ///   （如 0 与 -0），必须区分。
    /// - 覆盖**所有**进入编码结果的字段；逐字段全等的记录才判等，此时换序
    ///   不影响输出字节。
    func fetchArchiveVoiceSamples(recordingID: UUID) throws -> [ArchiveVoiceSampleRecord] {
        let descriptor = FetchDescriptor<SpeakerVoiceSample>(
            predicate: #Predicate { $0.recordingID == recordingID }
        )
        return try modelContext.fetch(descriptor).map { sample in
            ArchiveVoiceSampleRecord(
                recordingID: sample.recordingID,
                rawLabel: sample.rawLabel,
                profileID: sample.profile?.id,
                embeddingData: sample.embeddingData,
                embeddingDimension: sample.embeddingDimension,
                sampleDuration: sample.sampleDuration,
                nonOverlapRatio: sample.nonOverlapRatio,
                qualityScore: sample.qualityScore,
                modelVersion: sample.modelVersion,
                createdAt: sample.createdAt
            )
        }.sorted(by: Self.archiveVoiceSampleTotalOrder)
    }

    /// 字符串一律按**原始 UTF-8 code units** 比较：Swift `String` 的 ==/< 走
    /// Unicode canonical equivalence（NFC "é" == NFD "e\u{0301}"，< 双向 false），
    /// 但 JSONEncoder 按原始 code units 输出不同字节——String 语义判等的
    /// "不同表示"仍会泄漏 SwiftData 的未定义顺序。
    private static func utf8Less(_ a: String, _ b: String) -> Bool {
        a.utf8.lexicographicallyPrecedes(b.utf8)
    }

    private static func utf8Equal(_ a: String, _ b: String) -> Bool {
        a.utf8.elementsEqual(b.utf8)
    }

    static func archiveVoiceSampleTotalOrder(
        _ a: ArchiveVoiceSampleRecord, _ b: ArchiveVoiceSampleRecord
    ) -> Bool {
        if !utf8Equal(a.rawLabel, b.rawLabel) { return utf8Less(a.rawLabel, b.rawLabel) }
        let aCreated = a.createdAt.timeIntervalSinceReferenceDate.bitPattern
        let bCreated = b.createdAt.timeIntervalSinceReferenceDate.bitPattern
        if aCreated != bCreated { return aCreated < bCreated }
        switch (a.profileID, b.profileID) {
        case (nil, nil): break
        case (nil, .some): return true
        case (.some, nil): return false
        case let (x?, y?):
            if x != y { return utf8Less(x.uuidString, y.uuidString) }
        }
        if !utf8Equal(a.modelVersion, b.modelVersion) { return utf8Less(a.modelVersion, b.modelVersion) }
        if a.embeddingDimension != b.embeddingDimension { return a.embeddingDimension < b.embeddingDimension }
        if a.sampleDuration.bitPattern != b.sampleDuration.bitPattern {
            return a.sampleDuration.bitPattern < b.sampleDuration.bitPattern
        }
        if a.nonOverlapRatio.bitPattern != b.nonOverlapRatio.bitPattern {
            return a.nonOverlapRatio.bitPattern < b.nonOverlapRatio.bitPattern
        }
        if a.qualityScore.bitPattern != b.qualityScore.bitPattern {
            return a.qualityScore.bitPattern < b.qualityScore.bitPattern
        }
        return a.embeddingData.lexicographicallyPrecedes(b.embeddingData)
    }
}
