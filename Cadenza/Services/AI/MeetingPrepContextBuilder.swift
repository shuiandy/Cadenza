import Foundation

/// 纯函数:把一场会的 MeetingEvent + 历史(AIContextData)+ 项目记忆(FolderContextDTO)
/// 格式化成给 prep 生成器的 context 文本。无 store / 无网络,便于单测。
enum MeetingPrepContextBuilder {
    static func build(event: MeetingEvent,
                      aiContext: AIContextData?,
                      folderContext: FolderContextDTO?) -> String {
        var lines: [String] = []

        // --- Meeting header ---
        lines.append("# Meeting: \(event.title)")
        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .short
        lines.append("When: \(df.string(from: event.startDate)) - \(df.string(from: event.endDate))")
        if let url = event.meetingURL { lines.append("Link: \(url.absoluteString)") }
        if let rsvp = event.myResponseStatus { lines.append("Your RSVP: \(rsvp.rawValue)") }
        if let notes = event.notes, !notes.isEmpty { lines.append("Notes: \(notes)") }
        if !event.attendees.isEmpty {
            lines.append("Attendees:")
            for a in event.attendees {
                let tags = [a.isOrganizer ? "organizer" : nil, a.isCurrentUser ? "you" : nil]
                    .compactMap { $0 }.joined(separator: ", ")
                let suffix = tags.isEmpty ? "" : " (\(tags))"
                lines.append("- \(a.name) <\(a.email)>\(suffix) — RSVP \(a.status.rawValue)")
            }
        }

        // --- Recent related meetings (last touch) ---
        if let ctx = aiContext, !ctx.summaries.isEmpty {
            lines.append("")
            lines.append("## Recent related meetings")
            for s in ctx.summaries.prefix(5) {
                lines.append("- \(s.title): \(s.summary ?? "(no summary)")")
            }
        }

        // --- Open action items (incomplete only) ---
        let openItems = (aiContext?.actionItems ?? []).filter { !$0.isCompleted }
        if !openItems.isEmpty {
            lines.append("")
            lines.append("## Open action items")
            for i in openItems.prefix(15) {
                let who = i.assignee.map { " [@\($0)]" } ?? ""
                lines.append("- \(i.text)\(who)")
            }
        }

        // --- Project memory ---
        if let f = folderContext {
            lines.append("")
            lines.append("## Project: \(f.folderName) (\(f.folderStatus), \(f.totalRecordingCount) recordings)")
            for m in f.recentMeetings.prefix(3) where !m.overview.isEmpty {
                lines.append("- \(m.title): \(m.overview)")
            }
            for fu in f.followUps.prefix(5) {
                lines.append("- follow-up: \(fu.text)")
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Scoping

    /// 把全库范围的 AIContextData 收窄到与这场会真正相关的 recordings,防止无关会议的
    /// 摘要/待办进入 prep prompt(隐私 + 相关性)。`fetchAIContext` 只在 transcript excerpt
    /// 层按 参会人名/标题关键词 过滤,summaries/actionItems 仍来自最近全库 —— 必须在此收窄。
    /// 相关判定(任一):
    /// - recording 有 excerpt 命中(即 参会人在该录音中说话);
    /// - recording 标题与会议标题相似(token 级 Jaccard,见 `titleSimilar`)。
    /// 无相关 recording → 各段为空,prep 退化为只基于事件本身(隐私优先的正确行为)。
    static func scoped(_ ctx: AIContextData, eventTitle: String) -> AIContextData {
        let hitIDs = Set(ctx.transcriptExcerpts.map(\.recordingID))
        let titleIDs = Set(ctx.summaries.filter { titleSimilar($0.title, eventTitle) }.map(\.recordingID))
        let relevant = hitIDs.union(titleIDs)
        return AIContextData(
            summaries: ctx.summaries.filter { relevant.contains($0.recordingID) },
            actionItems: ctx.actionItems.filter { relevant.contains($0.recordingID) },
            decisions: ctx.decisions.filter { relevant.contains($0.recordingID) },
            followUps: ctx.followUps.filter { relevant.contains($0.recordingID) },
            transcriptExcerpts: ctx.transcriptExcerpts,
            transcriptCoverage: ctx.transcriptCoverage,
            speakers: ctx.speakers)
    }

    /// 标题相似:规范化后完全相等,或 token 集 Jaccard ≥ 0.6。
    /// 词级匹配避免子串误伤("AI" 不匹配 "D[ai]ly Standup","Sync" 不匹配 "Security Sync")。
    /// CJK 标题无空格分词时整题作单 token → 退化为完全相等;其相关性由 excerpt 命中
    /// (参会人说话)路径兜底,漏配优于误伤(隐私优先)。
    static func titleSimilar(_ a: String, _ b: String) -> Bool {
        let na = normalizeTitle(a), nb = normalizeTitle(b)
        guard !na.isEmpty, !nb.isEmpty else { return false }
        if na == nb { return true }
        let ta = tokens(na), tb = tokens(nb)
        guard !ta.isEmpty, !tb.isEmpty else { return false }
        let inter = ta.intersection(tb).count
        guard inter > 0 else { return false }
        return Double(inter) / Double(ta.union(tb).count) >= 0.6
    }

    private static func normalizeTitle(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func tokens(_ s: String) -> Set<String> {
        Set(s.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
    }

    /// Personal summaries require explicit selection rather than title/speaker inference.
    /// Both context products keep their scoping at this shared boundary; the stricter
    /// selection never broadens the existing MCP meeting-context permission.
    static func confirmedHistory(store: RecordingsStore, ids: [UUID], currentID: UUID, before: Date) async -> [RecordingDetailDTO] {
        guard case .history(let rows) = await retrieve(.confirmed(ids: ids, currentID: currentID, before: before), store: store) else { return [] }
        return rows
    }

    // MARK: - Assembly (shared by scheduler + MCP)

    /// 装配一场会的完整 prep context(事件头 + scoped 历史)。内置 scheduler 与 MCP
    /// get_meeting_context 共用此入口,保证两条路径喂的料一致(spec §6)。
    /// 内含三条已评审的红线,勿在调用方各自实现:
    /// - excerpt 过滤只按参会人(speaker+keyword 是 AND 语义,同传会滤没);
    /// - 无其他参会人时禁用 excerpt 路径(speakerQueries=nil 是「不过滤」→ 全库泄露);
    /// - 全库 summaries/actionItems 必须经 scoped() 收窄;
    /// - 多参会人必须用 `.any` 匹配:默认的 `.all` 要求所有参会人曾在同一场历史录音
    ///   共同出现,3 人以上的会几乎永不成立,prep 历史会静默变空;
    /// - **两路候选必须都取**:speaker 路只召回参会人开过口的录音,而 store 的 recording
    ///   级过滤会把其余录音连 summary 一起删掉,`scoped()` 的标题兜底就再也看不到它们。
    ///   往届同名会议若还没做说话人识别(逐字稿仍是 `Speaker 1`)、或刚被重新转录清空
    ///   映射,就会整场丢失 —— 标题候选必须走一条不带 speaker 过滤的独立查询。
    static func assemble(event: MeetingEvent, store: RecordingsStore) async -> String {
        guard case .prep(let context) = await retrieve(.event(event), store: store) else {
            return build(event: event, aiContext: nil, folderContext: nil)
        }
        return build(event: event, aiContext: context, folderContext: nil)
    }

    private enum Selection {
        case event(MeetingEvent)
        case confirmed(ids: [UUID], currentID: UUID, before: Date)
    }
    private enum RetrievedContext {
        case prep(AIContextData)
        case history([RecordingDetailDTO])
    }
    /// A shared structured retrieval boundary with explicit, non-interchangeable scope policies.
    private static func retrieve(_ selection: Selection, store: RecordingsStore) async -> RetrievedContext {
        switch selection {
        case .confirmed(let ids, let currentID, let before):
            return .history(await store.fetchConfirmedSummaryHistory(ids: ids, currentID: currentID, before: before))
        case .event(let event):
            let names = event.attendees.filter { !$0.isCurrentUser }
                .map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            // Metadata-only title fallback and attendee-based excerpt lookup preserve
            // the existing prep/MCP scope; confirmed history never uses this inference.
            let titleCandidates = await store.fetchAIContext(maxTranscriptEntries: 0)
            guard !names.isEmpty else { return .prep(scoped(titleCandidates, eventTitle: event.title)) }
            let speakerHits = await store.fetchAIContext(speakerQueries: names, speakerMatchMode: .any)
            return .prep(scoped(merge(speakerHits, titleCandidates), eventTitle: event.title))
        }
    }

    /// 合并两路候选(按 recordingID 去重,`primary` 优先)。excerpts/coverage/speakers 只取
    /// `primary` —— `secondary` 是刻意不带 excerpt 的 metadata-only 查询。
    ///
    /// **必须按时间重排**:`build()` 对 summaries 取 `prefix(5)`、action items 取
    /// `prefix(15)`,若简单拼接则 primary 的旧命中会占满配额,把更新的标题候选挤出
    /// prompt —— 那正是这次修复要救的那条录音。重排后两路按同一条时间轴竞争。
    static func merge(_ primary: AIContextData, _ secondary: AIContextData) -> AIContextData {
        let seen = Set(primary.summaries.map(\.recordingID))
        let extraIDs = Set(secondary.summaries.map(\.recordingID)).subtracting(seen)
        let summaries = (primary.summaries + secondary.summaries.filter { extraIDs.contains($0.recordingID) })
            .sorted { $0.startDate > $1.startDate }
        // action items / decisions / follow-ups 没有自己的时间戳,按所属 recording 的
        // 时间排(缺失的排到最后),保持与 summaries 一致的新→旧顺序。
        let startByID = Dictionary(summaries.map { ($0.recordingID, $0.startDate) },
                                   uniquingKeysWith: { a, _ in a })
        func byRecordingDate<T>(_ items: [T], _ id: (T) -> UUID) -> [T] {
            items.sorted { (startByID[id($0)] ?? .distantPast) > (startByID[id($1)] ?? .distantPast) }
        }
        return AIContextData(
            summaries: summaries,
            actionItems: byRecordingDate(
                primary.actionItems + secondary.actionItems.filter { extraIDs.contains($0.recordingID) },
                \.recordingID),
            decisions: byRecordingDate(
                primary.decisions + secondary.decisions.filter { extraIDs.contains($0.recordingID) },
                \.recordingID),
            followUps: byRecordingDate(
                primary.followUps + secondary.followUps.filter { extraIDs.contains($0.recordingID) },
                \.recordingID),
            transcriptExcerpts: primary.transcriptExcerpts,
            transcriptCoverage: primary.transcriptCoverage,
            speakers: primary.speakers)
    }
}
