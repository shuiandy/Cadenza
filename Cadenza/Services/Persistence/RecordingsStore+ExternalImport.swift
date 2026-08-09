import Foundation
import SwiftData

extension RecordingsStore {
    /// Machine-only marker for the minimal ledger tombstone retained after a
    /// user permanently deletes an imported recording. A one-way identity
    /// digest prevents background import replay; all raw source identity,
    /// content, and fingerprints are scrubbed by the deletion transaction.
    static let userDeletedExternalImportReason = "cadenza:user-deleted"

    /// Irreversible, deterministic replay key. The provider remains as a
    /// low-cardinality integration identifier; the raw external ID is erased.
    /// A NUL separator prevents concatenation ambiguity.
    static func userDeletedExternalImportKey(
        provider: String,
        externalID: String
    ) -> String {
        let canonicalProvider = provider
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let canonicalExternalID = externalID
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var data = Data(canonicalProvider.utf8)
        data.append(0)
        data.append(contentsOf: canonicalExternalID.utf8)
        return "deleted:" + ExternalRecordingFingerprint.data(data)
    }

    func previewExternalRecording(_ input: ExternalRecordingPreviewInput) -> ExternalRecordingPreviewResult {
        let identity: ExternalRecordingIdentity
        do {
            identity = try ExternalRecordingIdentity.make(provider: input.provider, externalID: input.externalID)
        } catch {
            return ExternalRecordingPreviewResult(
                provider: input.provider,
                externalID: input.externalID,
                externalKey: "",
                status: .conflict,
                recordingID: nil,
                matchedRecordingID: nil,
                reason: error.localizedDescription,
                qualitySignals: ExternalImportQualityEvaluator.signals(for: input)
            )
        }

        let qualitySignals = ExternalImportQualityEvaluator.signals(for: input)
        if let ledger = externalImport(for: identity) {
            let disposition = ExternalImportDisposition(rawValue: ledger.disposition) ?? .conflict
            if disposition == .ignored {
                return previewResult(identity, status: .ignored, ledger: ledger,
                                     reason: ledger.reason, qualitySignals: qualitySignals)
            }

            if input.sourceUpdatedAt < ledger.sourceUpdatedAt {
                return previewResult(
                    identity,
                    status: .conflict,
                    ledger: ledger,
                    reason: "The supplied source version is older than the latest version already seen.",
                    qualitySignals: qualitySignals
                )
            }
            guard let recording = ledger.recording else {
                let status: ExternalImportPreviewStatus = disposition == .pending ? .new : .conflict
                let reason = status == .new ? nil : "The imported recording no longer exists locally."
                return previewResult(identity, status: status, ledger: ledger,
                                     reason: reason, qualitySignals: qualitySignals)
            }

            let suppliedTranscriptFingerprint = ExternalRecordingFingerprint.normalizedSHA256(
                input.transcriptFingerprint
            )
            let sourceChanged = input.sourceUpdatedAt > ledger.sourceUpdatedAt
                || (suppliedTranscriptFingerprint != nil
                    && suppliedTranscriptFingerprint != ledger.transcriptFingerprint)
            guard sourceChanged else {
                let status: ExternalImportPreviewStatus = disposition == .conflict ? .conflict : .unchanged
                return previewResult(identity, status: status, ledger: ledger,
                                     reason: ledger.reason, qualitySignals: qualitySignals)
            }

            if let lastApplied = ledger.lastAppliedLocalFingerprint,
               ExternalRecordingFingerprint.local(recording) != lastApplied {
                return previewResult(
                    identity,
                    status: .conflict,
                    ledger: ledger,
                    reason: "The Cadenza recording changed after the last source import.",
                    qualitySignals: qualitySignals
                )
            }
            return previewResult(identity, status: .updated, ledger: ledger,
                                 reason: nil, qualitySignals: qualitySignals)
        }

        if let duplicate = possibleDuplicate(for: input) {
            return ExternalRecordingPreviewResult(
                provider: identity.provider,
                externalID: identity.externalID,
                externalKey: identity.externalKey,
                status: .possibleDuplicate,
                recordingID: nil,
                matchedRecordingID: duplicate.recording.id,
                reason: duplicate.reason,
                qualitySignals: qualitySignals
            )
        }

        return ExternalRecordingPreviewResult(
            provider: identity.provider,
            externalID: identity.externalID,
            externalKey: identity.externalKey,
            status: .new,
            recordingID: nil,
            matchedRecordingID: nil,
            reason: nil,
            qualitySignals: qualitySignals
        )
    }

