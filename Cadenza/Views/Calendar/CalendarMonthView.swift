import SwiftUI

struct CalendarMonthView: View {
    @Environment(\.uiScale) private var uiScale: CGFloat
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.locale) private var locale

    @Binding var selectedDate: Date
    let events: [MeetingEvent]
    @Binding var viewMode: CalendarViewMode
    var onEventTap: (MeetingEvent) -> Void = { _ in }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)

    private var weekdaySymbols: [String] {
        var calendar = Calendar.autoupdatingCurrent
        calendar.locale = locale
        return calendar.shortWeekdaySymbols
    }

    var body: some View {
        if CalendarAdaptiveLayoutPolicy.mode(
            for: dynamicTypeSize,
            effectiveScale: uiScale
        ) == .agenda {
            accessibleMonthAgenda
        } else {
            monthGrid
        }
    }

    private var monthGrid: some View {
        VStack(spacing: 0) {
            // Weekday headers
            HStack(spacing: 0) {
                ForEach(weekdaySymbols, id: \.self) { symbol in
                    Text(symbol.uppercased(with: locale))
                        .font(.cadenza(11, weight: .semibold, scale: uiScale))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 8)

            Divider()

            // Day grid
            LazyVGrid(columns: columns, spacing: 0) {
                ForEach(monthDays, id: \.self) { date in
                    let selected = Calendar.current.isDate(date, inSameDayAs: selectedDate)
                    Button {
                        selectedDate = date
                    } label: {
                        DayCell(
                            date: date,
                            isCurrentMonth: isCurrentMonth(date),
                            isToday: Calendar.current.isDateInToday(date),
                            isSelected: selected,
                            eventCount: eventsForDay(date).count,
                            hasRecordable: eventsForDay(date).contains { $0.meetingApp != nil }
                        )
                    }
                    .buttonStyle(.cadenzaPlain)
                    .onKeyPress(.return) {
                        openDay(date)
                        return .handled
                    }
                    .onKeyPress(.space) {
                        openDay(date)
                        return .handled
                    }
                    .accessibilityLabel(Text(LocalizedDateFormatting.string(
                        from: date,
                        style: .dateTime.weekday(.wide).year().month(.wide).day(),
                        locale: locale
                    )))
                    .accessibilityValue(selected ? Text("Selected") : Text("Not selected"))
                    .accessibilityHint("Open the day view.")
                    .accessibilityAction(.default) { openDay(date) }
                    .accessibilityAction(named: Text("Open Day")) { openDay(date) }
                }
            }

            Divider()

            // Selected day event list
            selectedDayEventList
        }
    }

    // MARK: - Selected day event list

    @ViewBuilder
    private var selectedDayEventList: some View {
        let dayEvents = eventsForDay(selectedDate).sorted { $0.startDate < $1.startDate }

        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(selectedDayTitle)
                    .font(.cadenza(15, weight: .semibold, scale: uiScale))
                Spacer()
                Text(Self.eventCountText(dayEvents.count, locale: locale))
                    .font(.cadenza(12, scale: uiScale))
                    .foregroundStyle(.secondary)
                Button("Open Day") {
                    openDay(selectedDate)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            if dayEvents.isEmpty {
                Text("No events")
                    .font(.cadenza(13, scale: uiScale))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                List {
                    ForEach(dayEvents) { event in
                        Button {
                            onEventTap(event)
                        } label: {
                            MonthEventRow(event: event)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.cadenzaPlain)
                        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private var selectedDayTitle: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(selectedDate) {
            return LocalizedBundle.string("Today", locale: locale)
        } else if calendar.isDateInYesterday(selectedDate) {
            return LocalizedBundle.string("Yesterday", locale: locale)
        } else if calendar.isDateInTomorrow(selectedDate) {
            return LocalizedBundle.string("Tomorrow", locale: locale)
        }
        return LocalizedDateFormatting.string(
            from: selectedDate,
            style: .dateTime.weekday(.abbreviated).month(.abbreviated).day(),
            locale: locale
        )
    }

    static func eventCountText(
        _ count: Int,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        if count == 1 {
            return String(
                localized: "\(count) event",
                bundle: LocalizedBundle.bundle(for: locale),
                locale: locale
            )
        }
        return String(
            localized: "\(count) events",
            bundle: LocalizedBundle.bundle(for: locale),
            locale: locale
        )
    }

    // MARK: - Helpers

    private var monthDays: [Date] {
        let calendar = Calendar.current
        guard let monthInterval = calendar.dateInterval(of: .month, for: selectedDate) else { return [] }

        let monthStart = monthInterval.start
        let weekday = calendar.component(.weekday, from: monthStart)
        let offset = weekday - calendar.firstWeekday
        let adjustedOffset = offset < 0 ? offset + 7 : offset

        guard let gridStart = calendar.date(byAdding: .day, value: -adjustedOffset, to: monthStart) else { return [] }

        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: gridStart) }
    }

    private func isCurrentMonth(_ date: Date) -> Bool {
        let calendar = Calendar.current
        return calendar.component(.month, from: date) == calendar.component(.month, from: selectedDate)
    }

    private func eventsForDay(_ date: Date) -> [MeetingEvent] {
        let calendar = Calendar.current
        return events.filter { calendar.isDate($0.startDate, inSameDayAs: date) }
    }

    private var accessibleMonthAgenda: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(monthDays.filter(isCurrentMonth), id: \.self) { date in
                    let dayEvents = eventsForDay(date)
                    Button {
                        openDay(date)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(LocalizedDateFormatting.string(
                                from: date,
                                style: .dateTime.weekday(.wide).month(.wide).day(),
                                locale: locale
                            ))
                                .font(.cadenza(.body, weight: .semibold, scale: uiScale))
                                .fixedSize(horizontal: false, vertical: true)
                            Text(Self.eventCountText(dayEvents.count, locale: locale))
                                .font(.cadenza(.caption, scale: uiScale))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.cadenzaPlain)
                    .accessibilityHint("Open the day view.")

                    Divider()
                }
            }
        }
    }

    private func openDay(_ date: Date) {
        selectedDate = date
        viewMode = .day
    }
}

