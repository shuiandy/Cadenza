import SwiftUI

struct CalendarContentReloadKey: Equatable {
    let dateRange: String
    let hasCalendarPermission: Bool
}

struct CalendarContainerView: View {
    @Environment(\.uiScale) private var uiScale: CGFloat
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(AppState.self) private var appState

    @State private var viewMode: CalendarViewMode = .week
    @State private var selectedDate = Date()
    @State private var events: [MeetingEvent] = []
    @State private var selectedEvent: MeetingEvent?
    /// Future events whose meeting-prep brief already exists; drives the
    /// sparkle on their timeline blocks. Loaded alongside the events.
    @State private var prepReadyEventIDs: Set<String> = []
    @State private var containerWidth: CGFloat = 0
    @AppStorage("calendarConnectBannerDismissed") private var connectBannerDismissed = false
    @AppStorage("autoRecordMeetings") private var autoRecordMeetings = false

    private var noCalendarSourcesConnected: Bool {
        !appState.hasCalendarPermission
            && !appState.googleCalendarConnected
            && !appState.zoomConnected
    }

    /// Right-hand "today" rail: week and day views only, and only when the
    /// panel is wide enough that the grid keeps its room.
    private var showsTodayRail: Bool {
        viewMode != .month
            && containerWidth >= 1000
            && !CadenzaTextScale.isAccessibilitySize(dynamicTypeSize)
    }

    /// Event → recording relationship for the timeline blocks (Concept D),
    /// keyed per OCCURRENCE: a recording counts only when it falls on that
    /// occurrence's own day, so a recurring series never inherits one
    /// occurrence's recording across the whole week.
    private var recordingStates: [String: CalendarEventRecordingState] {
        var map: [String: CalendarEventRecordingState] = [:]
        let recordingsByEvent = Dictionary(
            grouping: appState.recordings.filter {
                $0.linkedCalendarEventID != nil && $0.trashedDate == nil
            },
            by: { $0.linkedCalendarEventID ?? "" }
        )
        let calendar = Calendar.current
        let now = Date()
        for event in events {
            let key = CalendarEventRecordingState.occurrenceKey(for: event)
            let occurrenceRecording = recordingsByEvent[event.id]?.first {
                calendar.isDate($0.startDate, inSameDayAs: event.startDate)
            }
            if let recording = occurrenceRecording {
                map[key] = .recorded(transcribed: recording.hasTranscript)
            } else if event.startDate > now, !event.isAllDay {
                map[key] = .upcoming(prepReady: prepReadyEventIDs.contains(event.id))
            }
        }
        return map
    }