    func upsertExternalRecording(
        _ input: ExternalRecordingUpsertInput,
        now: Date = Date()
    ) -> ExternalRecordingUpsertResult {
        let identity: ExternalRecordingIdentity
        do {
            identity = try ExternalRecordingIdentity.make(provider: input.provider, externalID: input.externalID)
        } catch {
            return failedExternalUpsert(error.localizedDescription)
        }
        let title = input.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            return failedExternalUpsert(ExternalImportError.invalidTitle.localizedDescription, key: identity.externalKey)
        }

        let previewInput = externalPreviewInput(from: input)
        let qualitySignals = ExternalImportQualityEvaluator.signals(for: previewInput)
        let sourceFingerprint = ExternalRecordingFingerprint.source(input)
        let transcriptFingerprint = input.transcript.map {
            ExternalRecordingFingerprint.transcript($0.fullText)
        }
        var ledger = externalImport(for: identity)

        if let ledger,
           ExternalImportDisposition(rawValue: ledger.disposition) == .ignored {
            if ledger.reason == Self.userDeletedExternalImportReason {
                // A background replay must not refill a user-deletion
                // tombstone with title, calendar, timing, transcript, or
                // fingerprint data. Explicit reconsideration changes the
                // disposition to pending before a later upsert may restore it.
                ledger.lastSeenAt = now
                guard save() else {
                    modelContext.rollback()
                    return failedExternalUpsert(
                        "Could not update the external import ledger.",
                        key: identity.externalKey
                    )
                }
                return ExternalRecordingUpsertResult(
                    status: .ignored,
                    externalKey: identity.externalKey,
                    recordingID: nil,
                    reason: ledger.reason,
                    qualitySignals: qualitySignals
                )
            }
            let canAdvanceAuditState = input.sourceUpdatedAt > ledger.sourceUpdatedAt
                || (input.sourceUpdatedAt == ledger.sourceUpdatedAt
                    && (ledger.contentFingerprint == nil || ledger.contentFingerprint == sourceFingerprint))
            if canAdvanceAuditState {
                updateSeenMetadata(ledger, input: input, sourceFingerprint: sourceFingerprint,
                                   transcriptFingerprint: transcriptFingerprint,
                                   qualitySignals: qualitySignals, now: now)
            } else {
                ledger.lastSeenAt = now
            }
            guard save() else {
                modelContext.rollback()
                return failedExternalUpsert("Could not update the external import ledger.", key: identity.externalKey)
            }
            return ExternalRecordingUpsertResult(
                status: .ignored,
                externalKey: identity.externalKey,
                recordingID: ledger.recording?.id,
                reason: ledger.reason,
                qualitySignals: qualitySignals
            )
        }

        if ledger == nil, let duplicate = possibleDuplicate(for: previewInput) {
            return ExternalRecordingUpsertResult(
                status: .possibleDuplicate,
                externalKey: identity.externalKey,
                recordingID: nil,
                matchedRecordingID: duplicate.recording.id,
                reason: duplicate.reason,
                qualitySignals: qualitySignals
            )
        }

        if let ledger, input.sourceUpdatedAt < ledger.sourceUpdatedAt {
            return ExternalRecordingUpsertResult(
                status: .stale,
                externalKey: identity.externalKey,
                recordingID: ledger.recording?.id,
                reason: "The supplied source version is older than the latest version already seen.",
                qualitySignals: qualitySignals
            )
        }

