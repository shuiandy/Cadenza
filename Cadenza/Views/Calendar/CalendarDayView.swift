import SwiftUI

struct CalendarDayView: View {
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
            // All-day events banner (pinned above scroll)
            if !allDayEvents.isEmpty {
                AllDayBanner(events: allDayEvents, onEventTap: onEventTap)
                Divider()
            }

            // Timed events timeline
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

                                    VStack(spacing: 0) {
                                        Divider()
                                        Spacer()
                                    }
                                }
                                .frame(height: hourHeight)
                                .id(hour)
                            }
                        }

                        // Timed events with overlap layout
                        GeometryReader { geo in
                            let columnWidth = geo.size.width - timeColumnWidth - 20
                            let layoutItems = OverlapLayout.layout(events: timedEvents)

                            ForEach(layoutItems, id: \.event.id) { item in
                                let w = columnWidth / CGFloat(item.totalColumns)
                                let x = timeColumnWidth + 12 + w * CGFloat(item.column)

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
                                .offset(x: x, y: eventOffset(item.event))
                            }
                        }

                        // Current time indicator
                        if Calendar.current.isDate(selectedDate, inSameDayAs: Date()) {
                            CurrentTimeIndicator()
                                .padding(.leading, timeColumnWidth + 4)
                                .offset(y: currentTimeOffset)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .onAppear {
                    let targetHour = Calendar.current.isDate(selectedDate, inSameDayAs: Date())
                        ? max(Calendar.current.component(.hour, from: Date()) - 1, 0)
                        : 8
                    proxy.scrollTo(targetHour, anchor: .top)
                }
            }
        }
    }

    private var accessibleAgenda: some View {
        Group {
            if dayEvents.isEmpty {
                ContentUnavailableView("No events", systemImage: "calendar")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(dayEvents.sorted { $0.startDate < $1.startDate }) { event in
                            Button {
                                onEventTap(event)
                            } label: {
                                CalendarAgendaEventRow(event: event)
                                    .padding(.horizontal, 16)
                            }
                            .buttonStyle(.cadenzaPlain)

                            Divider()
                        }
                    }
                }
            }
        }
    }

    // MARK: - Filtered events

    private var dayEvents: [MeetingEvent] {
        let calendar = Calendar.current
        return events.filter { calendar.isDate($0.startDate, inSameDayAs: selectedDate) }
    }

    private var allDayEvents: [MeetingEvent] {
        dayEvents.filter { $0.isAllDay }
    }

    private var timedEvents: [MeetingEvent] {
        dayEvents.filter { !$0.isAllDay }
    }

    // MARK: - Layout helpers

    private func eventOffset(_ event: MeetingEvent) -> CGFloat {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: selectedDate)
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

    private func hourString(_ hour: Int) -> String {
        let calendar = Calendar.current
        let date = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: selectedDate)!
        return LocalizedDateFormatting.string(
            from: date,
            style: .dateTime.hour(.defaultDigits(amPM: .abbreviated)),
            locale: locale,
            calendar: calendar
        )
    }
}

// MARK: - Overlap Layout Algorithm

enum OverlapLayout {
    struct Item {
        let event: MeetingEvent
        let column: Int
        let totalColumns: Int
    }

    static func layout(events: [MeetingEvent]) -> [Item] {
        guard !events.isEmpty else { return [] }

        let sorted = events.sorted { $0.startDate < $1.startDate }
        var clusters: [[MeetingEvent]] = []

        for event in sorted {
            if let lastIdx = clusters.indices.last,
               clusters[lastIdx].contains(where: { overlaps($0, event) }) {
                clusters[lastIdx].append(event)
            } else {
                clusters.append([event])
            }
        }

        // Merge clusters that overlap transitively
        var merged: [[MeetingEvent]] = []
        for cluster in clusters {
            if let lastIdx = merged.indices.last,
               merged[lastIdx].contains(where: { existing in
                   cluster.contains(where: { overlaps(existing, $0) })
               }) {
                merged[lastIdx].append(contentsOf: cluster)
            } else {
                merged.append(cluster)
            }
        }

        var result: [Item] = []

        for cluster in merged {
            let clusterSorted = cluster.sorted { $0.startDate < $1.startDate }
            var columns: [[MeetingEvent]] = []

            for event in clusterSorted {
                var placed = false
                for colIdx in columns.indices {
                    let lastInCol = columns[colIdx].last!
                    if !overlaps(lastInCol, event) {
                        columns[colIdx].append(event)
                        placed = true
                        break
                    }
                }
                if !placed {
                    columns.append([event])
                }
            }

            let totalCols = columns.count
            for (colIdx, col) in columns.enumerated() {
                for event in col {
                    result.append(Item(event: event, column: colIdx, totalColumns: totalCols))
                }
            }
        }

        return result
    }

    private static func overlaps(_ a: MeetingEvent, _ b: MeetingEvent) -> Bool {
        a.startDate < b.endDate && b.startDate < a.endDate
    }
}

// MARK: - All-day banner (shared between Day & Week views)

struct AllDayBanner: View {
    @Environment(\.uiScale) private var uiScale: CGFloat

    let events: [MeetingEvent]
    var onEventTap: (MeetingEvent) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text("all-day")
                .font(.cadenza(11, scale: uiScale))
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .trailing)
                .padding(.trailing, 8)

            VStack(alignment: .leading, spacing: 3) {
                ForEach(events) { event in
                    Button {
                        onEventTap(event)
                    } label: {
                        AllDayEventChip(event: event)
                    }
                    .buttonStyle(.cadenzaPlain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .background(.fill.quaternary)
    }
}

struct AllDayEventChip: View {
    @Environment(\.uiScale) private var uiScale: CGFloat

    let event: MeetingEvent

    var body: some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                .fill(event.displayColor)
                .frame(width: 3, height: 14)

            Text(event.title)
                .font(.cadenza(12, weight: .medium, scale: uiScale))
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(event.displayColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
    }
}
