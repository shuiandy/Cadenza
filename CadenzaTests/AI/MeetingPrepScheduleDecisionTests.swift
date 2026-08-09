import Testing
import Foundation
@testable import Cadenza

@Suite("MeetingPrepScheduleDecision")
struct MeetingPrepScheduleDecisionTests {
    private let now = Date(timeIntervalSince1970: 10_000)
    private func ev(minsUntil: Int) -> MeetingEvent {
        MeetingEvent(id: "e", title: "Sync",
            startDate: now.addingTimeInterval(Double(minsUntil) * 60),
            endDate: now.addingTimeInterval(Double(minsUntil) * 60 + 3600),
            meetingURL: URL(string: "https://zoom.us/j/1"), meetingApp: .zoom, calendarName: "c",
            notes: nil, source: .apple, calendarID: "c",
            attendees: [EventAttendee(name: "D", email: "d@x.com", isOrganizer: true, status: .accepted)])
    }
    private func dto(source: String, status: String, fingerprint: String = "fp",
                     generatingStartedAt: Date? = nil, errorClass: String? = nil,
                     retryAfter: Date? = nil, stale: String? = nil) -> AgentArtifactDTO {
        AgentArtifactDTO(id: UUID(), slotKey: "s", bodyMarkdown: "b", provenanceSource: source,
            provenanceDetail: "d", status: status, generationID: nil, generatingStartedAt: generatingStartedAt,
            errorClass: errorClass, errorMessage: nil, retryAfter: retryAfter, targetFingerprint: fingerprint,
            staleReason: stale, updatedAt: now)
    }
    private func decide(event: MeetingEvent, existing: AgentArtifactDTO?, fp: String = "fp") -> PrepScheduleAction {
        MeetingPrepScheduleDecision.decide(.init(event: event, existing: existing, currentFingerprint: fp,
            now: now, leadMinutes: 30, generatingTTL: 600))
    }

    @Test func emptySlotWithinWindowGenerates() { #expect(decide(event: ev(minsUntil: 20), existing: nil) == .generate) }
    @Test func tooEarlySkips() { #expect(decide(event: ev(minsUntil: 120), existing: nil) == .skip) }
    @Test func alreadyStartedSkips() { #expect(decide(event: ev(minsUntil: -5), existing: nil) == .skip) }
    @Test func ineligibleSkips() {
        let solo = MeetingEvent(id: "e", title: "Focus", startDate: now.addingTimeInterval(600), endDate: now.addingTimeInterval(4200),
            meetingURL: nil, meetingApp: nil, calendarName: "c", notes: nil, source: .apple, calendarID: "c", attendees: [])
        #expect(decide(event: solo, existing: nil) == .skip)
    }
    @Test func externalNeverAutoGenerates() {
        #expect(decide(event: ev(minsUntil: 20), existing: dto(source: "external", status: "ready")) == .skip)
    }
    @Test func freshBuiltinReadySameFingerprintSkips() {
        #expect(decide(event: ev(minsUntil: 20), existing: dto(source: "builtin", status: "ready", fingerprint: "fp"), fp: "fp") == .skip)
    }
    @Test func staleBuiltinReadyRegenerates() {
        #expect(decide(event: ev(minsUntil: 20), existing: dto(source: "builtin", status: "ready", fingerprint: "old"), fp: "new") == .generate)
    }
    @Test func freshGeneratingSkips_expiredReclaims() {
        #expect(decide(event: ev(minsUntil: 20), existing: dto(source: "builtin", status: "generating", generatingStartedAt: now.addingTimeInterval(-60))) == .skip)
        #expect(decide(event: ev(minsUntil: 20), existing: dto(source: "builtin", status: "generating", generatingStartedAt: now.addingTimeInterval(-1200))) == .generate)
    }
    @Test func failedPermanentSkips_retryableDueGenerates() {
        #expect(decide(event: ev(minsUntil: 20), existing: dto(source: "builtin", status: "failed", errorClass: "permanent")) == .skip)
        #expect(decide(event: ev(minsUntil: 20), existing: dto(source: "builtin", status: "failed", errorClass: "retryable", retryAfter: now.addingTimeInterval(-10))) == .generate)
        #expect(decide(event: ev(minsUntil: 20), existing: dto(source: "builtin", status: "failed", errorClass: "retryable", retryAfter: now.addingTimeInterval(60))) == .skip)
    }
}