        if let ledger,
           input.sourceUpdatedAt == ledger.sourceUpdatedAt,
           sourceFingerprint == ledger.lastAppliedSourceFingerprint,
           ledger.recording != nil {
            ledger.lastSeenAt = now
            ledger.qualitySignals = qualitySignals.map(\.rawValue)
            if ExternalImportDisposition(rawValue: ledger.disposition) == .pending {
                ledger.disposition = ExternalImportDisposition.imported.rawValue
            }
            guard save() else {
                modelContext.rollback()
                return failedExternalUpsert("Could not update last-seen state.", key: identity.externalKey)
            }
            return ExternalRecordingUpsertResult(
                status: .unchanged,
                externalKey: identity.externalKey,
                recordingID: ledger.recording?.id,
                reason: nil,
                qualitySignals: qualitySignals
            )
        }

        if let ledger,
           input.sourceUpdatedAt == ledger.sourceUpdatedAt,
           ledger.contentFingerprint != nil,
           sourceFingerprint != ledger.contentFingerprint {
            markConflict(
                ledger,
                input: input,
                sourceFingerprint: sourceFingerprint,
                transcriptFingerprint: transcriptFingerprint,
                qualitySignals: qualitySignals,
                reason: "The source content changed without advancing sourceUpdatedAt.",
                now: now
            )
            guard save() else {
                modelContext.rollback()
                return failedExternalUpsert("Could not save conflict state.", key: identity.externalKey)
            }
            return conflictExternalUpsert(identity.externalKey, recordingID: ledger.recording?.id,
                                          reason: ledger.reason, qualitySignals: qualitySignals)
        }

        if let ledger,
           ExternalImportDisposition(rawValue: ledger.disposition) == .conflict,
           sourceFingerprint == ledger.contentFingerprint,
           sourceFingerprint != ledger.lastAppliedSourceFingerprint {
            ledger.lastSeenAt = now
            guard save() else {
                modelContext.rollback()
                return failedExternalUpsert("Could not update conflict state.", key: identity.externalKey)
            }
            return conflictExternalUpsert(identity.externalKey, recordingID: ledger.recording?.id,
                                          reason: ledger.reason, qualitySignals: qualitySignals)
        }

        if let ledger, let recording = ledger.recording {
            if let lastApplied = ledger.lastAppliedLocalFingerprint,
               ExternalRecordingFingerprint.local(recording) != lastApplied {
                markConflict(
                    ledger,
                    input: input,
                    sourceFingerprint: sourceFingerprint,
                    transcriptFingerprint: transcriptFingerprint,
                    qualitySignals: qualitySignals,
                    reason: "The Cadenza recording changed after the last source import.",
                    now: now
                )
                guard save() else {
                    modelContext.rollback()
                    return failedExternalUpsert("Could not save conflict state.", key: identity.externalKey)
                }
                return conflictExternalUpsert(identity.externalKey, recordingID: recording.id,
                                              reason: ledger.reason, qualitySignals: qualitySignals)
            }
        } else if let ledger,
                  ExternalImportDisposition(rawValue: ledger.disposition) != .pending {
            markConflict(
                ledger,
                input: input,
                sourceFingerprint: sourceFingerprint,
                transcriptFingerprint: transcriptFingerprint,
                qualitySignals: qualitySignals,
                reason: "The previously imported recording no longer exists locally.",
                now: now
            )
            guard save() else {
                modelContext.rollback()
                return failedExternalUpsert("Could not save conflict state.", key: identity.externalKey)
            }
            return conflictExternalUpsert(identity.externalKey, recordingID: nil,
                                          reason: ledger.reason, qualitySignals: qualitySignals)
        }

        let isNewRecording = ledger?.recording == nil
        let recording: Recording
        if let existing = ledger?.recording {
            recording = existing
        } else {
            recording = Recording(
                title: title,
                startDate: input.startDate,
                language: input.language,
                source: .external
            )
            modelContext.insert(recording)
        }
        applyExternalContent(input, title: title, to: recording, now: now)

