import SwiftUI

struct CalendarWeekView: View {
    @Environment(\.uiScale) private var uiScale: CGFloat
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.locale) private var locale

    @Binding var selectedDate: Date
    let events: [MeetingEvent]
    var recordingStates: [String: CalendarEventRecordingState] = [:]
    var onEventTap: (MeetingEvent) -> Void

    private let hourHeight = CalendarTimelineMetrics.hourHeight
    private let startHour = 0
    private let endHour = 24
    private let timeColumnWidth: CGFloat = 60

    var body: some View {
        if CalendarAdaptiveLayoutPolicy.mode(
            for: dynamicTypeSize,
            effectiveScale: uiScale
        ) == .agenda {
            accessibleAgenda
        } else {
            timeline
        }
    }

    private var timeline: some View {
        VStack(spacing: 0) {
            // Day headers
            HStack(spacing: 0) {
                Spacer()
                    .frame(width: timeColumnWidth + 8)
                ForEach(weekDays, id: \.self) { date in
                    VStack(spacing: 2) {
                        Text(dayOfWeekString(date))
                            .font(.cadenza(11, weight: .medium, scale: uiScale))
                            .foregroundStyle(.secondary)
                        Text(dayNumberString(date))
                            .font(.cadenza(.title3, weight: .bold, scale: uiScale))
                            .foregroundStyle(isToday(date) ? .white : .primary)
                            .frame(width: 30, height: 30)
                            .background {
                                if isToday(date) {
                                    Circle().fill(.red)
                                }
                            }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 4)

            Divider()

            // All-day events row (pinned above scroll)
            if hasAnyAllDayEvents {
                weekAllDayRow
                Divider()
            }

            // Scrollable time grid
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    ZStack(alignment: .topLeading) {
                        // Hour grid
                        VStack(spacing: 0) {
                            ForEach(startHour..<endHour, id: \.self) { hour in
                                HStack(alignment: .top, spacing: 0) {
                                    Text(hourString(hour))
                                        .font(.cadenza(11, scale: uiScale))
                                        .foregroundStyle(.secondary)
                                        .frame(width: timeColumnWidth, alignment: .trailing)
                                        .padding(.trailing, 8)
                                        .offset(y: -6)

                                    HStack(spacing: 0) {
                                        ForEach(0..<7, id: \.self) { _ in
                                            VStack(spacing: 0) {
                                                Divider()
                                                Spacer()
                                            }
                                            .frame(maxWidth: .infinity)
                                        }
                                    }
                                }
                                .frame(height: hourHeight)
                                .id(hour)
                            }
                        }

                        // Timed events overlay with overlap layout per day
                        GeometryReader { geo in
                            let dayColumnWidth = (geo.size.width - timeColumnWidth - 8) / 7.0

                            ForEach(Array(weekDays.enumerated()), id: \.offset) { dayIndex, date in
                                let dayTimedEvents = timedEventsForDay(date)
                                let layoutItems = OverlapLayout.layout(events: dayTimedEvents)
                                let dayX = timeColumnWidth + 8 + dayColumnWidth * CGFloat(dayIndex)

                                ForEach(layoutItems, id: \.event.id) { item in
                                    let w = dayColumnWidth / CGFloat(item.totalColumns)
                                    let x = dayX + w * CGFloat(item.column)

                                    Button {
                                        onEventTap(item.event)
                                    } label: {
                                        CalendarEventBlock(
                                            event: item.event,
                                            recordingState: recordingStates[CalendarEventRecordingState.occurrenceKey(for: item.event)] ?? .none
                                        )
                                            .frame(width: w - 2, height: eventHeight(item.event))
                                    }
                                    .buttonStyle(.cadenzaPlain)
                                    .offset(x: x, y: eventOffset(item.event, dayStart: Calendar.current.startOfDay(for: date)))
                                }
                            }
                        }

                        // Current time indicator
                        if weekDays.contains(where: { isToday($0) }) {
                            CurrentTimeIndicator()
                                .padding(.leading, timeColumnWidth + 4)
                                .offset(y: currentTimeOffset)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .onAppear {
                    let targetHour = max(Calendar.current.component(.hour, from: Date()) - 1, 0)
                    proxy.scrollTo(targetHour, anchor: .top)
                }
            }
        }
    }

    private var accessibleAgenda: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(weekDays, id: \.self) { date in
                    let dayEvents = eventsForDay(date)
                    Text(LocalizedDateFormatting.string(
                        from: date,
                        style: .dateTime.weekday(.wide).month(.wide).day(),
                        locale: locale
                    ))
                        .font(.cadenza(.headline, scale: uiScale))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                        .padding(.bottom, 6)

                    if dayEvents.isEmpty {
                        Text("No events")
                            .font(.cadenza(.body, scale: uiScale))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 10)
                    } else {
                        ForEach(dayEvents) { event in
                            Button {
                                onEventTap(event)
                            } label: {
                                CalendarAgendaEventRow(event: event)
                                    .padding(.horizontal, 16)
                            }
                            .buttonStyle(.cadenzaPlain)
                        }
                    }

                    Divider()
                }
            }
        }
    }

    // MARK: - All-day row for week view

    private var hasAnyAllDayEvents: Bool {
        weekDays.contains { date in
            allDayEventsForDay(date).count > 0
        }
    }

    private var weekAllDayRow: some View {
        HStack(alignment: .top, spacing: 0) {
            Text("all-day")
                .font(.cadenza(11, scale: uiScale))
                .foregroundStyle(.secondary)
                .frame(width: timeColumnWidth, alignment: .trailing)
                .padding(.trailing, 8)

            ForEach(weekDays, id: \.self) { date in
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(allDayEventsForDay(date)) { event in
                        Button {
                            onEventTap(event)
                        } label: {
                            AllDayEventChip(event: event)
                        }
                        .buttonStyle(.cadenzaPlain)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 1)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .background(.fill.quaternary)
    }

    // MARK: - Event filtering

    private func allDayEventsForDay(_ date: Date) -> [MeetingEvent] {
        let calendar = Calendar.current
        return events.filter { calendar.isDate($0.startDate, inSameDayAs: date) && $0.isAllDay }
    }

    private func timedEventsForDay(_ date: Date) -> [MeetingEvent] {
        let calendar = Calendar.current
        return events.filter { calendar.isDate($0.startDate, inSameDayAs: date) && !$0.isAllDay }
    }

    private func eventsForDay(_ date: Date) -> [MeetingEvent] {
        let calendar = Calendar.current
        return events
            .filter { calendar.isDate($0.startDate, inSameDayAs: date) }
            .sorted { $0.startDate < $1.startDate }
    }

    // MARK: - Layout helpers

    private var weekDays: [Date] {
        let calendar = Calendar.current
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: selectedDate)?.start ?? selectedDate
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: weekStart) }
    }

    private func eventOffset(_ event: MeetingEvent, dayStart: Date) -> CGFloat {
        let interval = event.startDate.timeIntervalSince(dayStart)
        let hours = interval / 3600.0
        return CGFloat(hours) * hourHeight
    }

    private func eventHeight(_ event: MeetingEvent) -> CGFloat {
        let duration = event.endDate.timeIntervalSince(event.startDate) / 3600.0
        return max(CGFloat(duration) * hourHeight, 24)
    }

    private var currentTimeOffset: CGFloat {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: Date())
        let interval = Date().timeIntervalSince(dayStart)
        let hours = interval / 3600.0
        return CGFloat(hours) * hourHeight
    }

    private func isToday(_ date: Date) -> Bool {
        Calendar.current.isDateInToday(date)
    }

    private func dayOfWeekString(_ date: Date) -> String {
        LocalizedDateFormatting.string(
            from: date,
            style: .dateTime.weekday(.abbreviated),
            locale: locale
        )
        .uppercased(with: locale)
    }

    private func dayNumberString(_ date: Date) -> String {
        // Bare digits only: the day() field style appends a day-unit suffix
        // in zh/ja/ko locales that cannot fit the fixed 30pt badge.
        Calendar.autoupdatingCurrent.component(.day, from: date)
            .formatted(.number.grouping(.never).locale(locale))
    }

    private func hourString(_ hour: Int) -> String {
        let calendar = Calendar.current
        let date = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: Date())!
        return LocalizedDateFormatting.string(
            from: date,
            style: .dateTime.hour(.defaultDigits(amPM: .abbreviated)),
            locale: locale,
            calendar: calendar
        )
    }
}
