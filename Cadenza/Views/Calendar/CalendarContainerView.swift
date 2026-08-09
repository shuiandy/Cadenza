import SwiftUI

struct CalendarContentReloadKey: Equatable {
    let dateRange: String
    let hasCalendarPermission: Bool
}

struct CalendarContainerView: View {
    @Environment(AppState.self) private var appState

    @State private var viewMode: CalendarViewMode = .week
    @State private var selectedDate = Date()
    @State private var events: [MeetingEvent] = []
    @State private var selectedEvent: MeetingEvent?

    var body: some View {
        VStack(spacing: 0) {
            CalendarToolbarView(
                viewMode: $viewMode,
                selectedDate: $selectedDate
            )
            .padding(.top, 2)
            .padding(.bottom, 6)

            Group {
                switch viewMode {
                case .day:
                    CalendarDayView(
                        selectedDate: $selectedDate,
                        events: events,
                        onEventTap: { selectedEvent = $0 }
                    )
                case .week:
                    CalendarWeekView(
                        selectedDate: $selectedDate,
                        events: events,
                        onEventTap: { selectedEvent = $0 }
                    )
                case .month:
                    CalendarMonthView(
                        selectedDate: $selectedDate,
                        events: events,
                        viewMode: $viewMode,
                        onEventTap: { selectedEvent = $0 }
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // The sheet window is the only chrome: it already rounds, shadows and
        // fills. The detail view therefore draws no card of its own and sits
        // flush against the window edge — the previous `padding(18)` +
        // inner glass card + `presentationBackground(.clear)` rendered as two
        // nested panels with a fat empty gutter between them (and
        // `presentationDetents` is iOS-only, so it never sized anything here).
        .sheet(item: $selectedEvent) { event in
            EventDetailPopover(event: event) {
                selectedEvent = nil
            }
            .environment(appState)
        }
        .task(id: calendarContentReloadKey) {
            await loadEvents()
        }
    }

    private var calendarContentReloadKey: CalendarContentReloadKey {
        CalendarContentReloadKey(
            dateRange: dateRangeKey,
            hasCalendarPermission: appState.hasCalendarPermission
        )
    }

    private var dateRangeKey: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return "\(formatter.string(from: selectedDate))-\(viewMode.rawValue)"
    }

    private func loadEvents() async {
        let calendar = Calendar.current
        let (start, end): (Date, Date)

        switch viewMode {
        case .day:
            start = calendar.startOfDay(for: selectedDate)
            end = calendar.date(byAdding: .day, value: 1, to: start) ?? start

        case .week:
            let weekStart = calendar.dateInterval(of: .weekOfYear, for: selectedDate)?.start ?? selectedDate
            start = weekStart
            end = calendar.date(byAdding: .day, value: 7, to: start) ?? start

        case .month:
            let monthStart = calendar.dateInterval(of: .month, for: selectedDate)?.start ?? selectedDate
            start = calendar.date(byAdding: .day, value: -7, to: monthStart) ?? monthStart
            let monthEnd = calendar.date(byAdding: .month, value: 1, to: monthStart) ?? monthStart
            end = calendar.date(byAdding: .day, value: 7, to: monthEnd) ?? monthEnd
        }

        appState.fetchEvents(from: start, to: end) { dtos in
            self.events = dtos.map { dto in
                MeetingEvent(
                    id: dto.id,
                    title: dto.title,
                    startDate: dto.startDate,
                    endDate: dto.endDate,
                    meetingURL: dto.meetingURL.flatMap { URL(string: $0) },
                    meetingApp: dto.meetingApp.flatMap { MeetingApp(rawValue: $0) },
                    calendarName: dto.calendarName,
                    notes: dto.notes,
                    source: CalendarSource(rawValue: dto.source) ?? .apple,
                    calendarID: dto.calendarID,
                    defaultColorHex: dto.defaultColorHex,
                    organizer: dto.organizer,
                    attendees: dto.attendees.map { attendee in
                        EventAttendee(
                            name: attendee.name,
                            email: attendee.email,
                            isOrganizer: attendee.isOrganizer,
                            status: AttendeeStatus(rawValue: attendee.status) ?? .unknown
                        )
                    },
                    isRecurring: dto.isRecurring,
                    location: dto.location
                )
            }
        }
    }
}

#Preview {
    CalendarContainerView()
        .environment(AppState())
        .frame(width: 700, height: 550)
}
