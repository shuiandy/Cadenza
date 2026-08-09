import SwiftUI

/// EventDetailPopover 内的会前 Prep 卡片:读取/渲染 artifact,手动(重)生成。
///
/// Rendering note: the prep body reuses `MarkdownMessageView` (Chat) — its
/// initializer only takes a markdown string + font params, no chat-specific
/// state (streaming/session), so it drops in cleanly here and keeps the
/// project's font iron rule (body = `.cadenzaBody`) for free since that view
/// already renders paragraphs/headings with `.cadenzaBody` internally.
struct MeetingPrepSection: View {
    @Environment(\.uiScale) private var uiScale: CGFloat
    @Environment(AppState.self) private var appState
    let event: MeetingEvent

    @State private var artifact: AgentArtifactDTO?
    @State private var isGenerating = false
    @State private var lastError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            content
        }
        .task(id: event.id) { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .cadenzaArtifactsChanged)
            .receive(on: DispatchQueue.main)) { _ in
            Task { await refresh() }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.cadenza(12, scale: uiScale))
                .foregroundStyle(.secondary)
            Text("Prep")
                .font(.cadenza(14, weight: .semibold, scale: uiScale))
            if let a = artifact {
                sourceBadge(a)
                if a.staleReason != nil { staleBadge }
            }
            Spacer()
            if isGenerating {
                ProgressView().controlSize(.mini)
            } else {
                Button(artifact == nil ? "Generate" : "Regenerate") { regenerate() }
                    .font(.cadenza(12, weight: .medium, scale: uiScale))
                    .buttonStyle(.cadenzaPlain)
                    .foregroundStyle(.blue)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let error = lastError {
            Text(error)
                .font(.cadenza(12, scale: uiScale))
                .foregroundStyle(.red)
        }
        if let a = artifact {
            switch a.status {
            case "ready":
                prepBody(a.bodyMarkdown)
                Text("Updated \(a.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.cadenza(11, scale: uiScale))
                    .foregroundStyle(.tertiary)
            case "generating":
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Generating…")
                        .font(.cadenza(12, scale: uiScale))
                        .foregroundStyle(.secondary)
                }
            case "failed":
                Text(a.errorClass == "permanent"
                     ? "Generation failed — check your AI provider API key in Settings."
                     : "Generation failed — will retry automatically.")
                    .font(.cadenza(12, scale: uiScale))
                    .foregroundStyle(.secondary)
            default:
                EmptyView()
            }
        } else if !isGenerating, lastError == nil {
            Text("No prep brief yet.")
                .font(.cadenza(12, scale: uiScale))
                .foregroundStyle(.secondary)
        }
    }

    /// 正文:阅读型长正文 → 复用 `MarkdownMessageView`(内部已用 `cadenzaBody`,
    /// 满足 CLAUDE.md 字体铁律)。`compact: true` 收紧行距/列表缩进,适配 400pt 弹层宽度。
    private func prepBody(_ markdown: String) -> some View {
        MarkdownMessageView(markdown, fontSize: 13, uiScale: uiScale, compact: true)
            .textSelection(.enabled)
    }

    private func sourceBadge(_ a: AgentArtifactDTO) -> some View {
        Text(
            a.provenanceSource == "external"
                ? String(localized: "Agent")
                : String(localized: "Automatic")
        )
            .font(.cadenza(11, scale: uiScale))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background((a.provenanceSource == "external" ? Color.purple : Color.blue).opacity(0.15),
                        in: Capsule())
            .foregroundStyle(a.provenanceSource == "external" ? .purple : .blue)
    }

    private var staleBadge: some View {
        Text("outdated")
            .font(.cadenza(11, scale: uiScale))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.orange.opacity(0.15), in: Capsule())
            .foregroundStyle(.orange)
    }

    private func refresh() async {
        artifact = await appState.fetchMeetingPrep(event: event)
    }

    private func regenerate() {
        isGenerating = true
        lastError = nil
        Task {
            let ok = await appState.generateMeetingPrepNow(event: event)
            isGenerating = false
            if !ok {
                // Plain String, not a SwiftUI Text literal — needs explicit lookup to localize.
                lastError = String(localized: "Couldn't generate — check AI provider settings, or a newer agent brief arrived.")
            }
            await refresh()
        }
    }
}

