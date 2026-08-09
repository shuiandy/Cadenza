import SwiftUI

struct RecapsListView: View {
    @Environment(\.uiScale) private var uiScale: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Environment(AppState.self) private var appState
    @AppStorage(AutomaticRecapGeneration.defaultsKey) private var automaticRecapsEnabled = false
    @State private var filter: RecapFilter = .all

    private enum RecapFilter: String, CaseIterable {
        case all = "All"
        case weekly = "Weekly"
        case monthly = "Monthly"

        var localizedName: String {
            switch self {
            case .all: String(localized: "All")
            case .weekly: String(localized: "Weekly")
            case .monthly: String(localized: "Monthly")
            }
        }
    }

    private var filteredRecaps: [RecapDTO] {
        switch filter {
        case .all: appState.recaps
        case .weekly: appState.recaps.filter { $0.period == "weekly" }
        case .monthly: appState.recaps.filter { $0.period == "monthly" }
        }
    }

    static func recordingCountText(
        _ count: Int,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        if count == 1 {
            return String(
                localized: "\(count) recording",
                bundle: LocalizedBundle.bundle(for: locale),
                locale: locale
            )
        }
        return String(
            localized: "\(count) recordings",
            bundle: LocalizedBundle.bundle(for: locale),
            locale: locale
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Recaps")
                    .font(.cadenza(.title, weight: .semibold, scale: uiScale))

                // Filter tabs
                HStack(spacing: 0) {
                    ForEach(RecapFilter.allCases, id: \.self) { tab in
                        Button {
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { filter = tab }
                        } label: {
                            Text(tab.localizedName)
                                .font(.cadenza(13, weight: .medium, scale: uiScale))
                                .foregroundStyle(filter == tab ? .primary : .secondary)
                                .padding(.vertical, 6)
                                .padding(.horizontal, 14)
                        }
                        .buttonStyle(.cadenzaPlain)
                    }
                }
                .cadenzaGlass(in: Capsule(), interactive: true)

                if filteredRecaps.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "calendar.badge.clock")
                            .font(.cadenza(40, scale: uiScale))
                            .foregroundStyle(.tertiary)
                        Text("No recaps yet")
                            .font(.cadenza(.headline, scale: uiScale))
                            .foregroundStyle(.secondary)
                        Group {
                            if automaticRecapsEnabled {
                                Text("Recaps are generated automatically at the start of each week and month.")
                            } else {
                                Text("Automatic recaps are off. Enable them in Settings → Transcription → Summary & AI.")
                            }
                        }
                        .font(.cadenza(.subheadline, scale: uiScale))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 300)

                        if !automaticRecapsEnabled {
                            Button("Open Recap Settings") {
                                appState.openSettings(category: .transcription)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 60)
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(filteredRecaps) { recap in
                            Button {
                                appState.present(.recapDetail(recap.id))
                            } label: {
                                RecapCardView(recap: recap)
                            }
                            .buttonStyle(.cadenzaPlain)
                            .accessibilityLabel(Text(recap.title))
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

// MARK: - Recap Card

private struct RecapCardView: View {
    @Environment(\.uiScale) private var uiScale: CGFloat
    @Environment(\.locale) private var locale

    let recap: RecapDTO
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(recap.period.uppercased())
                .font(.cadenza(11, weight: .bold, scale: uiScale))
                .foregroundStyle(recap.period == "monthly" ? .orange : .accentColor)

            Text(recap.title)
                .font(.cadenza(15, weight: .semibold, scale: uiScale))
                .lineLimit(2)

            if !recap.overview.isEmpty {
                Text(recap.overview)
                    .font(.cadenza(13, scale: uiScale))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: 12) {
                Label(dateRangeString, systemImage: "calendar")
                Label(
                    RecapsListView.recordingCountText(recap.stats.meetingCount, locale: locale),
                    systemImage: "waveform"
                )
            }
            .font(.cadenza(12, scale: uiScale))
            .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appCard(cornerRadius: AppStyle.Radius.card, hovered: isHovered)
        .onHover { isHovered = $0 }
    }

    private var dateRangeString: String {
        LocalizedDateFormatting.interval(
            from: recap.startDate,
            to: recap.endDate.addingTimeInterval(-1),
            dateStyle: .medium,
            timeStyle: .none,
            locale: locale
        )
    }
}
