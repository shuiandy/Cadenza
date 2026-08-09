import Foundation
import UserNotifications

extension Notification.Name {
    /// prep artifact 有写入(scheduler 自动/手动/MCP 外部)。UI 监听以刷新。
    static let cadenzaArtifactsChanged = Notification.Name("cadenzaArtifactsChanged")
}

/// Async 编排:对每场会 markStaleIfChanged → decide → `.generate` 走 single-flight 生成链
/// (acquireBuiltinSlot → fetchAIContext + build context → generate → commitBuiltin)。
/// 与 Phase 1 acquire/commit 的 generationID 语义对齐(见 `RecordingsStore+Artifacts.swift`):
/// 同一个 `g` 贯穿 acquire 与 commit,commit 内部以参数 generationID 为准匹配槽位。
@MainActor
final class MeetingPrepScheduler {
    private let store: RecordingsStore
    /// 会前提前量(分钟)。var:AppState 每次 tick 前从 UserDefaults `meetingPrepLeadMinutes` 刷新,
    /// 设置变更无需重启即生效。
    var leadMinutes: Int
    private let generatingTTL: TimeInterval
    private let generator = MeetingPrepGenerator()
    private var inFlight: Set<String> = []

    /// 测试注入:替换真实 provider 调用。返回 markdown 或 PrepGenerationError。
    var generateOverride: ((MeetingEvent, String) async -> Result<String, PrepGenerationError>)?
    /// 生成用 provider。每次生成时解析(与 PostProcessingCoordinator 每 job 读 `defaultAIProvider`
    /// 一致),Settings 切换 provider 后无需重启即生效。测试可注入固定值。
    var providerResolver: () -> AIProvider = {
        let raw = UserDefaults.standard.string(forKey: "defaultAIProvider") ?? AIProvider.apple.rawValue
        return AIProvider(rawValue: raw) ?? .apple
    }

    init(store: RecordingsStore, leadMinutes: Int = 30, generatingTTL: TimeInterval = 600) {
        self.store = store; self.leadMinutes = leadMinutes; self.generatingTTL = generatingTTL
    }

    nonisolated static func classify(_ error: PrepGenerationError) -> ArtifactErrorClass {
        switch error {
        case .noAPIKey: return .permanent
        case .provider(let e):
            let msg = (e as NSError).localizedDescription.lowercased()
            // 429/rate-limit 是瞬时限流 → retryable(靠 retryAfter 退避);
            // 只有明确的配额耗尽/账单类才 permanent(spec §5.1:配额=permanent)。
            if msg.contains("quota") || msg.contains("insufficient") || msg.contains("billing") { return .permanent }
            return .retryable
        }
    }

    func tick(events: [MeetingEvent], now: Date) async {
        for event in events {
            let fp = MeetingPrepFingerprint.compute(event)
            let slot = ArtifactTargetKey.slotKey(kind: "meetingPrep", targetType: "calendarEvent", targetKey: event.artifactTargetKey)
            let markedStale = await store.markStaleIfChanged(slotKey: slot, currentFingerprint: fp)  // badge for UI (both sources)
            if markedStale { NotificationCenter.default.post(name: .cadenzaArtifactsChanged, object: nil) }
            let existing = await store.fetchArtifact(slotKey: slot)
            let action = MeetingPrepScheduleDecision.decide(.init(
                event: event, existing: existing, currentFingerprint: fp, now: now,
                leadMinutes: leadMinutes, generatingTTL: generatingTTL))
            guard action == .generate, !inFlight.contains(slot) else { continue }
            inFlight.insert(slot)
            defer { inFlight.remove(slot) }
            await generateAndCommit(event: event, slot: slot, fingerprint: fp, now: now)
        }
    }

    private func generateAndCommit(event: MeetingEvent, slot: String, fingerprint: String, now: Date) async {
        let provider = providerResolver()  // 每次生成时解析,跟 Settings 实时一致
        let placeholder = ArtifactCandidate(kind: .meetingPrep, targetType: .calendarEvent,
            targetKey: event.artifactTargetKey, bodyMarkdown: "", provenanceSource: .builtin,
            provenanceDetail: provider.summaryModel, status: .generating, generationID: nil, generatingStartedAt: nil,
            errorClass: nil, errorMessage: nil, targetStartDate: event.startDate, targetEndDate: event.endDate,
            targetFingerprint: fingerprint, contextBuiltAt: now, staleReason: nil)
        let g = UUID()
        guard case .acquired = await store.acquireBuiltinSlot(slotKey: slot, placeholder: placeholder,
            newGenerationID: g, now: now, generatingTTL: generatingTTL) else { return }

        // build context — 装配逻辑(speaker-only 过滤/无参会人禁 excerpt/scoped 收窄)
        // 统一在 MeetingPrepContextBuilder.assemble,与 MCP get_meeting_context 共享。
        let contextText = await MeetingPrepContextBuilder.assemble(event: event, store: store)

        // generate (override in tests, else real provider)
        let result: Result<String, PrepGenerationError>
        if let ov = generateOverride { result = await ov(event, contextText) }
        else { result = await generator.generatePrep(contextText: contextText, provider: provider, model: nil) }

        switch result {
        case .success(let md):
            let committed = await store.commitBuiltin(ready(placeholder, body: md, fingerprint: fingerprint, now: now, generationID: g), generationID: g)
            if committed {
                NotificationCenter.default.post(name: .cadenzaArtifactsChanged, object: nil)
                sendPrepReadyNotification(for: event)
            }
        case .failure(let err):
            let cls = Self.classify(err)
            let committed = await store.commitBuiltin(failed(placeholder, cls: cls, message: "\(err)", now: now, generationID: g), generationID: g)
            if committed { NotificationCenter.default.post(name: .cadenzaArtifactsChanged, object: nil) }
        }
    }

