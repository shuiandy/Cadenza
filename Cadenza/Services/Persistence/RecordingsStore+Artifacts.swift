import Foundation
import SwiftData

enum AcquireResult: Sendable { case acquired(UUID); case rejected }

/// 跨 actor 返回的只读快照(AgentArtifact 非 Sendable,不能直接跨边界)。
struct AgentArtifactDTO: Sendable {
    let id: UUID
    let slotKey: String
    let bodyMarkdown: String
    let provenanceSource: String
    let provenanceDetail: String
    let status: String
    let generationID: UUID?
    let generatingStartedAt: Date?
    let errorClass: String?
    let errorMessage: String?
    let retryAfter: Date?
    let targetFingerprint: String
    let staleReason: String?
    let updatedAt: Date
}

extension RecordingsStore {

    func fetchArtifact(slotKey: String) -> AgentArtifactDTO? {
        fetchModel(slotKey: slotKey).map(Self.toDTO)
    }

    /// external:无条件覆盖当前槽位(命中原地改;空则 insert)。
    func writeExternalArtifact(_ candidate: ArtifactCandidate, now: Date = Date()) -> Bool {
        if let existing = fetchModel(slotKey: candidate.slotKey) {
            applyCandidate(candidate, to: existing, updatedAt: now)
        } else {
            insertArtifact(candidate, now: now)
        }
        return saveArtifacts()
    }

    /// phase 1 — acquire: claim the slot with a builtin `generating` placeholder.
    /// `placeholder` carries real target metadata (dates/fingerprint) known at acquire
    /// time; provenance/status/generationID are forced. Returns .rejected when the slot
    /// cannot be claimed: fresh builtin ready, un-expired failed/generating, or ANY external.
    func acquireBuiltinSlot(slotKey: String, placeholder: ArtifactCandidate,
                            newGenerationID: UUID, now: Date,
                            generatingTTL: TimeInterval) -> AcquireResult {
        let existing = fetchModel(slotKey: slotKey)
        guard canAcquire(existing, now: now, generatingTTL: generatingTTL) else {
            return .rejected
        }
        if let m = existing {
            m.provenanceSource = ArtifactProvenanceSource.builtin.rawValue
            m.provenanceDetail = placeholder.provenanceDetail
            m.status = ArtifactStatus.generating.rawValue
            m.generationID = newGenerationID
            m.generatingStartedAt = now
            m.errorClass = nil
            m.errorMessage = nil
            m.staleReason = nil
            m.targetStartDate = placeholder.targetStartDate
            m.targetEndDate = placeholder.targetEndDate
            m.targetFingerprint = placeholder.targetFingerprint
            m.contextBuiltAt = placeholder.contextBuiltAt
            m.updatedAt = now
        } else {
            var c = placeholder
            c.provenanceSource = .builtin
            c.status = .generating
            c.generationID = newGenerationID
            c.generatingStartedAt = now
            insertArtifact(c, now: now)
        }
        return saveArtifacts() ? .acquired(newGenerationID) : .rejected
    }

    private func canAcquire(_ m: AgentArtifact?, now: Date,
                            generatingTTL: TimeInterval) -> Bool {
        guard let m else { return true } // empty slot
        if m.provenanceSource == ArtifactProvenanceSource.external.rawValue { return false }
        switch m.status {
        case ArtifactStatus.ready.rawValue:
            return m.staleReason != nil // stale builtin ready is rebuildable
        case ArtifactStatus.generating.rawValue:
            guard let started = m.generatingStartedAt else { return true }
            return now.timeIntervalSince(started) > generatingTTL // crash-leftover reclaim
        case ArtifactStatus.failed.rawValue:
            let retryable = m.errorClass == ArtifactErrorClass.retryable.rawValue
            let due = (m.retryAfter.map { now >= $0 }) ?? true
            return retryable && due
        default:
            return true // idle
        }
    }

    /// phase 2 — commit: land ready/failed ONLY if the slot is still this generationID's
    /// builtin placeholder. If external overwrote it (or another gen took over), abandon.
    func commitBuiltin(_ candidate: ArtifactCandidate, generationID: UUID, now: Date = Date()) -> Bool {
        guard let m = fetchModel(slotKey: candidate.slotKey) else { return false }
        guard m.provenanceSource == ArtifactProvenanceSource.builtin.rawValue,
              m.generationID == generationID else { return false }
        applyCandidate(candidate, to: m, updatedAt: now)
        m.generationID = generationID
        return saveArtifacts()
    }

    /// User "regenerate with built-in": replace only on success AND if the external
    /// wasn't rewritten underneath; otherwise keep the original external.
    ///
    /// - Note: The `expectedPriorExternalUpdatedAt` optimistic check is honored ONLY when
    ///   the current slot is `external`; overriding a `builtin` slot always replaces
    ///   unconditionally (per spec §4).
    func overrideWithBuiltin(_ candidate: ArtifactCandidate,
                             expectedPriorExternalUpdatedAt: Date?,
                             now: Date = Date()) -> Bool {
        guard candidate.status == .ready else { return false }
        let existing = fetchModel(slotKey: candidate.slotKey)
        if let m = existing, m.provenanceSource == ArtifactProvenanceSource.external.rawValue {
            // The current slot is external. Only proceed if the caller captured *this exact*
            // external's updatedAt beforehand (expected != nil) and it still matches — i.e.
            // nothing wrote a newer/different external underneath us. If the caller started
            // from an empty/builtin slot (expected == nil) but an external has since landed
            // (e.g. an agent wrote mid-generation), that external is newer than the caller's
            // knowledge and must win — reject rather than overwrite it.
            guard let expected = expectedPriorExternalUpdatedAt, m.updatedAt == expected else {
                return false // external arrived or was rewritten mid-generation — newer external wins
            }
        }
        if let m = existing {
            applyCandidate(candidate, to: m, updatedAt: now)
        } else {
            insertArtifact(candidate, now: now)
        }
        return saveArtifacts()
    }