// MARK: - Event row for month list

private struct MonthEventRow: View {
    @Environment(\.uiScale) private var uiScale: CGFloat
    @Environment(\.locale) private var locale

    let event: MeetingEvent

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(eventColor)
                .frame(width: 4, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.cadenza(13, weight: .medium, scale: uiScale))
                    .lineLimit(1)

                Text(timeString)
                    .font(.cadenza(12, scale: uiScale))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let app = event.meetingApp {
                Label(app.displayName, systemImage: "video")
                    .font(.cadenza(11, scale: uiScale))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var eventColor: Color {
        event.displayColor
    }

    private var timeString: String {
        if event.isAllDay { return LocalizedBundle.string("All Day", locale: locale) }
        return LocalizedDateFormatting.interval(
            from: event.startDate,
            to: event.endDate,
            dateStyle: .none,
            timeStyle: .short,
            locale: locale
        )
    }
}

// MARK: - Day Cell

private struct DayCell: View {
    @Environment(\.uiScale) private var uiScale: CGFloat
    @Environment(\.locale) private var locale

    let date: Date
    let isCurrentMonth: Bool
    let isToday: Bool
    let isSelected: Bool
    let eventCount: Int
    let hasRecordable: Bool

    var body: some View {
        VStack(spacing: 4) {
            Text(dayNumber)
                .font(.cadenza(.body, scale: uiScale))
                .fontWeight(isToday ? .bold : .regular)
                .foregroundStyle(isToday ? Color.white : (isCurrentMonth ? Color.primary : Color.secondary.opacity(0.5)))
                .frame(width: 28, height: 28)
                .background {
                    if isToday {
                        Circle().fill(.red)
                    } else if isSelected {
                        Circle().fill(.blue.opacity(0.15))
                    }
                }

            // Event dots
            if eventCount > 0 {
                HStack(spacing: 3) {
                    ForEach(0..<min(eventCount, 3), id: \.self) { _ in
                        Circle()
                            .fill(hasRecordable ? .blue : .secondary)
                            .frame(width: 5, height: 5)
                    }
                }
            }

            Spacer()
        }
        .padding(.top, 4)
        .frame(height: 64)
        .frame(maxWidth: .infinity)
        .background(isSelected ? Color.blue.opacity(0.05) : Color.clear)
    }

    private var dayNumber: String {
        // Bare digits only: the day() field style appends a day-unit suffix
        // in zh/ja/ko locales that cannot fit the fixed 28pt badge.
        Calendar.autoupdatingCurrent.component(.day, from: date)
            .formatted(.number.grouping(.never).locale(locale))
    }
}
