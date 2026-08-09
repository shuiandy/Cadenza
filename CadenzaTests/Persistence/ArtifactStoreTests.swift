import Testing
import SwiftData
import Foundation
@testable import Cadenza

@MainActor
private func makeStore() throws -> RecordingsStore {
    let container = try RecordingsStore.makeContainer(inMemory: true)
    return RecordingsStore(modelContainer: container)
}

private func sampleCandidate(key: String, source: ArtifactProvenanceSource = .builtin,
                              status: ArtifactStatus = .ready,
                              generationID: UUID? = nil) -> ArtifactCandidate {
    ArtifactCandidate(
        kind: .meetingPrep, targetType: .calendarEvent,
        targetKey: key, bodyMarkdown: "placeholder",
        provenanceSource: source, provenanceDetail: "test",
        status: status,
        generationID: generationID,
        targetStartDate: Date(timeIntervalSince1970: 2_000_000),
        targetEndDate: Date(timeIntervalSince1970: 2_003_600),
        targetFingerprint: "fp1",
        contextBuiltAt: Date(timeIntervalSince1970: 1_999_000))
}

@Suite("ArtifactStore", .serialized)
struct ArtifactStoreTests {

    @Test @MainActor func modelInsertsAndFetchesViaContext() async throws {
        let container = try RecordingsStore.makeContainer(inMemory: true)
        let ctx = ModelContext(container)
        let a = AgentArtifact(
            kind: "meetingPrep", targetType: "calendarEvent",
            targetKey: "apple|c|e|", slotKey: "meetingPrep|calendarEvent|apple|c|e|",
            bodyMarkdown: "body", provenanceSource: "external", provenanceDetail: "test",
            status: "ready",
            targetStartDate: Date(timeIntervalSince1970: 2_000_000),
            targetEndDate: Date(timeIntervalSince1970: 2_003_600),
            targetFingerprint: "fp1", contextBuiltAt: Date(timeIntervalSince1970: 1_999_000))
        ctx.insert(a)
        try ctx.save()
        let fetched = try ctx.fetch(FetchDescriptor<AgentArtifact>()).first
        #expect(fetched?.slotKey == "meetingPrep|calendarEvent|apple|c|e|")
        #expect(fetched?.provenanceSource == "external")
        #expect(fetched?.bodyMarkdown == "body")
    }

    @Test @MainActor func externalOverwritesExisting() async throws {
        let store = try makeStore()
        let key = ArtifactTargetKey.make(source: "apple", calendarID: "c",
            providerEventID: "e", occurrenceAnchor: nil)
        var c1 = sampleCandidate(key: key, source: .builtin); c1.bodyMarkdown = "old"
        _ = await store.writeExternalArtifact(c1)  // 先放一个(用 external 写以简化)
        var c2 = sampleCandidate(key: key, source: .external); c2.bodyMarkdown = "new"
        _ = await store.writeExternalArtifact(c2)

        let slot = ArtifactTargetKey.slotKey(
            kind: "meetingPrep", targetType: "calendarEvent", targetKey: key)
        let fetched = await store.fetchArtifact(slotKey: slot)
        #expect(fetched?.bodyMarkdown == "new")
        #expect(fetched?.provenanceSource == "external")

        // 仍只有一行(无重复)
        let count = await store.artifactCountForTests(slotKey: slot)
        #expect(count == 1)
    }

    @Test @MainActor func acquireRejectedWhenExternalPresent() async throws {
        let store = try makeStore()
        let key = ArtifactTargetKey.make(source: "apple", calendarID: "c", providerEventID: "e", occurrenceAnchor: nil)
        _ = await store.writeExternalArtifact(sampleCandidate(key: key, source: .external))
        let slot = ArtifactTargetKey.slotKey(kind: "meetingPrep", targetType: "calendarEvent", targetKey: key)
        let r = await store.acquireBuiltinSlot(slotKey: slot, placeholder: sampleCandidate(key: key),
            newGenerationID: UUID(), now: Date(timeIntervalSince1970: 3_000_000), generatingTTL: 600)
        #expect({ if case .rejected = r { return true } else { return false } }())
    }

