import Foundation
import SwiftData
import Testing
@testable import Cadenza

/// CI-only restorer + full-store snapshot (spec P0 验收 / codex review #3)。
///
/// `PortableArchiveRestorer.rebuild` 把已验证归档真正重建成一个 in-memory
/// SwiftData store；`StoreSnapshot.capture` 用**独立于归档 schema 的字段清单**
/// 抓取两个 store 的完整用户数据面并比较——归档 schema 少存任何一个用户字段，
/// 重建侧就会与源侧不等，round-trip 变红。这是 schema 完整性的真正门禁
/// （只比 counts / hash 发现不了字段丢失）。
///
/// 刻意排除的字段（见 PortableArchiveSchema 顶部注释）：lastAccessedDate、
/// processingAttempts、postProcessingBackfill*、calendarAutoLinkAttemptedAt
/// （calendarAutoLinkState 本身随档——.userCleared 是用户意图）、
/// speakerSuggestions、audioFilePath/audioSegmentsDirectory（以文件形态入档，
/// 路径是机器相关的）、Transcript.id / MeetingSummary.id（1:1 子对象的合成
/// 身份，内容才是数据；条目级 id —— TranscriptEntry/ActionItem —— 照常比较）。
/// 时间精度承诺为毫秒级：快照按毫秒比较（归档实际是 Double 最短表示往返）。

@MainActor
enum PortableArchiveRestorer {

