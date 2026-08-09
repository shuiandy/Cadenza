import Foundation

struct CalendarEventFetchResult {
    let events: [MeetingEvent]
    let canConcludeNoMatch: Bool
}

enum CalendarRefreshErrorPresentation {
    static func message(for error: Error, locale: Locale? = nil) -> String {
        if let oauthError = error as? OAuthError {
            switch oauthError {
            case .refreshFailed, .noRefreshToken:
                return oauthError.localizedMessage(locale: locale)
            default:
                break
            }
        }
        return LocalizedBundle.string(
            "Calendar refresh failed. Check your network connection and reconnect in Settings if the problem continues.",
            locale: locale
        )
    }
}

/// Aggregates events from Apple Calendar, Google Calendar, and Zoom.
@Observable @MainActor
final class CalendarManager {
    let externalAccessEnabled: Bool
    let appleCalendarService: CalendarService
    let googleCalendarService: GoogleCalendarService
    let zoomMeetingService: ZoomMeetingService
    private let tokenManager: OAuthTokenManager

    private(set) var upcomingMeetings: [MeetingEvent] = []
    /// False until `refreshAll()`'s first pass lands. `upcomingMeetings` starts empty,
    /// so without this an early reader (the MCP server now starts at the top of
    /// AppState.setup(), before calendar monitoring) cannot tell "no meetings" from
    /// "not loaded yet" and would answer the former authoritatively.
    private(set) var hasCompletedInitialRefresh: Bool
    private(set) var currentMeeting: MeetingEvent?
    private(set) var isMonitoring = false
    private var pollTimer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var refreshGate = CalendarRefreshGate()

    init(
        tokenManager: OAuthTokenManager = OAuthTokenManager(),
        externalAccessEnabled: Bool = true
    ) {
        self.externalAccessEnabled = externalAccessEnabled
        self.appleCalendarService = CalendarService(
            externalAccessEnabled: externalAccessEnabled
        )
        self.tokenManager = tokenManager
        self.googleCalendarService = GoogleCalendarService(tokenManager: tokenManager)
        self.zoomMeetingService = ZoomMeetingService(tokenManager: tokenManager)
        self.hasCompletedInitialRefresh = !externalAccessEnabled
    }

    // MARK: - Monitoring