    @Test @MainActor func builtinCommitDoesNotOverwriteExternal() async throws {
        let store = try makeStore()
        let key = ArtifactTargetKey.make(source: "apple", calendarID: "c", providerEventID: "e", occurrenceAnchor: nil)
        let slot = ArtifactTargetKey.slotKey(kind: "meetingPrep", targetType: "calendarEvent", targetKey: key)
        let g = UUID()
        let a = await store.acquireBuiltinSlot(slotKey: slot, placeholder: sampleCandidate(key: key),
            newGenerationID: g, now: Date(timeIntervalSince1970: 3_000_000), generatingTTL: 600)
        #expect({ if case .acquired = a { return true } else { return false } }())

        var ext = sampleCandidate(key: key, source: .external); ext.bodyMarkdown = "ext"
        _ = await store.writeExternalArtifact(ext)

        var done = sampleCandidate(key: key, source: .builtin, generationID: g); done.bodyMarkdown = "builtin-late"
        let committed = await store.commitBuiltin(done, generationID: g)
        #expect(committed == false)

        let fetched = await store.fetchArtifact(slotKey: slot)
        #expect(fetched?.provenanceSource == "external")
        #expect(fetched?.bodyMarkdown == "ext")
    }

    @Test @MainActor func staleBuiltinCanBeReacquired() async throws {
        let store = try makeStore()
        let key = ArtifactTargetKey.make(source: "apple", calendarID: "c", providerEventID: "e", occurrenceAnchor: nil)
        let slot = ArtifactTargetKey.slotKey(kind: "meetingPrep", targetType: "calendarEvent", targetKey: key)
        let g0 = UUID()
        _ = await store.acquireBuiltinSlot(slotKey: slot, placeholder: sampleCandidate(key: key),
            newGenerationID: g0, now: Date(timeIntervalSince1970: 3_000_000), generatingTTL: 600)
        var stale = sampleCandidate(key: key, source: .builtin, status: .ready, generationID: g0)
        stale.staleReason = "eventMoved"
        _ = await store.commitBuiltin(stale, generationID: g0)

        let g1 = UUID()
        let a = await store.acquireBuiltinSlot(slotKey: slot, placeholder: sampleCandidate(key: key),
            newGenerationID: g1, now: Date(timeIntervalSince1970: 3_100_000), generatingTTL: 600)
        #expect({ if case .acquired = a { return true } else { return false } }())
    }

    @Test @MainActor func expiredGeneratingReacquirableButFreshIsNot() async throws {
        let store = try makeStore()
        let key = ArtifactTargetKey.make(source: "apple", calendarID: "c", providerEventID: "e", occurrenceAnchor: nil)
        let slot = ArtifactTargetKey.slotKey(kind: "meetingPrep", targetType: "calendarEvent", targetKey: key)
        let g0 = UUID()
        _ = await store.acquireBuiltinSlot(slotKey: slot, placeholder: sampleCandidate(key: key),
            newGenerationID: g0, now: Date(timeIntervalSince1970: 3_000_000), generatingTTL: 600)
        // still generating, never committed. Past TTL → reclaimable:
        let g1 = UUID()
        let a = await store.acquireBuiltinSlot(slotKey: slot, placeholder: sampleCandidate(key: key),
            newGenerationID: g1, now: Date(timeIntervalSince1970: 3_000_700), generatingTTL: 600)
        #expect({ if case .acquired = a { return true } else { return false } }())
        // fresh (non-expired) generating placeholder → NOT reclaimable:
        let g2 = UUID()
        let b = await store.acquireBuiltinSlot(slotKey: slot, placeholder: sampleCandidate(key: key),
            newGenerationID: g2, now: Date(timeIntervalSince1970: 3_000_800), generatingTTL: 600)
        #expect({ if case .rejected = b { return true } else { return false } }())
    }

    @Test @MainActor func overrideReplacesExternalOnSuccess() async throws {
        let store = try makeStore()
        let key = ArtifactTargetKey.make(source: "apple", calendarID: "c",
            providerEventID: "e", occurrenceAnchor: nil)
        let slot = ArtifactTargetKey.slotKey(kind: "meetingPrep",
            targetType: "calendarEvent", targetKey: key)
        var ext = sampleCandidate(key: key, source: .external); ext.bodyMarkdown = "ext"
        _ = await store.writeExternalArtifact(ext)
        let prior = await store.fetchArtifact(slotKey: slot)!.updatedAt

        var reGen = sampleCandidate(key: key, source: .builtin, status: .ready)
        reGen.bodyMarkdown = "user-builtin"
        let ok = await store.overrideWithBuiltin(reGen, expectedPriorExternalUpdatedAt: prior)
        #expect(ok == true)
        let f = await store.fetchArtifact(slotKey: slot)
        #expect(f?.provenanceSource == "builtin")
        #expect(f?.bodyMarkdown == "user-builtin")
    }