    // MARK: - internal helpers

    private func fetchModel(slotKey: String) -> AgentArtifact? {
        // 若历史/迁移留下重复行,取最新一行(Task 6 提供 collapse)。
        let descriptor = FetchDescriptor<AgentArtifact>(
            predicate: #Predicate { $0.slotKey == slotKey },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        return (try? modelContext.fetch(descriptor))?.first
    }

    private func insertArtifact(_ candidate: ArtifactCandidate, now: Date) {
        let model = AgentArtifact(
            kind: candidate.kind.rawValue, targetType: candidate.targetType.rawValue,
            targetKey: candidate.targetKey, slotKey: candidate.slotKey,
            bodyMarkdown: candidate.bodyMarkdown,
            provenanceSource: candidate.provenanceSource.rawValue,
            provenanceDetail: candidate.provenanceDetail,
            status: candidate.status.rawValue, generationID: candidate.generationID,
            generatingStartedAt: candidate.generatingStartedAt,
            errorClass: candidate.errorClass?.rawValue, errorMessage: candidate.errorMessage,
            retryAfter: candidate.retryAfter,
            targetStartDate: candidate.targetStartDate, targetEndDate: candidate.targetEndDate,
            targetFingerprint: candidate.targetFingerprint,
            contextBuiltAt: candidate.contextBuiltAt, staleReason: candidate.staleReason,
            createdAt: now, updatedAt: now)
        modelContext.insert(model)
    }

    private func applyCandidate(_ c: ArtifactCandidate, to m: AgentArtifact, updatedAt: Date) {
        m.bodyMarkdown = c.bodyMarkdown
        m.provenanceSource = c.provenanceSource.rawValue
        m.provenanceDetail = c.provenanceDetail
        m.status = c.status.rawValue
        m.generationID = c.generationID
        m.generatingStartedAt = c.generatingStartedAt
        m.errorClass = c.errorClass?.rawValue
        m.errorMessage = c.errorMessage
        m.retryAfter = c.retryAfter
        m.targetStartDate = c.targetStartDate
        m.targetEndDate = c.targetEndDate
        m.targetFingerprint = c.targetFingerprint
        m.contextBuiltAt = c.contextBuiltAt
        m.staleReason = c.staleReason
        m.updatedAt = updatedAt
    }

    private func saveArtifacts() -> Bool {
        do { try modelContext.save(); return true }
        catch { NSLog("[RecordingsStore] artifact save failed: %@", error.localizedDescription); return false }
    }

    static func toDTO(_ m: AgentArtifact) -> AgentArtifactDTO {
        AgentArtifactDTO(
            id: m.id, slotKey: m.slotKey, bodyMarkdown: m.bodyMarkdown,
            provenanceSource: m.provenanceSource, provenanceDetail: m.provenanceDetail,
            status: m.status, generationID: m.generationID,
            generatingStartedAt: m.generatingStartedAt, errorClass: m.errorClass,
            errorMessage: m.errorMessage, retryAfter: m.retryAfter, targetFingerprint: m.targetFingerprint,
            staleReason: m.staleReason, updatedAt: m.updatedAt)
    }

    /// 若存档 fingerprint 与当前不同,标 staleReason="eventChanged"。返回是否标记。
    func markStaleIfChanged(slotKey: String, currentFingerprint: String) -> Bool {
        guard let m = fetchModel(slotKey: slotKey) else { return false }
        guard m.targetFingerprint != currentFingerprint else { return false }
        if m.staleReason == "eventChanged" { return false } // 已标,幂等
        m.staleReason = "eventChanged"
        m.updatedAt = Date()
        return saveArtifacts()
    }

    // 仅测试用:同 slotKey 行数。
    func artifactCountForTests(slotKey: String) -> Int {
        let descriptor = FetchDescriptor<AgentArtifact>(
            predicate: #Predicate { $0.slotKey == slotKey })
        return (try? modelContext.fetch(descriptor))?.count ?? 0
    }

    /// Safety net: if multiple rows ever share a slotKey (migration/legacy),
    /// keep the newest (max updatedAt), delete the rest. Returns count removed.
    func collapseDuplicateSlots(slotKey: String) -> Int {
        let descriptor = FetchDescriptor<AgentArtifact>(
            predicate: #Predicate { $0.slotKey == slotKey },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        let rows = (try? modelContext.fetch(descriptor)) ?? []
        guard rows.count > 1 else { return 0 }
        for extra in rows.dropFirst() { modelContext.delete(extra) }
        guard saveArtifacts() else { return 0 }
        return rows.count - 1
    }

    /// Test-only: attempt to create `times` rows for the same candidate.
    /// Used to probe SwiftData @Attribute(.unique) collapse behavior.
    func insertRawDuplicatesForTests(candidate: ArtifactCandidate, times: Int) {
        for _ in 0..<times { insertArtifact(candidate, now: Date()) }
        _ = saveArtifacts()
    }
}