    func startMonitoring(pollInterval: TimeInterval = 60) {
        stopMonitoring()
        guard externalAccessEnabled else {
            resetDisabledState()
            return
        }

        // CalendarService handles its own EKEventStore change notifications.
        // We only call startMonitoring (without a poll timer) so it registers
        // the EKEventStoreChanged observer. The periodic polling is handled
        // solely by CalendarManager to avoid duplicate work.
        appleCalendarService.startMonitoring(pollInterval: 0)
        refreshAll()

        if pollInterval > 0 {
            pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshAll()
                }
            }
        }
        isMonitoring = true
    }

    func stopMonitoring() {
        appleCalendarService.stopMonitoring()
        pollTimer?.invalidate()
        pollTimer = nil
        refreshTask?.cancel()
        refreshTask = nil
        refreshGate.invalidate()
        isMonitoring = false
    }

    // MARK: - Available Calendars

    func availableCalendars() -> [CalendarInfo] {
        guard externalAccessEnabled else { return [] }
        return appleCalendarService.availableCalendars()
    }

    // MARK: - Fetch for Date Range

    func fetchEvents(from startDate: Date, to endDate: Date) -> [MeetingEvent] {
        guard externalAccessEnabled else { return [] }
        // Apple calendar events (synchronous via EventKit)
        var all = appleCalendarService.fetchEvents(from: startDate, to: endDate)

        // Google and Zoom are cached in upcomingMeetings; filter by range
        let googleAndZoom = upcomingMeetings.filter { $0.source == .google || $0.source == .zoom }
        let rangeFiltered = googleAndZoom.filter { $0.startDate >= startDate && $0.startDate < endDate }
        all.append(contentsOf: rangeFiltered)

        return all.sorted { $0.startDate < $1.startDate }
    }

    func fetchEventsForAutoLink(from startDate: Date, to endDate: Date) async -> CalendarEventFetchResult {
        guard externalAccessEnabled else {
            return CalendarEventFetchResult(events: [], canConcludeNoMatch: false)
        }
        var all: [MeetingEvent] = []
        var queriedCompleteRangeSource = false
        var remoteFetchFailed = false

        if appleCalendarService.isAuthorized {
            all.append(contentsOf: appleCalendarService.fetchEvents(from: startDate, to: endDate))
            queriedCompleteRangeSource = true
        }

        if googleCalendarService.isConnected {
            do {
                let events = try await googleCalendarService.fetchEvents(from: startDate, to: endDate)
                recordSuccessfulRemoteRefresh(for: .google)
                all.append(contentsOf: events)
                queriedCompleteRangeSource = true
            } catch {
                remoteFetchFailed = true
                googleCalendarService.error = CalendarRefreshErrorPresentation.message(for: error)
                NSLog("[CalendarManager] Google auto-link fetch failed: %@", error.localizedDescription)
            }
        }

        let cachedRemoteEvents = upcomingMeetings.filter { event in
            (event.source == .google || event.source == .zoom)
                && event.startDate < endDate
                && event.endDate > startDate
        }
        all.append(contentsOf: cachedRemoteEvents)

        let sortedEvents = uniqueEvents(all).sorted { $0.startDate < $1.startDate }
        return CalendarEventFetchResult(
            events: sortedEvents,
            canConcludeNoMatch: queriedCompleteRangeSource && !remoteFetchFailed
        )
    }

    /// Get the next meeting starting within the given minutes.
    func nextMeetingStartingSoon(withinMinutes minutes: Int) -> MeetingEvent? {
        guard externalAccessEnabled else { return nil }
        return upcomingMeetings.first { event in
            event.isUpcoming && event.minutesUntilStart <= minutes
        }
    }

    /// Recompute the active meeting from cached events without refetching any
    /// calendar provider. Used by meeting detection at a short cadence so an
    /// event crossing its start time becomes active immediately.
    func refreshCurrentMeetingFromCache() {
        guard externalAccessEnabled else {
            currentMeeting = nil
            return
        }
        currentMeeting = upcomingMeetings.first { $0.isHappening && !$0.isAllDay }
    }

    /// Return the calendar event whose title/app context should still inform
    /// meeting detection, even shortly before start or after scheduled end.
    func currentMeetingForDetectionContext(now: Date = Date()) -> MeetingEvent? {
        guard externalAccessEnabled else { return nil }
        return upcomingMeetings.first { $0.isWithinDetectionContext(at: now) }
    }

    // MARK: - Refresh All Sources

    func refreshAll() {
        guard externalAccessEnabled else {
            refreshTask?.cancel()
            refreshTask = nil
            refreshGate.invalidate()
            resetDisabledState()
            return
        }
        let refresh = refreshGate.begin()
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            var all: [MeetingEvent] = []

            // Apple — refresh data before reading cached results
            appleCalendarService.refreshMeetings()
            all.append(contentsOf: appleCalendarService.upcomingMeetings)

            // Google
            if googleCalendarService.isConnected {
                let now = Date()
                let endDate = Calendar.current.date(byAdding: .day, value: 7, to: now)!
                do {
                    let events = try await googleCalendarService.fetchEvents(from: now, to: endDate)
                    guard !Task.isCancelled else { return }
                    recordSuccessfulRemoteRefresh(for: .google)
                    all.append(contentsOf: events)
                } catch {
                    guard !Task.isCancelled else { return }
                    googleCalendarService.error = CalendarRefreshErrorPresentation.message(for: error)
                    NSLog("[CalendarManager] Google fetch failed: %@", error.localizedDescription)
                }
            }

            guard !Task.isCancelled else { return }

            // Zoom
            if zoomMeetingService.isConnected {
                do {
                    let meetings = try await zoomMeetingService.fetchUpcomingMeetings()
                    guard !Task.isCancelled else { return }
                    recordSuccessfulRemoteRefresh(for: .zoom)
                    all.append(contentsOf: meetings)
                } catch {
                    guard !Task.isCancelled else { return }
                    zoomMeetingService.error = CalendarRefreshErrorPresentation.message(for: error)
                    NSLog("[CalendarManager] Zoom fetch failed: %@", error.localizedDescription)
                }
            }

            guard !Task.isCancelled, refreshGate.accepts(refresh) else { return }
            upcomingMeetings = all.sorted { $0.startDate < $1.startDate }
            refreshCurrentMeetingFromCache()
            hasCompletedInitialRefresh = true
        }
    }

    /// A provider error describes the latest refresh attempt, not a permanent
    /// connection state. Clear stale failures as soon as that provider returns
    /// successfully so Settings can move back from Error to Connected.
    func recordSuccessfulRemoteRefresh(for source: CalendarSource) {
        switch source {
        case .google:
            googleCalendarService.error = nil
        case .zoom:
            zoomMeetingService.error = nil
        case .apple:
            break
        }
    }

    private func resetDisabledState() {
        upcomingMeetings = []
        currentMeeting = nil
        hasCompletedInitialRefresh = true
    }

    private func uniqueEvents(_ events: [MeetingEvent]) -> [MeetingEvent] {
        var seen = Set<String>()
        return events.filter { event in
            let key = "\(event.source.rawValue):\(event.id)"
            guard !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
    }
}