    @Test @MainActor func overrideAbandonsWhenExternalChangedUnderneath() async throws {
        let store = try makeStore()
        let key = ArtifactTargetKey.make(source: "apple", calendarID: "c",
            providerEventID: "e", occurrenceAnchor: nil)
        let slot = ArtifactTargetKey.slotKey(kind: "meetingPrep",
            targetType: "calendarEvent", targetKey: key)
        var ext = sampleCandidate(key: key, source: .external); ext.bodyMarkdown = "ext1"
        _ = await store.writeExternalArtifact(ext)
        let stalePrior = Date(timeIntervalSince1970: 1) // 明显早于真实 updatedAt

        var reGen = sampleCandidate(key: key, source: .builtin, status: .ready)
        reGen.bodyMarkdown = "user-builtin"
        let ok = await store.overrideWithBuiltin(reGen, expectedPriorExternalUpdatedAt: stalePrior)
        #expect(ok == false)
        let f = await store.fetchArtifact(slotKey: slot)
        #expect(f?.provenanceSource == "external") // 原 external 保留
        #expect(f?.bodyMarkdown == "ext1")
    }

    @Test @MainActor func overrideRejectsNonReadyCandidate() async throws {
        let store = try makeStore()
        let key = ArtifactTargetKey.make(source: "apple", calendarID: "c", providerEventID: "e", occurrenceAnchor: nil)
        let slot = ArtifactTargetKey.slotKey(kind: "meetingPrep", targetType: "calendarEvent", targetKey: key)
        var ext = sampleCandidate(key: key, source: .external); ext.bodyMarkdown = "ext"
        _ = await store.writeExternalArtifact(ext)
        var failed = sampleCandidate(key: key, source: .builtin, status: .failed)
        failed.bodyMarkdown = "should-not-apply"
        let ok = await store.overrideWithBuiltin(failed, expectedPriorExternalUpdatedAt: nil)
        #expect(ok == false)
        let f = await store.fetchArtifact(slotKey: slot)
        #expect(f?.provenanceSource == "external")
        #expect(f?.bodyMarkdown == "ext")
    }

    @Test @MainActor func overrideInsertsWhenSlotEmpty() async throws {
        let store = try makeStore()
        let key = ArtifactTargetKey.make(source: "apple", calendarID: "c", providerEventID: "e", occurrenceAnchor: nil)
        let slot = ArtifactTargetKey.slotKey(kind: "meetingPrep", targetType: "calendarEvent", targetKey: key)
        var reGen = sampleCandidate(key: key, source: .builtin, status: .ready); reGen.bodyMarkdown = "fresh"
        let ok = await store.overrideWithBuiltin(reGen, expectedPriorExternalUpdatedAt: nil)
        #expect(ok == true)
        let f = await store.fetchArtifact(slotKey: slot)
        #expect(f?.provenanceSource == "builtin")
        #expect(f?.bodyMarkdown == "fresh")
    }

    // Fix (Codex review): a caller that started from an empty/builtin slot (so it captured
    // no prior external, expectedPriorExternalUpdatedAt == nil) must NOT be allowed to
    // stomp an external that landed in the meantime (e.g. an agent's write_artifact call
    // racing a manual "regenerate" in flight) — the newer external always wins.
    @Test @MainActor func overrideRejectsWhenExternalArrivedMidGenerationWithNilExpectation() async throws {
        let store = try makeStore()
        let key = ArtifactTargetKey.make(source: "apple", calendarID: "c", providerEventID: "e", occurrenceAnchor: nil)
        let slot = ArtifactTargetKey.slotKey(kind: "meetingPrep", targetType: "calendarEvent", targetKey: key)
        // Slot starts empty (caller captured expectedPriorExternalUpdatedAt == nil at that point).
        // Before the builtin generation finishes, an external write lands.
        var ext = sampleCandidate(key: key, source: .external); ext.bodyMarkdown = "ext-arrived-mid-generation"
        _ = await store.writeExternalArtifact(ext)

        var reGen = sampleCandidate(key: key, source: .builtin, status: .ready)
        reGen.bodyMarkdown = "builtin-should-not-land"
        let ok = await store.overrideWithBuiltin(reGen, expectedPriorExternalUpdatedAt: nil)
        #expect(ok == false)
        let f = await store.fetchArtifact(slotKey: slot)
        #expect(f?.provenanceSource == "external")
        #expect(f?.bodyMarkdown == "ext-arrived-mid-generation")
    }