    static func rebuild(_ archive: ValidatedArchive) throws -> ModelContainer {
        let container = try RecordingsStore.makeContainer(inMemory: true)
        let context = container.mainContext

        // Folders：两遍建树
        var folderByID: [UUID: Folder] = [:]
        for f in archive.folders {
            let folder = Folder(
                name: f.name, icon: f.icon, iconColor: f.iconColor,
                colorHex: f.colorHex, status: f.status, sortOrder: f.sortOrder
            )
            folder.id = f.id
            folder.createdAt = f.createdAt
            context.insert(folder)
            folderByID[f.id] = folder
        }
        for f in archive.folders {
            if let parentID = f.parentFolderID {
                folderByID[f.id]?.parentFolder = folderByID[parentID]
            }
        }

        // Speaker profiles（留 dict 供 voice sample 关联）
        var profileByID: [UUID: SpeakerProfile] = [:]
        for p in archive.speakerProfiles {
            let profile = SpeakerProfile(displayName: p.displayName, notes: p.notes, teamOrOrg: p.teamOrOrg)
            profile.id = p.id
            profile.aliases = p.aliases
            profile.createdAt = p.createdAt
            profile.lastSeenAt = p.lastSeenAt
            context.insert(profile)
            profileByID[p.id] = profile
        }

        // Recordings + transcript/summary
        let transcriptByID = Dictionary(uniqueKeysWithValues: archive.transcripts.map { ($0.recordingID, $0) })
        let summaryByID = Dictionary(uniqueKeysWithValues: archive.summaries.map { ($0.recordingID, $0) })
        for r in archive.recordings {
            let recording = Recording(
                id: r.id, title: r.title, startDate: r.startDate, language: r.language,
                source: r.source.flatMap(RecordingSource.init(rawValue:)) ?? .captured
            )
            recording.endDate = r.endDate
            recording.duration = r.duration
            recording.meetingApp = r.meetingApp
            recording.meetingURL = r.meetingURL
            recording.meetingType = r.meetingType
            recording.linkedCalendarEventID = r.linkedCalendarEventID
            recording.calendarAutoLinkState = r.calendarAutoLinkState
            recording.tags = r.tags
            recording.trashedDate = r.trashedDate
            recording.createdAt = r.createdAt
            recording.updatedAt = r.updatedAt
            recording.source = r.source
            recording.speakerMappings = r.speakerMappings.isEmpty ? nil : r.speakerMappings.map {
                SpeakerLabelMapping(rawLabel: $0.rawLabel, profileID: $0.profileID)
            }
            recording.folder = r.folderID.flatMap { folderByID[$0] }
            recording.audioFileOwnership = r.audioOwnership
            context.insert(recording)

            if let t = transcriptByID[r.id] {
                let transcript = Transcript(
                    fullText: t.fullText,
                    segments: t.segments.map { seg in
                        var entry = TranscriptEntry(
                            startTime: seg.startTime, endTime: seg.endTime,
                            text: seg.text, speaker: seg.speaker
                        )
                        entry.id = seg.id
                        return entry
                    }
                )
                transcript.detectedLanguage = t.detectedLanguage
                transcript.createdAt = t.createdAt
                recording.transcript = transcript
            }
            if let s = summaryByID[r.id] {
                let summary = MeetingSummary(
                    overview: s.overview,
                    keyPoints: s.keyPoints,
                    actionItems: s.actionItems.map { item in
                        var actionItem = ActionItem(
                            assignee: item.assignee, task: item.task, deadline: item.deadline,
                            isCompleted: item.isCompleted,
                            priority: ActionPriority(rawValue: item.priority) ?? .medium,
                            createdAt: item.createdAt, updatedAt: item.updatedAt
                        )
                        actionItem.id = item.id
                        return actionItem
                    },
                    decisions: s.decisions,
                    followUps: s.followUps,
                    yourTasks: s.yourTasks,
                    model: s.model,
                    language: s.language
                )
                summary.provider = s.provider
                summary.createdAt = s.createdAt
                if !s.chapters.isEmpty {
                    let chapterDTOs = s.chapters.map {
                        ChapterDTO(title: $0.title, startSeconds: $0.startSeconds, summary: $0.summary)
                    }
                    summary.chaptersJSON = String(
                        decoding: (try? JSONEncoder().encode(chapterDTOs)) ?? Data(), as: UTF8.self
                    )
                }
                recording.summary = summary
            }
        }

        // Recaps
        let decoder = JSONDecoder()
        for r in archive.recaps {
            let recap = Recap(
                id: r.id, period: r.period, startDate: r.startDate, endDate: r.endDate,
                title: r.title, overview: r.overview,
                sections: (try? decoder.decode([RecapSection].self, from: Data(r.sectionsJSON.utf8))) ?? [],
                stats: (try? decoder.decode(RecapStats.self, from: Data(r.statsJSON.utf8))) ?? RecapStats(),
                recordingIDs: r.recordingIDs,
                allActionItems: r.allActionItems,
                allDecisions: r.allDecisions,
                provider: r.provider
            )
            recap.createdAt = r.createdAt
            context.insert(recap)
        }

        // Voice samples（embeddings 选装面——归档含则必须可重建）
        for s in archive.voiceSamples {
            let sample = SpeakerVoiceSample(
                recordingID: s.recordingID, rawLabel: s.rawLabel,
                profile: s.profileID.flatMap { profileByID[$0] },
                embeddingData: s.embeddingData, embeddingDimension: s.embeddingDimension,
                sampleDuration: s.sampleDuration, nonOverlapRatio: s.nonOverlapRatio,
                qualityScore: s.qualityScore, modelVersion: s.modelVersion
            )
            sample.createdAt = s.createdAt
            context.insert(sample)
        }

        // Agent artifacts（全字段）
        for a in archive.artifacts {
            context.insert(AgentArtifact(
                id: a.id, kind: a.kind, targetType: a.targetType, targetKey: a.targetKey,
                slotKey: a.slotKey, bodyMarkdown: a.bodyMarkdown,
                provenanceSource: a.provenanceSource, provenanceDetail: a.provenanceDetail,
                status: a.status, generationID: a.generationID,
                generatingStartedAt: a.generatingStartedAt, errorClass: a.errorClass,
                errorMessage: a.errorMessage, lastAttemptedAt: a.lastAttemptedAt,
                retryAfter: a.retryAfter, targetStartDate: a.targetStartDate,
                targetEndDate: a.targetEndDate, targetFingerprint: a.targetFingerprint,
                contextBuiltAt: a.contextBuiltAt, staleReason: a.staleReason,
                createdAt: a.createdAt, updatedAt: a.updatedAt
            ))
        }

        try context.save()
        return container
    }
}

// MARK: - Full-store snapshot

/// 归档日期是 epoch 秒 Double（JSON 最短表示往返，见 PortableArchiveSchema）；
/// 对外承诺的精度是**毫秒级**，因此快照统一量化到毫秒比较。
private func ms(_ date: Date?) -> Int64? {
    date.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) }
}