    /// 手动「立即(重)生成」(UI 按钮):绕过 eligibility/lead-window/decision。
    /// out-of-band 生成 —— 期间不占槽(原 external/builtin 仍在位作 fallback);
    /// 仅成功才经 overrideWithBuiltin 原子替换;若期间 external 被 agent 重写则放弃
    /// (更新的 external 优先);失败槽位原样(spec §4.3/4.4)。
    func generateNow(event: MeetingEvent) async -> Bool {
        let fp = MeetingPrepFingerprint.compute(event)
        let slot = ArtifactTargetKey.slotKey(kind: "meetingPrep", targetType: "calendarEvent",
                                             targetKey: event.artifactTargetKey)
        guard !inFlight.contains(slot) else { return false }
        inFlight.insert(slot)
        defer { inFlight.remove(slot) }

        let prior = await store.fetchArtifact(slotKey: slot)
        let priorExternalUpdatedAt: Date? =
            prior?.provenanceSource == ArtifactProvenanceSource.external.rawValue ? prior?.updatedAt : nil

        let provider = providerResolver()
        let contextText = await MeetingPrepContextBuilder.assemble(event: event, store: store)
        let result: Result<String, PrepGenerationError>
        if let ov = generateOverride { result = await ov(event, contextText) }
        else { result = await generator.generatePrep(contextText: contextText, provider: provider, model: nil) }

        guard case .success(let md) = result else { return false }
        let now = Date()
        let candidate = ArtifactCandidate(kind: .meetingPrep, targetType: .calendarEvent,
            targetKey: event.artifactTargetKey, bodyMarkdown: md, provenanceSource: .builtin,
            provenanceDetail: provider.summaryModel, status: .ready, generationID: nil,
            generatingStartedAt: nil, errorClass: nil, errorMessage: nil,
            targetStartDate: event.startDate, targetEndDate: event.endDate,
            targetFingerprint: fp, contextBuiltAt: now, staleReason: nil)
        let ok = await store.overrideWithBuiltin(candidate, expectedPriorExternalUpdatedAt: priorExternalUpdatedAt)
        if ok { NotificationCenter.default.post(name: .cadenzaArtifactsChanged, object: nil) }
        return ok
    }

    /// 会前提醒(仅 auto 路径,见 tick → generateAndCommit)。manual generateNow 时用户已在看
    /// 卡片,MCP 写入是 agent 驱动、agent 会话本身就是 surface——两者都不发通知。
    /// 照 `AutoRecordScheduler.sendNotification` 先例,复用已有权限流(无新 request)。
    private func sendPrepReadyNotification(for event: MeetingEvent) {
        guard event.startDate > Date() else { return }   // 会已开始就不打扰
        let content = UNMutableNotificationContent()
        // Plain Strings on UNMutableNotificationContent — SwiftUI's Text localization
        // never sees these, so they need explicit lookup to reach the string catalog.
        content.title = String(localized: "Prep brief ready")
        content.body = String(localized: "Your prep for \"\(event.title)\" is ready to review.")
        content.sound = nil                               // 安静:会前不打铃
        let request = UNNotificationRequest(
            identifier: "prepReady-\(event.artifactTargetKey)",   // 同会去重(重生成替换而非叠加)
            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func ready(_ base: ArtifactCandidate, body: String, fingerprint: String, now: Date, generationID: UUID) -> ArtifactCandidate {
        var c = base; c.bodyMarkdown = body; c.status = .ready; c.staleReason = nil; c.contextBuiltAt = now
        c.generationID = generationID
        return c
    }
    private func failed(_ base: ArtifactCandidate, cls: ArtifactErrorClass, message: String, now: Date, generationID: UUID) -> ArtifactCandidate {
        var c = base; c.status = .failed; c.errorClass = cls; c.errorMessage = message
        c.retryAfter = (cls == .retryable) ? now.addingTimeInterval(300) : nil  // 5-min backoff; permanent skipped by decide regardless
        c.generationID = generationID
        return c
    }
}