        if ledger == nil {
            let created = ExternalRecordingImport(
                externalKey: identity.externalKey,
                provider: identity.provider,
                externalID: identity.externalID,
                sourceTitle: title,
                sourceStartDate: input.startDate,
                sourceDuration: max(0, input.duration),
                sourceCalendarEventID: input.calendarEventID,
                sourceCreatedAt: input.sourceCreatedAt,
                sourceUpdatedAt: input.sourceUpdatedAt,
                lastSeenAt: now,
                disposition: .imported,
                qualitySignals: qualitySignals
            )
            modelContext.insert(created)
            ledger = created
        }
        guard let ledger else {
            modelContext.rollback()
            return failedExternalUpsert("Could not create the external import ledger.", key: identity.externalKey)
        }
        ledger.recording = recording
        updateSeenMetadata(ledger, input: input, sourceFingerprint: sourceFingerprint,
                           transcriptFingerprint: transcriptFingerprint,
                           qualitySignals: qualitySignals, now: now)
        ledger.lastAppliedAt = now
        ledger.lastAppliedSourceFingerprint = sourceFingerprint
        ledger.lastAppliedLocalFingerprint = ExternalRecordingFingerprint.local(recording)
        ledger.disposition = ExternalImportDisposition.imported.rawValue
        ledger.reason = nil
        invalidateDetailCache(recording.id)

        guard save() else {
            modelContext.rollback()
            invalidateDetailCache(recording.id)
            return failedExternalUpsert("Could not atomically save the external recording.", key: identity.externalKey)
        }
        return ExternalRecordingUpsertResult(
            status: isNewRecording ? .imported : .updated,
            externalKey: identity.externalKey,
            recordingID: recording.id,
            reason: nil,
            qualitySignals: qualitySignals
        )
    }

    func setExternalImportDisposition(
        previewInput input: ExternalRecordingPreviewInput,
        disposition: ExternalImportDisposition,
        reason: String?,
        now: Date = Date()
    ) -> ExternalImportDispositionResult {
        guard disposition == .ignored || disposition == .pending else {
            return ExternalImportDispositionResult(
                status: .conflict,
                externalKey: nil,
                recordingID: nil,
                reason: "Only ignored or pending can be set explicitly."
            )
        }
        let identity: ExternalRecordingIdentity
        do {
            identity = try ExternalRecordingIdentity.make(provider: input.provider, externalID: input.externalID)
        } catch {
            return ExternalImportDispositionResult(
                status: .conflict,
                externalKey: nil,
                recordingID: nil,
                reason: error.localizedDescription
            )
        }
        let qualitySignals = ExternalImportQualityEvaluator.signals(for: input)
        var ledger = externalImport(for: identity)
        if ledger == nil {
            let created = ExternalRecordingImport(
                externalKey: identity.externalKey,
                provider: identity.provider,
                externalID: identity.externalID,
                sourceTitle: input.title,
                sourceStartDate: input.startDate,
                sourceDuration: max(0, input.duration),
                sourceCalendarEventID: input.calendarEventID,
                sourceCreatedAt: input.sourceCreatedAt,
                sourceUpdatedAt: input.sourceUpdatedAt,
                lastSeenAt: now,
                disposition: disposition,
                reason: reason,
                qualitySignals: qualitySignals
            )
            modelContext.insert(created)
            ledger = created
        }
        guard let ledger else {
            return ExternalImportDispositionResult(status: .conflict, externalKey: identity.externalKey,
                                                   recordingID: nil, reason: "Could not create import state.")
        }
        if ledger.reason == Self.userDeletedExternalImportReason,
           disposition == .pending {
            // Reconsideration is the only path that restores the normal
            // lookup identity. Merely seeing the source again never does.
            ledger.externalKey = identity.externalKey
            ledger.provider = identity.provider
            ledger.externalID = identity.externalID
        }
        if input.sourceUpdatedAt >= ledger.sourceUpdatedAt {
            ledger.sourceTitle = input.title
            ledger.sourceStartDate = input.startDate
            ledger.sourceDuration = max(0, input.duration)
            ledger.sourceCalendarEventID = input.calendarEventID
            ledger.sourceCreatedAt = input.sourceCreatedAt
            ledger.sourceUpdatedAt = input.sourceUpdatedAt
            ledger.transcriptFingerprint = ExternalRecordingFingerprint.normalizedSHA256(
                input.transcriptFingerprint
            )
        }
        ledger.lastSeenAt = now
        ledger.disposition = disposition.rawValue
        ledger.reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        ledger.qualitySignals = qualitySignals.map(\.rawValue)
        guard save() else {
            modelContext.rollback()
            return ExternalImportDispositionResult(
                status: .conflict,
                externalKey: identity.externalKey,
                recordingID: ledger.recording?.id,
                reason: "Could not save import disposition."
            )
        }
        return ExternalImportDispositionResult(
            status: disposition,
            externalKey: identity.externalKey,
            recordingID: ledger.recording?.id,
            reason: ledger.reason
        )
    }

    func fetchExternalRecordingImport(provider: String, externalID: String) -> ExternalRecordingImportDTO? {
        guard let identity = try? ExternalRecordingIdentity.make(provider: provider, externalID: externalID),
              let ledger = externalImport(for: identity) else { return nil }
        return externalImportDTO(ledger)
    }

    func countExternalRecordingImports() -> Int {
        (try? modelContext.fetchCount(FetchDescriptor<ExternalRecordingImport>())) ?? 0
    }