    var body: some View {
        VStack(spacing: 0) {
            CalendarToolbarView(
                viewMode: $viewMode,
                selectedDate: $selectedDate
            )
            .padding(.top, 2)
            .padding(.bottom, 6)

            // No connected source means an empty grid with zero explanation;
            // say why and point at the fix instead (Concept D).
            if noCalendarSourcesConnected && !connectBannerDismissed {
                connectBanner
                    .padding(.bottom, 6)
            }

            HStack(spacing: 0) {
                Group {
                    switch viewMode {
                    case .day:
                        CalendarDayView(
                            selectedDate: $selectedDate,
                            events: events,
                            recordingStates: recordingStates,
                            onEventTap: { selectedEvent = $0 }
                        )
                    case .week:
                        CalendarWeekView(
                            selectedDate: $selectedDate,
                            events: events,
                            recordingStates: recordingStates,
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

                if showsTodayRail {
                    Divider()
                    todayRail
                        .frame(width: 232)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            containerWidth = width
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

    // MARK: - Connect Banner

    private var connectBanner: some View {
        HStack(spacing: 9) {
            Image(systemName: "exclamationmark.triangle")
                .font(.cadenza(12, weight: .medium, scale: uiScale))
                .foregroundStyle(.orange)
            Text("Connect a calendar to see your meetings here and link them to recordings automatically.")
                .font(.cadenza(12, scale: uiScale))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button {
                appState.navigate(to: .settings)
            } label: {
                Text("Connect Calendar")
                    .font(.cadenza(12, weight: .semibold, scale: uiScale))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.accentColor))
            }
            .buttonStyle(.cadenzaPlain)
            Button {
                connectBannerDismissed = true
            } label: {
                Image(systemName: "xmark")
                    .font(.cadenza(10, weight: .semibold, scale: uiScale))
                    .foregroundStyle(.tertiary)
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.cadenzaPlain)
            .accessibilityLabel("Clear")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.orange.opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.3), lineWidth: 1)
        )
        .padding(.horizontal, 10)
    }

    // MARK: - Today Rail

    private var todayEvents: [MeetingEvent] {
        let calendar = Calendar.current
        return events
            .filter { calendar.isDateInToday($0.startDate) && !$0.isAllDay }
            .sorted { $0.startDate < $1.startDate }
    }

    /// The meeting the rail spotlights: in progress first, else next up today.
    private var railFocusEvent: MeetingEvent? {
        let now = Date()
        let candidates = todayEvents.filter { $0.endDate > now }
        return candidates.first(where: \.isHappening) ?? candidates.first
    }

    private var weekRecordings: [RecordingDTO] {
        guard let week = Calendar.current.dateInterval(of: .weekOfYear, for: Date()) else { return [] }
        return appState.recordings.filter {
            $0.trashedDate == nil && week.contains($0.startDate)
        }
    }

    private var todayRail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Today")
                        .font(.cadenza(13, weight: .bold, scale: uiScale))
                    Text(Date.now.formatted(.dateTime.month(.abbreviated).day().weekday(.abbreviated)))
                        .font(.cadenza(10, scale: uiScale))
                        .foregroundStyle(.tertiary)
                }

                if let focus = railFocusEvent {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(focus.displayColor)
                                .frame(width: 7, height: 7)
                                .accessibilityHidden(true)
                            Text(focus.title)
                                .font(.cadenza(12, weight: .semibold, scale: uiScale))
                                .lineLimit(2)
                        }
                        Text(verbatim: railFocusTimeString(focus))
                            .font(.cadenza(10.5, scale: uiScale))
                            .foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            Button {
                                selectedEvent = focus
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "sparkles")
                                        .font(.cadenza(9, scale: uiScale))
                                    Text("Meeting Prep")
                                        .font(.cadenza(10.5, weight: .semibold, scale: uiScale))
                                }
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                                .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.3), lineWidth: 0.75))
                                .contentShape(Capsule())
                            }
                            .buttonStyle(.cadenzaPlain)

                            if autoRecordMeetings {
                                HStack(spacing: 3) {
                                    Image(systemName: "checkmark")
                                        .font(.cadenza(8, weight: .bold, scale: uiScale))
                                        .foregroundStyle(.green)
                                    Text("Auto-record on")
                                        .font(.cadenza(9.5, scale: uiScale))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .appCollectionCard(cornerRadius: 10)
                } else {
                    Text("No more meetings today.")
                        .font(.cadenza(11, scale: uiScale))
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 4)
                }

                Text("This Week")
                    .font(.cadenza(10, weight: .bold, scale: uiScale))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)

                HStack(spacing: 6) {
                    Image(systemName: "waveform")
                        .font(.cadenza(10, scale: uiScale))
                        .foregroundStyle(.secondary)
                    Text(verbatim: weekRecordedString)
                        .font(.cadenza(10.5, scale: uiScale))
                        .foregroundStyle(.secondary)
                }

                Button {
                    appState.navigate(to: .allRecordings)
                } label: {
                    Text("View this week in Library")
                        .font(.cadenza(11, weight: .semibold, scale: uiScale))
                        .foregroundStyle(Color.accentColor)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.cadenzaPlain)
            }
            .padding(12)
        }
    }

    private func railFocusTimeString(_ event: MeetingEvent) -> String {
        let range = LocalizedDateFormatting.interval(
            from: event.startDate, to: event.endDate,
            dateStyle: .none, timeStyle: .short
        )
        if let app = event.meetingApp {
            return "\(range) · \(app.displayName)"
        }
        return range
    }

    private var weekRecordedString: String {
        let recordings = weekRecordings
        let countString = String(localized: "\(recordings.count) recorded")
        let total = recordings.reduce(0) { $0 + $1.duration }
        guard total >= 60 else { return countString }
        let durationString = Duration.seconds(total).formatted(
            .units(allowed: [.hours, .minutes], width: .narrow, maximumUnitCount: 2)
        )
        return "\(countString) · \(durationString)"
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
            self.loadPrepReadiness()
        }
    }

    /// Checks which visible future meetings already have a prep brief; the
    /// timeline sparkle and the rail read from this. Capped so a dense month
    /// view never fans out into dozens of artifact fetches.
    private func loadPrepReadiness() {
        let now = Date()
        let futureEvents = Array(
            events
                .filter { $0.startDate > now && !$0.isAllDay }
                .sorted { $0.startDate < $1.startDate }
                .prefix(12)
        )
        prepReadyEventIDs = []
        guard !futureEvents.isEmpty else { return }
        Task {
            var ready: Set<String> = []
            for event in futureEvents {
                if await appState.fetchMeetingPrep(event: event) != nil {
                    ready.insert(event.id)
                }
            }
            prepReadyEventIDs = ready
        }
    }
}

#Preview {
    CalendarContainerView()
        .environment(AppState())
        .frame(width: 700, height: 550)
}