struct StoreSnapshot: Equatable {
    struct RecordingMirror: Equatable {
        var id: UUID
        var title: String
        var startDate: Int64?
        var endDate: Int64?
        var duration: TimeInterval
        var meetingApp: String?
        var meetingURL: String?
        var meetingType: String?
        var linkedCalendarEventID: String?
        var calendarAutoLinkState: String?
        var language: String
        var tags: [String]
        var folderID: UUID?
        var trashedDate: Int64?
        var source: String?
        var createdAt: Int64?
        var updatedAt: Int64?
        var speakerMappings: [String]
        var audioOwnership: String?
        var transcript: TranscriptMirror?
        var summary: SummaryMirror?
    }
    struct TranscriptMirror: Equatable {
        var fullText: String
        var detectedLanguage: String?
        var createdAt: Int64?
        var segments: [String] // "id|start|end|speaker|text"
    }
    struct SummaryMirror: Equatable {
        var overview: String
        var keyPoints: [String]
        var decisions: [String]
        var followUps: [String]
        var yourTasks: [String]
        var provider: String
        var model: String
        var language: String
        var createdAt: Int64?
        var chapters: [String]    // "title|start|summary"
        var actionItems: [String] // "id|task|assignee|deadline|done|priority|createdAtMs|updatedAtMs"
    }
    struct FolderMirror: Equatable {
        var id: UUID
        var name: String
        var parentFolderID: UUID?
        var icon: String
        var iconColor: String
        var colorHex: String?
        var status: String
        var createdAt: Int64?
        var sortOrder: Int
    }
    struct ProfileMirror: Equatable {
        var id: UUID
        var displayName: String
        var aliases: [String]
        var notes: String
        var teamOrOrg: String?
        var createdAt: Int64?
        var lastSeenAt: Int64?
    }
    struct RecapMirror: Equatable {
        var id: UUID
        var period: String
        var startDate: Int64?
        var endDate: Int64?
        var title: String
        var overview: String
        var recordingIDs: [UUID]
        var allActionItems: [String]
        var allDecisions: [String]
        var provider: String
        var createdAt: Int64?
        // sections/stats 按解码后的语义比较——JSONEncoder 不带 .sortedKeys 时
        // key 顺序不稳定（实测同进程两次编码顺序都会漂），字节比较必然误报。
        var sections: [String]  // "id|category|summary|recordingIDs"
        var stats: String       // "meetings|duration|actionItems|decisions"
    }
    struct ArtifactMirror: Equatable {
        var id: UUID
        var kind: String
        var targetType: String
        var targetKey: String
        var slotKey: String
        var bodyMarkdown: String
        var provenanceSource: String
        var provenanceDetail: String
        var status: String
        var generationID: UUID?
        var generatingStartedAt: Int64?
        var errorClass: String?
        var errorMessage: String?
        var lastAttemptedAt: Int64?
        var retryAfter: Int64?
        var targetStartDate: Int64?
        var targetEndDate: Int64?
        var targetFingerprint: String
        var contextBuiltAt: Int64?
        var staleReason: String?
        var createdAt: Int64?
        var updatedAt: Int64?
    }

    struct SampleMirror: Equatable {
        var recordingID: UUID
        var rawLabel: String
        var profileID: UUID?
        var embeddingData: Data
        var embeddingDimension: Int
        var sampleDuration: TimeInterval
        var nonOverlapRatio: Float
        var qualityScore: Float
        var modelVersion: String
        var createdAt: Int64?
    }

    var recordings: [RecordingMirror]
    var folders: [FolderMirror]
    var profiles: [ProfileMirror]
    var recaps: [RecapMirror]
    var artifacts: [ArtifactMirror]
    var voiceSamples: [SampleMirror]