#if DEBUG
    struct ExternalImportDeletionSnapshot: Sendable, Equatable {
        let externalKey: String
        let provider: String
        let externalID: String
        let recordingID: UUID?
        let sourceTitle: String
        let sourceStartDate: Date
        let sourceDuration: TimeInterval
        let sourceCalendarEventID: String?
        let sourceCreatedAt: Date?
        let sourceUpdatedAt: Date
        let lastAppliedAt: Date?
        let contentFingerprint: String?
        let transcriptFingerprint: String?
        let lastAppliedSourceFingerprint: String?
        let lastAppliedLocalFingerprint: String?
        let disposition: String
        let reason: String?
        let qualitySignals: [String]
    }

    func externalImportDeletionSnapshotForTesting(
        provider: String,
        externalID: String
    ) -> ExternalImportDeletionSnapshot? {
        guard let identity = try? ExternalRecordingIdentity.make(
            provider: provider,
            externalID: externalID
        ), let ledger = externalImport(for: identity) else {
            return nil
        }
        return ExternalImportDeletionSnapshot(
            externalKey: ledger.externalKey,
            provider: ledger.provider,
            externalID: ledger.externalID,
            recordingID: ledger.recording?.id,
            sourceTitle: ledger.sourceTitle,
            sourceStartDate: ledger.sourceStartDate,
            sourceDuration: ledger.sourceDuration,
            sourceCalendarEventID: ledger.sourceCalendarEventID,
            sourceCreatedAt: ledger.sourceCreatedAt,
            sourceUpdatedAt: ledger.sourceUpdatedAt,
            lastAppliedAt: ledger.lastAppliedAt,
            contentFingerprint: ledger.contentFingerprint,
            transcriptFingerprint: ledger.transcriptFingerprint,
            lastAppliedSourceFingerprint: ledger.lastAppliedSourceFingerprint,
            lastAppliedLocalFingerprint: ledger.lastAppliedLocalFingerprint,
            disposition: ledger.disposition,
            reason: ledger.reason,
            qualitySignals: ledger.qualitySignals
        )
    }
