import Testing
import SwiftData
import Foundation
@testable import Cadenza

@MainActor private func store() throws -> RecordingsStore { RecordingsStore(modelContainer: try RecordingsStore.makeContainer(inMemory: true)) }

@Suite("MeetingPrepScheduler", .serialized)
struct MeetingPrepSchedulerTests {
    private func ev(id: String, minsUntil: Int, now: Date) -> MeetingEvent {
        MeetingEvent(id: id, title: "Sync", startDate: now.addingTimeInterval(Double(minsUntil)*60),
            endDate: now.addingTimeInterval(Double(minsUntil)*60 + 3600),
            meetingURL: URL(string: "https://zoom.us/j/1"), meetingApp: .zoom, calendarName: "c", notes: nil,
            source: .apple, calendarID: "c",
            attendees: [EventAttendee(name: "D", email: "d@x.com", isOrganizer: true, status: .accepted)])
    }

    @Test @MainActor func generatesPrepForEligibleEmptySlot() async throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let s = try store()
        let sched = MeetingPrepScheduler(store: s, leadMinutes: 30, generatingTTL: 600)
        sched.generateOverride = { _, _ in .success("## Prep\nbody") } // inject success, skip real provider
        let e = ev(id: "APPLE1", minsUntil: 20, now: now)
        await sched.tick(events: [e], now: now)
        let dto = await s.fetchArtifact(slotKey: ArtifactTargetKey.slotKey(kind: "meetingPrep", targetType: "calendarEvent", targetKey: e.artifactTargetKey))
        #expect(dto?.provenanceSource == "builtin")
        #expect(dto?.status == "ready")
        #expect(dto?.bodyMarkdown == "## Prep\nbody")
    }

    @Test @MainActor func doesNotOverwriteExternal() async throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let s = try store()
        let e = ev(id: "APPLE2", minsUntil: 20, now: now)
        let slot = ArtifactTargetKey.slotKey(kind: "meetingPrep", targetType: "calendarEvent", targetKey: e.artifactTargetKey)
        _ = await s.writeExternalArtifact(ArtifactCandidate(kind: .meetingPrep, targetType: .calendarEvent,
            targetKey: e.artifactTargetKey, bodyMarkdown: "EXT", provenanceSource: .external, provenanceDetail: "mcp",
            status: .ready, generationID: nil, generatingStartedAt: nil, errorClass: nil, errorMessage: nil,
            targetStartDate: e.startDate, targetEndDate: e.endDate,
            targetFingerprint: MeetingPrepFingerprint.compute(e), contextBuiltAt: now, staleReason: nil))
        let sched = MeetingPrepScheduler(store: s, leadMinutes: 30, generatingTTL: 600)
        sched.generateOverride = { _, _ in .success("BUILTIN") }
        await sched.tick(events: [e], now: now)
        #expect(await s.fetchArtifact(slotKey: slot)?.bodyMarkdown == "EXT")  // external preserved
    }

    @Test func classifiesNoKeyAsPermanent() {
        #expect(MeetingPrepScheduler.classify(.noAPIKey) == .permanent)
        #expect(MeetingPrepScheduler.classify(.provider(URLError(.timedOut))) == .retryable)
    }

    @Test @MainActor func urlOnlyMeetingDoesNotLeakUnrelatedContext() async throws {
        // 回归:无其他参会人时 speakerQueries 若传 nil = 不过滤 → 全量 excerpts →
        // scoped() 全当相关 → 全库泄露。正确行为:禁用 excerpt 路径,只留标题匹配。
        let now = Date(timeIntervalSince1970: 10_000)
        let s = try store()
        // 库里 seed 一条与会议无关的 recording(带 transcript + summary)
        let recID = UUID()
        await s.createRecording(id: recID, title: "Security Incident Review",
                                startDate: now.addingTimeInterval(-86_400), segmentsDirURL: nil)
        let segments = [TranscriptEntry(startTime: 0, endTime: 5, text: "rotating credentials", speaker: "Speaker 1")]
        await s.saveTranscript(recordingID: recID, fullText: "rotating credentials",
                               segments: segments, language: "en", tags: [])
        let summary = SummaryResult(title: "Security Incident Review", overview: "Rotated all keys.",
            keyPoints: [], actionItems: [ActionItemResult(assignee: nil, task: "rotate keys", deadline: nil)],
            decisions: [], followUps: [], yourTasks: [], tags: [], chapters: [], rawText: "")
        await s.saveSummary(recordingID: recID, summary: summary, chaptersJSON: nil)

        // URL-only 会议:无其他参会人(eligibility 靠 meetingURL 放行)
        let e = MeetingEvent(id: "URLONLY", title: "Quick Huddle",
            startDate: now.addingTimeInterval(20 * 60), endDate: now.addingTimeInterval(20 * 60 + 3600),
            meetingURL: URL(string: "https://zoom.us/j/9"), meetingApp: .zoom, calendarName: "c",
            notes: nil, source: .apple, calendarID: "c", attendees: [])

        let sched = MeetingPrepScheduler(store: s, leadMinutes: 30, generatingTTL: 600)
        actor Captured { var text = ""; func set(_ t: String) { text = t } }
        let captured = Captured()
        sched.generateOverride = { _, ctx in await captured.set(ctx); return .success("ok") }
        await sched.tick(events: [e], now: now)

        let ctx = await captured.text
        #expect(!ctx.isEmpty)                                  // 生成确实跑了
        #expect(!ctx.contains("Security Incident Review"))     // 无关会议标题不进 prompt
        #expect(!ctx.contains("rotate keys"))                  // 无关待办不进 prompt
        #expect(!ctx.contains("Rotated all keys."))            // 无关摘要不进 prompt
    }

    @Test @MainActor func blankAttendeeNamesDoNotLeakUnrelatedContext() async throws {
        // 回归:GoogleEventParser 在 displayName+email 都缺时会产出空字符串 attendee name。
        // 空名若混入 speakerQueries → String.contains("") 命中一切 → 全库泄露。
        // 正确行为:trim+过滤空名后视同"无其他参会人",走 maxTranscriptEntries:0 路径。
        let now = Date(timeIntervalSince1970: 10_000)
        let s = try store()
        let recID = UUID()
        await s.createRecording(id: recID, title: "Security Incident Review",
                                startDate: now.addingTimeInterval(-86_400), segmentsDirURL: nil)
        let segments = [TranscriptEntry(startTime: 0, endTime: 5, text: "rotating credentials", speaker: "Speaker 1")]
        await s.saveTranscript(recordingID: recID, fullText: "rotating credentials",
                               segments: segments, language: "en", tags: [])
        let summary = SummaryResult(title: "Security Incident Review", overview: "Rotated all keys.",
            keyPoints: [], actionItems: [ActionItemResult(assignee: nil, task: "rotate keys", deadline: nil)],
            decisions: [], followUps: [], yourTasks: [], tags: [], chapters: [], rawText: "")
        await s.saveSummary(recordingID: recID, summary: summary, chaptersJSON: nil)

        // 会议有 URL(eligible),attendees 全是空/空白名(displayName+email 缺失场景)
        let e = MeetingEvent(id: "BLANKATTENDEE", title: "Quick Huddle",
            startDate: now.addingTimeInterval(20 * 60), endDate: now.addingTimeInterval(20 * 60 + 3600),
            meetingURL: URL(string: "https://zoom.us/j/9"), meetingApp: .zoom, calendarName: "c",
            notes: nil, source: .apple, calendarID: "c",
            attendees: [EventAttendee(name: "", email: "", isOrganizer: false, status: .accepted),
                        EventAttendee(name: "   ", email: "", isOrganizer: false, status: .accepted)])

        let sched = MeetingPrepScheduler(store: s, leadMinutes: 30, generatingTTL: 600)
        actor Captured { var text = ""; func set(_ t: String) { text = t } }
        let captured = Captured()
        sched.generateOverride = { _, ctx in await captured.set(ctx); return .success("ok") }
        await sched.tick(events: [e], now: now)

        let ctx = await captured.text
        #expect(!ctx.isEmpty)
        #expect(!ctx.contains("Security Incident Review"))
        #expect(!ctx.contains("rotate keys"))
        #expect(!ctx.contains("Rotated all keys."))
    }

    /// Codex merge review P1: the store's recording-level speaker filter drops any
    /// recording where no attendee spoke — including title-similar past occurrences
    /// whose transcript is still unidentified ("Speaker 1") or was just cleared by a
    /// retranscription. scoped()'s documented "excerpt hit OR title similar" union
    /// then has nothing to fall back to, and prep silently loses the history.
    @Test @MainActor func assembleRetainsTitleMatchWithoutSpeakerHit() async throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let s = try store()

        // Past occurrence of the same meeting: useful summary, but its transcript
        // speakers were never resolved — no attendee name can match it.
        let recID = UUID()
        await s.createRecording(id: recID, title: "Roadmap Sync",
                                startDate: now.addingTimeInterval(-86_400), segmentsDirURL: nil)
        await s.saveTranscript(recordingID: recID, fullText: "we agreed to cut scope",
            segments: [TranscriptEntry(startTime: 0, endTime: 5, text: "we agreed to cut scope", speaker: "Speaker 1")],
            language: "en", tags: [])
        let summary = SummaryResult(title: "Roadmap Sync", overview: "Agreed to cut scope X.",
            keyPoints: [], actionItems: [ActionItemResult(assignee: nil, task: "draft the spec", deadline: nil)],
            decisions: [], followUps: [], yourTasks: [], tags: [], chapters: [], rawText: "")
        await s.saveSummary(recordingID: recID, summary: summary, chaptersJSON: nil)

        let event = MeetingEvent(id: "RS", title: "Roadmap Sync",
            startDate: now.addingTimeInterval(20 * 60), endDate: now.addingTimeInterval(20 * 60 + 3600),
            meetingURL: nil, meetingApp: nil, calendarName: "c", notes: nil, source: .apple, calendarID: "c",
            attendees: [EventAttendee(name: "Dana", email: "d@x.com", isOrganizer: true, status: .accepted)])

        let ctx = await MeetingPrepContextBuilder.assemble(event: event, store: s)
        #expect(ctx.contains("Agreed to cut scope X."))   // title fallback survives
        #expect(ctx.contains("draft the spec"))
    }

    /// Codex review round 2: merge() must re-sort by time. Appending title-only
    /// candidates after every speaker hit let build()'s prefix(5) evict them — the
    /// exact recording this fallback exists to rescue.
    @Test @MainActor func titleCandidateSurvivesAmongManySpeakerHits() async throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let s = try store()

        // 6 older recordings where Dana spoke — enough to fill build()'s prefix(5).
        for i in 0..<6 {
            let id = UUID()
            await s.createRecording(id: id, title: "Chat \(i)",
                                    startDate: now.addingTimeInterval(-864_000 - Double(i) * 3600), segmentsDirURL: nil)
            await s.saveTranscript(recordingID: id, fullText: "older",
                segments: [TranscriptEntry(startTime: 0, endTime: 5, text: "older", speaker: "Dana")],
                language: "en", tags: [])
            let sum = SummaryResult(title: "Chat \(i)", overview: "older overview \(i)",
                keyPoints: [], actionItems: [], decisions: [], followUps: [], yourTasks: [],
                tags: [], chapters: [], rawText: "")
            await s.saveSummary(recordingID: id, summary: sum, chaptersJSON: nil)
        }

        // The NEWEST relevant recording: same title as the meeting, speakers unidentified.
        let titleOnly = UUID()
        await s.createRecording(id: titleOnly, title: "Roadmap Sync",
                                startDate: now.addingTimeInterval(-3_600), segmentsDirURL: nil)
        await s.saveTranscript(recordingID: titleOnly, fullText: "scope call",
            segments: [TranscriptEntry(startTime: 0, endTime: 5, text: "scope call", speaker: "Speaker 1")],
            language: "en", tags: [])
        let sum = SummaryResult(title: "Roadmap Sync", overview: "THE TITLE MATCH OVERVIEW",
            keyPoints: [], actionItems: [], decisions: [], followUps: [], yourTasks: [],
            tags: [], chapters: [], rawText: "")
        await s.saveSummary(recordingID: titleOnly, summary: sum, chaptersJSON: nil)

        let event = MeetingEvent(id: "RS2", title: "Roadmap Sync",
            startDate: now.addingTimeInterval(20 * 60), endDate: now.addingTimeInterval(20 * 60 + 3600),
            meetingURL: nil, meetingApp: nil, calendarName: "c", notes: nil, source: .apple, calendarID: "c",
            attendees: [EventAttendee(name: "Dana", email: "d@x.com", isOrganizer: true, status: .accepted)])

        let ctx = await MeetingPrepContextBuilder.assemble(event: event, store: s)
        #expect(ctx.contains("THE TITLE MATCH OVERVIEW"))
    }

    @Test func classifiesRateLimitRetryableButQuotaPermanent() {
        // 429/rate-limit = 瞬时限流 → retryable(靠退避);配额耗尽/账单 → permanent
        let rateLimit = NSError(domain: "api", code: 429,
            userInfo: [NSLocalizedDescriptionKey: "429 Too Many Requests — rate limit exceeded"])
        #expect(MeetingPrepScheduler.classify(.provider(rateLimit)) == .retryable)
        let quota = NSError(domain: "api", code: 429,
            userInfo: [NSLocalizedDescriptionKey: "You exceeded your current quota, please check your plan and billing details"])
        #expect(MeetingPrepScheduler.classify(.provider(quota)) == .permanent)
    }

    @Test @MainActor func retryableFailureBacksOffAndDoesNotHotLoop() async throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let s = try store()
        let e = ev(id: "APPLE_FAIL", minsUntil: 20, now: now)
        let slot = ArtifactTargetKey.slotKey(kind: "meetingPrep", targetType: "calendarEvent", targetKey: e.artifactTargetKey)
        let sched = MeetingPrepScheduler(store: s, leadMinutes: 30, generatingTTL: 600)
        actor Counter { var n = 0; func inc() { n += 1 } }
        let counter = Counter()
        sched.generateOverride = { _, _ in await counter.inc(); return .failure(.provider(URLError(.timedOut))) }

        await sched.tick(events: [e], now: now)
        #expect(await counter.n == 1)
        let dto1 = await s.fetchArtifact(slotKey: slot)
        #expect(dto1?.status == "failed")
        #expect(dto1?.retryAfter != nil)                 // backoff persisted

        // second tick 5s later → still within backoff → NOT re-attempted
        await sched.tick(events: [e], now: now.addingTimeInterval(5))
        #expect(await counter.n == 1)                    // no hot-loop

        // tick after the backoff window → retried
        await sched.tick(events: [e], now: now.addingTimeInterval(400))
        #expect(await counter.n == 2)
    }

    // MARK: - generateNow(手动重生成)

    @Test @MainActor func generateNowFillsEmptySlotIgnoringWindow() async throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let s = try store()
        let e = ev(id: "MANUAL1", minsUntil: 600, now: now)   // 10h 后,自动路径不会触发
        let sched = MeetingPrepScheduler(store: s, leadMinutes: 30, generatingTTL: 600)
        sched.generateOverride = { _, _ in .success("## Manual prep") }
        let ok = await sched.generateNow(event: e)
        #expect(ok)
        let slot = ArtifactTargetKey.slotKey(kind: "meetingPrep", targetType: "calendarEvent", targetKey: e.artifactTargetKey)
        let dto = await s.fetchArtifact(slotKey: slot)
        #expect(dto?.provenanceSource == "builtin")
        #expect(dto?.status == "ready")
        #expect(dto?.bodyMarkdown == "## Manual prep")
    }

    @Test @MainActor func generateNowOverridesExternalOnUserIntent() async throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let s = try store()
        let e = ev(id: "MANUAL2", minsUntil: 20, now: now)
        let slot = ArtifactTargetKey.slotKey(kind: "meetingPrep", targetType: "calendarEvent", targetKey: e.artifactTargetKey)
        _ = await s.writeExternalArtifact(ArtifactCandidate(kind: .meetingPrep, targetType: .calendarEvent,
            targetKey: e.artifactTargetKey, bodyMarkdown: "EXT", provenanceSource: .external, provenanceDetail: "mcp",
            status: .ready, generationID: nil, generatingStartedAt: nil, errorClass: nil, errorMessage: nil,
            targetStartDate: e.startDate, targetEndDate: e.endDate,
            targetFingerprint: MeetingPrepFingerprint.compute(e), contextBuiltAt: now, staleReason: nil))
        let sched = MeetingPrepScheduler(store: s, leadMinutes: 30, generatingTTL: 600)
        sched.generateOverride = { _, _ in .success("USER-REQUESTED") }
        let ok = await sched.generateNow(event: e)
        #expect(ok)
        let dto = await s.fetchArtifact(slotKey: slot)
        #expect(dto?.provenanceSource == "builtin")     // 用户显式意图可覆盖 external(spec §4.3)
        #expect(dto?.bodyMarkdown == "USER-REQUESTED")
    }

    @Test @MainActor func generateNowOnEmptySlotDoesNotStompExternalThatArrivedMidGeneration() async throws {
        // Fix (Codex review): generateNow starts from an empty slot (no prior external
        // captured), but an agent's write_artifact races it and lands an external mid-flight.
        // The newer external must win — generateNow must report failure and leave it intact.
        let now = Date(timeIntervalSince1970: 10_000)
        let s = try store()
        let e = ev(id: "MANUAL_RACE", minsUntil: 600, now: now)
        let slot = ArtifactTargetKey.slotKey(kind: "meetingPrep", targetType: "calendarEvent", targetKey: e.artifactTargetKey)
        let sched = MeetingPrepScheduler(store: s, leadMinutes: 30, generatingTTL: 600)
        sched.generateOverride = { _, _ in
            // Simulate an agent's external write landing mid-generation.
            _ = await s.writeExternalArtifact(ArtifactCandidate(kind: .meetingPrep, targetType: .calendarEvent,
                targetKey: e.artifactTargetKey, bodyMarkdown: "AGENT-EXTERNAL", provenanceSource: .external,
                provenanceDetail: "mcp", status: .ready, generationID: nil, generatingStartedAt: nil,
                errorClass: nil, errorMessage: nil, targetStartDate: e.startDate, targetEndDate: e.endDate,
                targetFingerprint: MeetingPrepFingerprint.compute(e), contextBuiltAt: now, staleReason: nil))
            return .success("BUILTIN-SHOULD-NOT-LAND")
        }
        let ok = await sched.generateNow(event: e)
        #expect(!ok)
        let dto = await s.fetchArtifact(slotKey: slot)
        #expect(dto?.provenanceSource == "external")
        #expect(dto?.bodyMarkdown == "AGENT-EXTERNAL")
    }

    @Test @MainActor func generateNowFailureLeavesSlotUntouched() async throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let s = try store()
        let e = ev(id: "MANUAL3", minsUntil: 20, now: now)
        let slot = ArtifactTargetKey.slotKey(kind: "meetingPrep", targetType: "calendarEvent", targetKey: e.artifactTargetKey)
        _ = await s.writeExternalArtifact(ArtifactCandidate(kind: .meetingPrep, targetType: .calendarEvent,
            targetKey: e.artifactTargetKey, bodyMarkdown: "EXT", provenanceSource: .external, provenanceDetail: "mcp",
            status: .ready, generationID: nil, generatingStartedAt: nil, errorClass: nil, errorMessage: nil,
            targetStartDate: e.startDate, targetEndDate: e.endDate,
            targetFingerprint: MeetingPrepFingerprint.compute(e), contextBuiltAt: now, staleReason: nil))
        let sched = MeetingPrepScheduler(store: s, leadMinutes: 30, generatingTTL: 600)
        sched.generateOverride = { _, _ in .failure(.provider(URLError(.timedOut))) }
        let ok = await sched.generateNow(event: e)
        #expect(!ok)
        let dto = await s.fetchArtifact(slotKey: slot)
        #expect(dto?.provenanceSource == "external")    // 失败不动槽位(out-of-band,spec §4.4)
        #expect(dto?.bodyMarkdown == "EXT")
        #expect(dto?.status == "ready")
    }
}
