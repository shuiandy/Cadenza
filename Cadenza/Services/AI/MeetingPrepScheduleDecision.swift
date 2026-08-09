import Foundation

enum PrepScheduleAction: Equatable, Sendable { case skip, generate }

struct PrepDecisionInput: Sendable {
    let event: MeetingEvent
    let existing: AgentArtifactDTO?
    let currentFingerprint: String
    let now: Date
    let leadMinutes: Int
    let generatingTTL: TimeInterval
}

/// 纯状态机:决定这场会本 tick 是否要(重)生成 prep。与 Phase 1 acquire 谓词保持一致。
enum MeetingPrepScheduleDecision {
    static func decide(_ i: PrepDecisionInput) -> PrepScheduleAction {
        guard MeetingPrepEligibility.isEligible(i.event) else { return .skip }
        let minsUntil = Int(i.event.startDate.timeIntervalSince(i.now) / 60)
        guard minsUntil >= 0, minsUntil <= i.leadMinutes else { return .skip }

        guard let a = i.existing else { return .generate }             // empty
        if a.provenanceSource == "external" { return .skip }           // external: 不 auto 覆盖

        switch a.status {
        case "ready":
            return a.targetFingerprint != i.currentFingerprint ? .generate : .skip
        case "generating":
            if let s = a.generatingStartedAt, i.now.timeIntervalSince(s) > i.generatingTTL { return .generate }
            return .skip
        case "failed":
            let retryable = a.errorClass == "retryable"
            let due = a.retryAfter.map { i.now >= $0 } ?? true
            return retryable && due ? .generate : .skip
        default:
            return .generate                                            // idle
        }
    }
}