#endif

    // MARK: - Private helpers

    private func externalImport(
        for identity: ExternalRecordingIdentity
    ) -> ExternalRecordingImport? {
        externalImport(byKey: identity.externalKey)
            ?? externalImport(byKey: Self.userDeletedExternalImportKey(
                provider: identity.provider,
                externalID: identity.externalID
            ))
    }

    private func externalImport(byKey key: String) -> ExternalRecordingImport? {
        var descriptor = FetchDescriptor<ExternalRecordingImport>(
            predicate: #Predicate { $0.externalKey == key }
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    private func externalImportDTO(_ ledger: ExternalRecordingImport) -> ExternalRecordingImportDTO {
        ExternalRecordingImportDTO(
            id: ledger.id,
            externalKey: ledger.externalKey,
            provider: ledger.provider,
            externalID: ledger.externalID,
            recordingID: ledger.recording?.id,
            sourceCreatedAt: ledger.sourceCreatedAt,
            sourceUpdatedAt: ledger.sourceUpdatedAt,
            lastSeenAt: ledger.lastSeenAt,
            lastAppliedAt: ledger.lastAppliedAt,
            contentFingerprint: ledger.contentFingerprint,
            lastAppliedLocalFingerprint: ledger.lastAppliedLocalFingerprint,
            disposition: ExternalImportDisposition(rawValue: ledger.disposition) ?? .conflict,
            reason: ledger.reason,
            qualitySignals: ledger.qualitySignals.compactMap(ExternalImportQualitySignal.init(rawValue:))
        )
    }

    private func previewResult(
        _ identity: ExternalRecordingIdentity,
        status: ExternalImportPreviewStatus,
        ledger: ExternalRecordingImport,
        reason: String?,
        qualitySignals: [ExternalImportQualitySignal]
    ) -> ExternalRecordingPreviewResult {
        ExternalRecordingPreviewResult(
            provider: identity.provider,
            externalID: identity.externalID,
            externalKey: identity.externalKey,
            status: status,
            recordingID: ledger.recording?.id,
            matchedRecordingID: nil,
            reason: reason,
            qualitySignals: qualitySignals
        )
    }

    private func possibleDuplicate(
        for input: ExternalRecordingPreviewInput
    ) -> (recording: Recording, reason: String)? {
        let recordings = (try? modelContext.fetch(FetchDescriptor<Recording>())) ?? []
        let active = recordings.filter { $0.trashedDate == nil }
        if let eventID = input.calendarEventID,
           let recording = active.first(where: {
               $0.linkedCalendarEventID == eventID
                   && abs($0.startDate.timeIntervalSince(input.startDate)) <= 15 * 60
           }) {
            return (recording, "Matched the same calendar event near the same start time.")
        }
        if let fingerprint = ExternalRecordingFingerprint.normalizedSHA256(input.transcriptFingerprint),
           let recording = active.first(where: {
               guard let text = $0.transcript?.fullText else { return false }
               return ExternalRecordingFingerprint.transcript(text) == fingerprint
           }) {
            return (recording, "Matched an existing transcript fingerprint.")
        }
        let normalizedTitle = input.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let recording = active.first(where: {
            let sameTitle = $0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedTitle
            let nearby = abs($0.startDate.timeIntervalSince(input.startDate)) <= 10 * 60
            let comparableDuration = $0.duration <= 0 || input.duration <= 0
                || abs($0.duration - input.duration) <= max(60, input.duration * 0.1)
            return sameTitle && nearby && comparableDuration
        }) {
            return (recording, "Title, start time and duration resemble an existing recording.")
        }
        return nil
    }

    private func applyExternalContent(
        _ input: ExternalRecordingUpsertInput,
        title: String,
        to recording: Recording,
        now: Date
    ) {
        recording.title = title
        recording.startDate = input.startDate
        recording.endDate = input.endDate
            ?? (input.duration > 0 ? input.startDate.addingTimeInterval(input.duration) : nil)
        recording.duration = max(0, input.duration)
        recording.language = input.language
        recording.meetingApp = input.meetingApp ?? input.provider
        recording.meetingURL = input.meetingURL
        recording.linkedCalendarEventID = input.calendarEventID
        recording.source = RecordingSource.external.rawValue
        recording.tags = normalizedExternalImportTags(input.tags)
        recording.updatedAt = now

        if let oldTranscript = recording.transcript {
            recording.transcript = nil
            modelContext.delete(oldTranscript)
        }
        if let transcriptInput = input.transcript {
            let transcript = Transcript(
                fullText: transcriptInput.fullText,
                segments: transcriptInput.segments.map {
                    TranscriptEntry(startTime: $0.startTime, endTime: $0.endTime,
                                    text: $0.text, speaker: $0.speaker)
                }
            )
            transcript.detectedLanguage = transcriptInput.detectedLanguage
            recording.transcript = transcript
        }

        if let oldSummary = recording.summary {
            recording.summary = nil
            modelContext.delete(oldSummary)
        }
        if let summaryInput = input.summary {
            let summary = MeetingSummary(
                overview: summaryInput.overview,
                keyPoints: summaryInput.keyPoints,
                actionItems: summaryInput.actionItems.map {
                    ActionItem(
                        assignee: $0.assignee,
                        task: $0.task,
                        deadline: $0.deadline,
                        isCompleted: $0.isCompleted,
                        priority: $0.priority
                    )
                },
                decisions: summaryInput.decisions,
                followUps: summaryInput.followUps,
                yourTasks: summaryInput.yourTasks,
                provider: .apple,
                model: "external-import",
                language: summaryInput.language
            )
            summary.provider = input.provider.lowercased()
            recording.summary = summary
        }
    }

    private func normalizedExternalImportTags(_ tags: [String]) -> [String] {
        let blocklist = UserDefaults.standard.stringArray(forKey: "tagBlocklist") ?? []
        return TagNormalizer(blocklist: blocklist).canonicalize(tags)
    }

    private func updateSeenMetadata(
        _ ledger: ExternalRecordingImport,
        input: ExternalRecordingUpsertInput,
        sourceFingerprint: String,
        transcriptFingerprint: String?,
        qualitySignals: [ExternalImportQualitySignal],
        now: Date
    ) {
        ledger.sourceTitle = input.title
        ledger.sourceStartDate = input.startDate
        ledger.sourceDuration = max(0, input.duration)
        ledger.sourceCalendarEventID = input.calendarEventID
        ledger.sourceCreatedAt = input.sourceCreatedAt
        ledger.sourceUpdatedAt = input.sourceUpdatedAt
        ledger.lastSeenAt = now
        ledger.contentFingerprint = sourceFingerprint
        ledger.transcriptFingerprint = transcriptFingerprint
        ledger.qualitySignals = qualitySignals.map(\.rawValue)
    }

    private func markConflict(
        _ ledger: ExternalRecordingImport,
        input: ExternalRecordingUpsertInput,
        sourceFingerprint: String,
        transcriptFingerprint: String?,
        qualitySignals: [ExternalImportQualitySignal],
        reason: String,
        now: Date
    ) {
        updateSeenMetadata(ledger, input: input, sourceFingerprint: sourceFingerprint,
                           transcriptFingerprint: transcriptFingerprint,
                           qualitySignals: qualitySignals, now: now)
        ledger.disposition = ExternalImportDisposition.conflict.rawValue
        ledger.reason = reason
    }

    private func externalPreviewInput(from input: ExternalRecordingUpsertInput) -> ExternalRecordingPreviewInput {
        ExternalRecordingPreviewInput(
            provider: input.provider,
            externalID: input.externalID,
            title: input.title,
            startDate: input.startDate,
            duration: input.duration,
            calendarEventID: input.calendarEventID,
            sourceCreatedAt: input.sourceCreatedAt,
            sourceUpdatedAt: input.sourceUpdatedAt,
            transcriptCharacterCount: input.transcript?.fullText.count ?? 0,
            transcriptSegmentCount: input.transcript?.segments.count ?? 0,
            hasSummary: input.summary != nil,
            actionItemCount: input.summary?.actionItems.count ?? 0,
            transcriptFingerprint: input.transcript.map {
                ExternalRecordingFingerprint.transcript($0.fullText)
            }
        )
    }

    private func failedExternalUpsert(
        _ reason: String,
        key: String? = nil
    ) -> ExternalRecordingUpsertResult {
        ExternalRecordingUpsertResult(
            status: .failed,
            externalKey: key,
            recordingID: nil,
            reason: reason,
            qualitySignals: []
        )
    }

    private func conflictExternalUpsert(
        _ key: String,
        recordingID: UUID?,
        reason: String?,
        qualitySignals: [ExternalImportQualitySignal]
    ) -> ExternalRecordingUpsertResult {
        ExternalRecordingUpsertResult(
            status: .conflict,
            externalKey: key,
            recordingID: recordingID,
            reason: reason,
            qualitySignals: qualitySignals
        )
    }
}