/// Preview helper: `AppState()` leaves `store` unset (implicitly-unwrapped nil),
/// which would crash this view's `.task` (it calls `appState.fetchMeetingPrep` →
/// `store.fetchArtifact`). Previews instead get a real in-memory `RecordingsStore`
/// (same `makeContainer(inMemory:)` path used by tests/TestHost) pre-seeded with
/// an `AgentArtifact` row so each state renders realistically.
@MainActor
private func previewAppState(seed: ((RecordingsStore) async -> Void)? = nil) -> AppState {
    let state = AppState()
    let container = try! RecordingsStore.makeContainer(inMemory: true)
    let store = RecordingsStore(modelContainer: container)
    state.store = store
    if let seed {
        Task { await seed(store) }
    }
    return state
}

private func previewEvent(id: String) -> MeetingEvent {
    MeetingEvent(
        id: id,
        title: "Weekly Standup",
        startDate: Date(),
        endDate: Date().addingTimeInterval(3600),
        meetingURL: URL(string: "https://zoom.us/j/123"),
        meetingApp: .zoom,
        calendarName: "Work",
        notes: nil
    )
}

#Preview("Ready · external · stale") {
    let event = previewEvent(id: "preview-ready")
    MeetingPrepSection(event: event)
        .environment(previewAppState { store in
            let candidate = ArtifactCandidate(
                kind: .meetingPrep, targetType: .calendarEvent, targetKey: event.artifactTargetKey,
                bodyMarkdown: """
                # Context
                Last sync 2 weeks ago covered Q3 roadmap.

                # Suggested talking points
                - Follow up on the API migration timeline
                - Confirm owner for the design review
                """,
                provenanceSource: .external, provenanceDetail: "agent:claude-code",
                status: .ready, generationID: nil, generatingStartedAt: nil,
                errorClass: nil, errorMessage: nil,
                targetStartDate: event.startDate, targetEndDate: event.endDate,
                targetFingerprint: "stale-fingerprint", contextBuiltAt: Date(),
                staleReason: "eventChanged")
            _ = await store.writeExternalArtifact(candidate)
        })
        .padding(16)
        .frame(width: 320)
}

#Preview("Generating") {
    let event = previewEvent(id: "preview-generating")
    MeetingPrepSection(event: event)
        .environment(previewAppState { store in
            let candidate = ArtifactCandidate(
                kind: .meetingPrep, targetType: .calendarEvent, targetKey: event.artifactTargetKey,
                bodyMarkdown: "", provenanceSource: .builtin, provenanceDetail: "gemini-2.5-flash",
                status: .generating, generationID: UUID(), generatingStartedAt: Date(),
                errorClass: nil, errorMessage: nil,
                targetStartDate: event.startDate, targetEndDate: event.endDate,
                targetFingerprint: "fp", contextBuiltAt: Date(), staleReason: nil)
            _ = await store.writeExternalArtifact(candidate)
        })
        .padding(16)
        .frame(width: 320)
}

#Preview("Failed · permanent") {
    let event = previewEvent(id: "preview-failed")
    MeetingPrepSection(event: event)
        .environment(previewAppState { store in
            let candidate = ArtifactCandidate(
                kind: .meetingPrep, targetType: .calendarEvent, targetKey: event.artifactTargetKey,
                bodyMarkdown: "", provenanceSource: .builtin, provenanceDetail: "gemini-2.5-flash",
                status: .failed, generationID: UUID(), generatingStartedAt: nil,
                errorClass: .permanent, errorMessage: "no API key configured",
                targetStartDate: event.startDate, targetEndDate: event.endDate,
                targetFingerprint: "fp", contextBuiltAt: Date(), staleReason: nil)
            _ = await store.writeExternalArtifact(candidate)
        })
        .padding(16)
        .frame(width: 320)
}

#Preview("No prep yet") {
    MeetingPrepSection(event: previewEvent(id: "preview-empty"))
        .environment(previewAppState())
        .padding(16)
        .frame(width: 320)
}