    // Regression guard: pins SwiftData @Attribute(.unique) behavior observed on 2026-06-30.
    // Observed: inserting two AgentArtifact objects with the same slotKey into the same
    // ModelContext and saving collapses them to ONE row (last-write-wins upsert) — NOT two
    // rows and NOT a thrown constraint error. The duplicate insert is silently merged.
    //
    // Consequence: collapseDuplicateSlots() is a no-op in the normal path (row count is
    // always 1 after any number of same-key inserts in one context). It remains as a
    // safety net for hypothetical cross-context or legacy migration duplicates.
    @Test @MainActor func permanentFailedIsNotReacquired() async throws {
        let store = try makeStore()
        let key = ArtifactTargetKey.make(source: "apple", calendarID: "c", providerEventID: "e", occurrenceAnchor: nil)
        let slot = ArtifactTargetKey.slotKey(kind: "meetingPrep", targetType: "calendarEvent", targetKey: key)
        let g0 = UUID()
        _ = await store.acquireBuiltinSlot(slotKey: slot, placeholder: sampleCandidate(key: key),
            newGenerationID: g0, now: Date(timeIntervalSince1970: 3_000_000), generatingTTL: 600)
        var failed = sampleCandidate(key: key, source: .builtin, status: .failed, generationID: g0)
        failed.errorClass = .permanent
        _ = await store.commitBuiltin(failed, generationID: g0)
        // permanent failure blocks automatic re-acquire
        let r = await store.acquireBuiltinSlot(slotKey: slot, placeholder: sampleCandidate(key: key),
            newGenerationID: UUID(), now: Date(timeIntervalSince1970: 3_100_000), generatingTTL: 600)
        #expect({ if case .rejected = r { return true } else { return false } }())
    }

    @Test @MainActor func generatingWithNilStartedAtIsReacquirable() async throws {
        // Defensive branch: a builtin `generating` row lacking generatingStartedAt
        // (legacy/migration/non-acquire origin) is treated as an orphan and is reclaimable.
        let store = try makeStore()
        let key = ArtifactTargetKey.make(source: "apple", calendarID: "c", providerEventID: "e", occurrenceAnchor: nil)
        let slot = ArtifactTargetKey.slotKey(kind: "meetingPrep", targetType: "calendarEvent", targetKey: key)
        var orphan = sampleCandidate(key: key, source: .builtin, status: .generating)
        orphan.generatingStartedAt = nil
        await store.insertRawDuplicatesForTests(candidate: orphan, times: 1)
        let r = await store.acquireBuiltinSlot(slotKey: slot, placeholder: sampleCandidate(key: key),
            newGenerationID: UUID(), now: Date(timeIntervalSince1970: 3_000_000), generatingTTL: 600)
        #expect({ if case .acquired = r { return true } else { return false } }())
    }

    @Test @MainActor func collapseAndUniqueBehavior() async throws {
        let store = try makeStore()
        let key = ArtifactTargetKey.make(source: "apple", calendarID: "c",
            providerEventID: "probe", occurrenceAnchor: nil)
        let slot = ArtifactTargetKey.slotKey(kind: "meetingPrep",
            targetType: "calendarEvent", targetKey: key)

        // Attempt to insert 2 rows for the same slotKey via the raw helper.
        await store.insertRawDuplicatesForTests(candidate: sampleCandidate(key: key), times: 2)

        // Observed behavior: SwiftData @unique upserts duplicate inserts into ONE row.
        let count = await store.artifactCountForTests(slotKey: slot)
        #expect(count == 1, "SwiftData @Attribute(.unique) must collapse duplicate inserts to 1 row")

        // collapseDuplicateSlots is a no-op when only 1 row exists (safety-net, not primary path).
        let removed = await store.collapseDuplicateSlots(slotKey: slot)
        #expect(removed == 0, "collapseDuplicateSlots must return 0 when row count is already 1")

        // Row count unchanged after no-op collapse.
        let countAfter = await store.artifactCountForTests(slotKey: slot)
        #expect(countAfter == 1)
    }
}
