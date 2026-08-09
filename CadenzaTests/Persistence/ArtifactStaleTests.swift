import Testing
import SwiftData
import Foundation
@testable import Cadenza

@MainActor private func makeStore() throws -> RecordingsStore {
    RecordingsStore(modelContainer: try RecordingsStore.makeContainer(inMemory: true))
}

@Suite("ArtifactStale", .serialized)
struct ArtifactStaleTests {
    private func candidate(key: String, fingerprint: String) -> ArtifactCandidate {
        ArtifactCandidate(kind: .meetingPrep, targetType: .calendarEvent, targetKey: key,
            bodyMarkdown: "b", provenanceSource: .external, provenanceDetail: "mcp",
            status: .ready, generationID: nil, generatingStartedAt: nil, errorClass: nil, errorMessage: nil,
            targetStartDate: Date(timeIntervalSince1970: 1000), targetEndDate: Date(timeIntervalSince1970: 4600),
            targetFingerprint: fingerprint, contextBuiltAt: Date(timeIntervalSince1970: 900), staleReason: nil)
    }

    @Test @MainActor func dtoCarriesFingerprintAndRetryAfter() async throws {
        let store = try makeStore()
        let key = ArtifactTargetKey.make(source: "apple", calendarID: "c", providerEventID: "e", occurrenceAnchor: nil)
        _ = await store.writeExternalArtifact(candidate(key: key, fingerprint: "fp1"))
        let slot = ArtifactTargetKey.slotKey(kind: "meetingPrep", targetType: "calendarEvent", targetKey: key)
        let dto = await store.fetchArtifact(slotKey: slot)
        #expect(dto?.targetFingerprint == "fp1")
        #expect(dto?.retryAfter == nil)
    }

    @Test @MainActor func markStaleWhenFingerprintChanged() async throws {
        let store = try makeStore()
        let key = ArtifactTargetKey.make(source: "apple", calendarID: "c", providerEventID: "e", occurrenceAnchor: nil)
        _ = await store.writeExternalArtifact(candidate(key: key, fingerprint: "fp1"))
        let slot = ArtifactTargetKey.slotKey(kind: "meetingPrep", targetType: "calendarEvent", targetKey: key)

        let markedSame = await store.markStaleIfChanged(slotKey: slot, currentFingerprint: "fp1")
        #expect(markedSame == false)
        #expect(await store.fetchArtifact(slotKey: slot)?.staleReason == nil)

        let markedDiff = await store.markStaleIfChanged(slotKey: slot, currentFingerprint: "fp2")
        #expect(markedDiff == true)
        #expect(await store.fetchArtifact(slotKey: slot)?.staleReason == "eventChanged")
    }
}