    @MainActor
    static func capture(_ container: ModelContainer) throws -> StoreSnapshot {
        let context = container.mainContext

        let recordings = try context.fetch(
            FetchDescriptor<Recording>(sortBy: [SortDescriptor(\.startDate, order: .forward)])
        ).map { r in
            RecordingMirror(
                id: r.id, title: r.title, startDate: ms(r.startDate), endDate: ms(r.endDate),
                duration: r.duration, meetingApp: r.meetingApp, meetingURL: r.meetingURL,
                meetingType: r.meetingType, linkedCalendarEventID: r.linkedCalendarEventID,
                calendarAutoLinkState: r.calendarAutoLinkState,
                language: r.language, tags: r.tags, folderID: r.folder?.id,
                trashedDate: ms(r.trashedDate), source: r.source,
                createdAt: ms(r.createdAt), updatedAt: ms(r.updatedAt),
                speakerMappings: (r.speakerMappings ?? [])
                    .map { "\($0.rawLabel)|\($0.profileID.uuidString)" }.sorted(),
                audioOwnership: r.audioFileOwnership,
                transcript: r.transcript.map { t in
                    TranscriptMirror(
                        fullText: t.fullText, detectedLanguage: t.detectedLanguage,
                        createdAt: ms(t.createdAt),
                        segments: t.segments.map {
                            "\($0.id.uuidString)|\($0.startTime)|\($0.endTime)|\($0.speaker ?? "-")|\($0.text)"
                        }
                    )
                },
                summary: r.summary.map { s in
                    let chapters: [ChapterDTO] = s.chaptersJSON
                        .flatMap { try? JSONDecoder().decode([ChapterDTO].self, from: Data($0.utf8)) } ?? []
                    return SummaryMirror(
                        overview: s.overview, keyPoints: s.keyPoints, decisions: s.decisions,
                        followUps: s.followUps, yourTasks: s.yourTasks,
                        provider: s.provider, model: s.model, language: s.language,
                        createdAt: ms(s.createdAt),
                        chapters: chapters.map { "\($0.title)|\($0.startSeconds)|\($0.summary)" },
                        actionItems: s.actionItems.map {
                            "\($0.id.uuidString)|\($0.task)|\($0.assignee ?? "-")|\($0.deadline ?? "-")|\($0.isCompleted)|\($0.priority.rawValue)|\(ms($0.createdAt) ?? -1)|\(ms($0.updatedAt) ?? -1)"
                        }
                    )
                }
            )
        }.sorted { $0.id.uuidString < $1.id.uuidString }

        let folders = try context.fetch(FetchDescriptor<Folder>()).map {
            FolderMirror(
                id: $0.id, name: $0.name, parentFolderID: $0.parentFolder?.id,
                icon: $0.icon, iconColor: $0.iconColor, colorHex: $0.colorHex,
                status: $0.status, createdAt: ms($0.createdAt), sortOrder: $0.sortOrder
            )
        }.sorted { $0.id.uuidString < $1.id.uuidString }

        let profiles = try context.fetch(FetchDescriptor<SpeakerProfile>()).map {
            ProfileMirror(
                id: $0.id, displayName: $0.displayName, aliases: $0.aliases, notes: $0.notes,
                teamOrOrg: $0.teamOrOrg, createdAt: ms($0.createdAt), lastSeenAt: ms($0.lastSeenAt)
            )
        }.sorted { $0.id.uuidString < $1.id.uuidString }

        let recaps = try context.fetch(FetchDescriptor<Recap>()).map { recap in
            let sections = recap.sections.map {
                "\($0.id.uuidString)|\($0.category)|\($0.summary)|\($0.recordingIDs.map(\.uuidString).joined(separator: ","))"
            }
            let stats = recap.stats
            return RecapMirror(
                id: recap.id, period: recap.period,
                startDate: ms(recap.startDate), endDate: ms(recap.endDate),
                title: recap.title, overview: recap.overview, recordingIDs: recap.recordingIDs,
                allActionItems: recap.allActionItems, allDecisions: recap.allDecisions,
                provider: recap.provider, createdAt: ms(recap.createdAt),
                sections: sections,
                stats: "\(stats.meetingCount)|\(stats.totalDuration)|\(stats.actionItemCount)|\(stats.decisionCount)"
            )
        }.sorted { $0.id.uuidString < $1.id.uuidString }

        let artifacts = try context.fetch(FetchDescriptor<AgentArtifact>()).map {
            ArtifactMirror(
                id: $0.id, kind: $0.kind, targetType: $0.targetType, targetKey: $0.targetKey,
                slotKey: $0.slotKey, bodyMarkdown: $0.bodyMarkdown,
                provenanceSource: $0.provenanceSource, provenanceDetail: $0.provenanceDetail,
                status: $0.status, generationID: $0.generationID,
                generatingStartedAt: ms($0.generatingStartedAt), errorClass: $0.errorClass,
                errorMessage: $0.errorMessage, lastAttemptedAt: ms($0.lastAttemptedAt),
                retryAfter: ms($0.retryAfter), targetStartDate: ms($0.targetStartDate),
                targetEndDate: ms($0.targetEndDate), targetFingerprint: $0.targetFingerprint,
                contextBuiltAt: ms($0.contextBuiltAt), staleReason: $0.staleReason,
                createdAt: ms($0.createdAt), updatedAt: ms($0.updatedAt)
            )
        }.sorted { $0.slotKey < $1.slotKey }

        let voiceSamples = try context.fetch(FetchDescriptor<SpeakerVoiceSample>()).map {
            SampleMirror(
                recordingID: $0.recordingID, rawLabel: $0.rawLabel, profileID: $0.profile?.id,
                embeddingData: $0.embeddingData, embeddingDimension: $0.embeddingDimension,
                sampleDuration: $0.sampleDuration, nonOverlapRatio: $0.nonOverlapRatio,
                qualityScore: $0.qualityScore, modelVersion: $0.modelVersion,
                createdAt: ms($0.createdAt)
            )
        }.sorted {
            ($0.recordingID.uuidString, $0.rawLabel) < ($1.recordingID.uuidString, $1.rawLabel)
        }

        return StoreSnapshot(
            recordings: recordings, folders: folders, profiles: profiles,
            recaps: recaps, artifacts: artifacts, voiceSamples: voiceSamples
        )
    }
}
