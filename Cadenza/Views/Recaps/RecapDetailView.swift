import SwiftUI

struct RecapDetailView: View {
    @Environment(\.uiScale) private var uiScale: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale

    let recapID: UUID
    @Environment(AppState.self) private var appState
    @State private var selectedTab = 0

    private var recap: RecapDTO? {
        appState.recaps.first(where: { $0.id == recapID })
    }

    var body: some View {
        if let recap {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Header
                    VStack(alignment: .leading, spacing: 4) {
                        Text(recap.period.uppercased())
                            .font(.cadenza(12, weight: .bold, scale: uiScale))
                            .foregroundStyle(recap.period == "monthly" ? .orange : .accentColor)
                        Text(recap.title)
                            .font(.cadenza(.title2, weight: .bold, scale: uiScale))
                    }

                    // Stats bar
                    statsBar(recap.stats)

                    Divider()

                    // Tab bar
                    tabBar

                    // Content
                    Group {
                        switch selectedTab {
                        case 0: summaryTab(recap)
                        case 1: recordingsTab(recap)
                        case 2: actionItemsTab(recap)
                        case 3: decisionsTab(recap)
                        default: EmptyView()
                        }
                    }
                    .transition(reduceMotion ? .identity : .opacity)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        } else {
            VStack {
                Spacer()
                Text("Recap not found")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Stats Bar

    private func statsBar(_ stats: RecapStats) -> some View {
        HStack(spacing: 0) {
            statItem(value: "\(stats.meetingCount)", label: "Meetings", icon: "waveform")
            Divider().frame(height: 32)
            statItem(value: formatDuration(stats.totalDuration), label: "Duration", icon: "clock")
            Divider().frame(height: 32)
            statItem(value: "\(stats.actionItemCount)", label: "Action Items", icon: "checklist")
            Divider().frame(height: 32)
            statItem(value: "\(stats.decisionCount)", label: "Decisions", icon: "lightbulb")
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .appGlassPanel(cornerRadius: 12)
    }

    private func statItem(value: String, label: LocalizedStringKey, icon: String) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.cadenza(12, scale: uiScale))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.cadenza(18, weight: .bold, design: .rounded, scale: uiScale))
            }
            Text(label)
                .font(.cadenza(11, scale: uiScale))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            tabButton("Summary", icon: "text.quote", index: 0)
            tabButton("Recordings", icon: "waveform", index: 1)
            tabButton("Action Items", icon: "checklist", index: 2)
            tabButton("Decisions", icon: "lightbulb", index: 3)
        }
    }

    private func tabButton(_ title: LocalizedStringKey, icon: String, index: Int) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .spring(duration: 0.25, bounce: 0.15)) {
                selectedTab = index
            }
        } label: {
            VStack(spacing: 4) {
                HStack(spacing: 5) {
                    Image(systemName: icon)
                        .font(.cadenza(13, scale: uiScale))
                    Text(title)
                        .font(.cadenza(13, weight: .medium, scale: uiScale))
                }
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity)
                .foregroundStyle(selectedTab == index ? .primary : .secondary)
                .contentShape(Rectangle())

                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.accentColor)
                    .frame(height: 2)
                    .opacity(selectedTab == index ? 1 : 0)
            }
        }
        .buttonStyle(.cadenzaPlain)
    }

    // MARK: - Summary Tab

    @ViewBuilder
    private func summaryTab(_ recap: RecapDTO) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if !recap.overview.isEmpty {
                Text(recap.overview)
                    .font(.cadenzaBody(14, scale: uiScale))
                    .lineSpacing(4)
            }

            ForEach(recap.sections) { section in
                VStack(alignment: .leading, spacing: 6) {
                    Text(section.category)
                        .font(.cadenza(14, weight: .semibold, scale: uiScale))

                    Text(section.summary)
                        .font(.cadenzaBody(13, scale: uiScale))
                        .foregroundStyle(.secondary)
                        .lineSpacing(3)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .appGlassPanel(cornerRadius: 10)
            }
        }
    }

    // MARK: - Recordings Tab

    @ViewBuilder
    private func recordingsTab(_ recap: RecapDTO) -> some View {
        let matchedRecordings = appState.recordings.filter { recap.recordingIDs.contains($0.id) }
        if matchedRecordings.isEmpty {
            Text("No recordings found")
                .foregroundStyle(.secondary)
                .padding(.vertical, 20)
        } else {
            LazyVStack(spacing: 8) {
                ForEach(matchedRecordings) { recording in
                    Button {
                        appState.openRecordingDetail(recordingID: recording.id, title: recording.title)
                    } label: {
                        recapRecordingRow(recording)
                    }
                    .buttonStyle(.cadenzaPlain)
                    .accessibilityLabel(Text(recording.title))
                }
            }
        }
    }

    private func recapRecordingRow(_ recording: RecordingDTO) -> some View {
        let iconFrame = CadenzaControlMetrics.squareIconFrame(
            base: 34,
            symbolPointSize: 14,
            scale: uiScale,
            padding: 2
        )
        return HStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.cadenza(14, scale: uiScale))
                .frame(width: iconFrame, height: iconFrame)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(recording.title)
                    .font(.cadenza(14, weight: .medium, scale: uiScale))
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(formatRecordingDate(recording.startDate))
                    Text(formatRecordingDuration(recording.duration))
                }
                .font(.cadenza(12, scale: uiScale))
                .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.cadenza(.caption, scale: uiScale))
                .foregroundStyle(.tertiary)
        }
        .padding(10)
        .contentShape(Rectangle())
    }

    // MARK: - Action Items Tab

    @ViewBuilder
    private func actionItemsTab(_ recap: RecapDTO) -> some View {
        if recap.allActionItems.isEmpty {
            Text("No action items")
                .foregroundStyle(.secondary)
                .padding(.vertical, 20)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(recap.allActionItems.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "circle")
                            .font(.cadenza(10, scale: uiScale))
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                        Text(item)
                            .font(.cadenzaBody(13, scale: uiScale))
                            .lineSpacing(3)
                    }
                    .padding(.vertical, 8)

                    if index < recap.allActionItems.count - 1 {
                        Divider()
                    }
                }
            }
        }
    }

    // MARK: - Decisions Tab

    @ViewBuilder
    private func decisionsTab(_ recap: RecapDTO) -> some View {
        if recap.allDecisions.isEmpty {
            Text("No decisions recorded")
                .foregroundStyle(.secondary)
                .padding(.vertical, 20)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(recap.allDecisions.enumerated()), id: \.offset) { index, decision in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "lightbulb.fill")
                            .font(.cadenza(11, scale: uiScale))
                            .foregroundStyle(.orange)
                            .padding(.top, 3)
                        Text(decision)
                            .font(.cadenzaBody(13, scale: uiScale))
                            .lineSpacing(3)
                    }
                    .padding(.vertical, 8)

                    if index < recap.allDecisions.count - 1 {
                        Divider()
                    }
                }
            }
        }
    }

    // MARK: - Formatters

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    private func formatRecordingDate(_ date: Date) -> String {
        LocalizedDateFormatting.string(
            from: date,
            style: .dateTime.month(.abbreviated).day()
                .hour(.defaultDigits(amPM: .abbreviated)).minute(),
            locale: locale
        )
    }

    private func formatRecordingDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        if minutes < 1 { return "<1m" }
        return "\(minutes)m"
    }
}
