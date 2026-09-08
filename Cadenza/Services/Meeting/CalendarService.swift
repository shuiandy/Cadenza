import AppKit
import EventKit
import Foundation

/// Info about a single calendar available in EventKit.
struct CalendarInfo: Identifiable, Sendable, Codable {
    let id: String           // calendarIdentifier
    let title: String
    let accountName: String
    let defaultColorHex: String
    let source: CalendarSource
}

/// Decides whether calendar resources may cross the process's external-access
/// boundary. The generic factory seam keeps the construction rule testable
/// without creating an `EKEventStore` (and therefore without touching TCC).
struct CalendarExternalAccessPolicy: Sendable, Equatable {
    let isEnabled: Bool

    init(isEnabled: Bool = true) {
        self.isEnabled = isEnabled
    }

    @MainActor
    func makeResource<Resource>(using factory: @MainActor () -> Resource) -> Resource? {
        guard isEnabled else { return nil }
        return factory()
    }
}

/// Reads calendar events and extracts meeting information.
@Observable @MainActor
final class CalendarService {
    typealias EventStoreFactory = @MainActor () -> EKEventStore
    typealias AuthorizationStatusProvider = @MainActor () -> EKAuthorizationStatus

    let externalAccessEnabled: Bool
    private let defaults: UserDefaults
    private let eventStore: EKEventStore?
    private let authorizationStatusProvider: AuthorizationStatusProvider
    /// Set when the TCC request sheet reported granted while
    /// `EKEventStore.authorizationStatus` still served its pre-grant value —
    /// the class-level status can lag like that for the rest of the process.
    private var authorizationGrantedInProcess = false
    private(set) var upcomingMeetings: [MeetingEvent] = []
    private(set) var currentMeeting: MeetingEvent?
    private(set) var isMonitoring = false
    private var pollTimer: Timer?
    private var eventStoreObserver: NSObjectProtocol?

    init(
        externalAccessEnabled: Bool = true,
        defaults: UserDefaults = .standard,
        eventStoreFactory: EventStoreFactory = { EKEventStore() },
        authorizationStatusProvider: @escaping AuthorizationStatusProvider = {
            EKEventStore.authorizationStatus(for: .event)
        }
    ) {
        let policy = CalendarExternalAccessPolicy(isEnabled: externalAccessEnabled)
        self.externalAccessEnabled = externalAccessEnabled
        self.defaults = defaults
        self.eventStore = policy.makeResource(using: eventStoreFactory)
        self.authorizationStatusProvider = authorizationStatusProvider
    }

    // MARK: - Authorization

    var isAuthorized: Bool {
        guard externalAccessEnabled, eventStore != nil else { return false }
        if authorizationGrantedInProcess { return true }
        return authorizationStatusProvider() == .fullAccess
    }

    /// The request sheet's own result is the authoritative grant signal.
    /// Adopting it unblocks every isAuthorized-gated path in this process and
    /// resets the store so a pre-grant instance starts returning calendars.
    func adoptAuthorizationGrantedInProcess() {
        guard externalAccessEnabled, let eventStore,
              !authorizationGrantedInProcess else { return }
        authorizationGrantedInProcess = true
        eventStore.reset()
    }

    func requestAccess() async -> Bool {
        guard externalAccessEnabled, let eventStore else { return false }
        do {
            return try await eventStore.requestFullAccessToEvents()
        } catch {
            return false
        }
    }

    // MARK: - Available Calendars

    func availableCalendars() -> [CalendarInfo] {
        guard externalAccessEnabled, isAuthorized, let eventStore else { return [] }
        return eventStore.calendars(for: .event).map { cal in
            CalendarInfo(
                id: cal.calendarIdentifier,
                title: cal.title,
                accountName: cal.source.title,
                defaultColorHex: hexFromCGColor(cal.cgColor),
                source: .apple
            )
        }
    }

    // MARK: - Start Monitoring

    func startMonitoring(pollInterval: TimeInterval = 60) {
        stopMonitoring()
        guard externalAccessEnabled, isAuthorized, let eventStore else { return }

        refreshMeetings()

        // When pollInterval is 0 (or negative), skip the periodic timer.
        // CalendarManager handles periodic refreshes to avoid duplicate polling.
        if pollInterval > 0 {
            pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshMeetings()
                }
            }
        }

        eventStoreObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: eventStore,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshMeetings()
            }
        }
        isMonitoring = true
    }

    func stopMonitoring() {
        pollTimer?.invalidate()
        pollTimer = nil
        if let eventStoreObserver {
            NotificationCenter.default.removeObserver(eventStoreObserver)
            self.eventStoreObserver = nil
        }
        isMonitoring = false
    }

    // MARK: - Fetch Events

    func refreshMeetings() {
        guard externalAccessEnabled, isAuthorized, let eventStore else {
            upcomingMeetings = []
            currentMeeting = nil
            return
        }
        let now = Date()
        let endDate = Calendar.current.date(byAdding: .hour, value: 24, to: now)!
        let predicate = eventStore.predicateForEvents(
            withStart: now,
            end: endDate,
            calendars: enabledEKCalendars(in: eventStore)
        )
        let events = eventStore.events(matching: predicate)

        upcomingMeetings = events
            .sorted { $0.startDate < $1.startDate }
            .map { mapToMeetingEvent($0) }

        currentMeeting = upcomingMeetings.first { $0.isHappening }
    }

    func fetchEvents(from startDate: Date, to endDate: Date) -> [MeetingEvent] {
        guard externalAccessEnabled, isAuthorized, let eventStore else { return [] }
        let predicate = eventStore.predicateForEvents(
            withStart: startDate,
            end: endDate,
            calendars: enabledEKCalendars(in: eventStore)
        )
        let events = eventStore.events(matching: predicate)

        return events
            .sorted { $0.startDate < $1.startDate }
            .map { mapToMeetingEvent($0) }
    }

    func nextMeetingStartingSoon(withinMinutes minutes: Int) -> MeetingEvent? {
        guard externalAccessEnabled else { return nil }
        return upcomingMeetings.first { event in
            event.isUpcoming && event.minutesUntilStart <= minutes
        }
    }

    // MARK: - Enabled Calendar Filtering

    /// Returns nil (all calendars) unless user has disabled specific ones.
    private func enabledEKCalendars(in eventStore: EKEventStore) -> [EKCalendar]? {
        let disabled = Set(defaults.stringArray(forKey: "disabledCalendarIDs") ?? [])
        guard !disabled.isEmpty else { return nil }
        return eventStore.calendars(for: .event).filter { !disabled.contains($0.calendarIdentifier) }
    }

    // MARK: - Map EKEvent to MeetingEvent

    private func mapToMeetingEvent(_ event: EKEvent) -> MeetingEvent {
        let meetingURL = MeetingURLParser.extractURL(from: event)
        let meetingApp = meetingURL.flatMap { MeetingURLParser.detectApp(from: $0) }

        let attendees: [EventAttendee] = (event.attendees ?? []).map { participant in
            let status: AttendeeStatus = switch participant.participantStatus {
            case .accepted: .accepted
            case .declined: .declined
            case .tentative: .tentative
            case .pending: .pending
            default: .unknown
            }
            return EventAttendee(
                name: participant.name ?? participant.url.absoluteString,
                email: participant.url.absoluteString.replacingOccurrences(of: "mailto:", with: ""),
                isOrganizer: participant.participantRole == .chair,
                status: status,
                isCurrentUser: participant.isCurrentUser)
        }

        return MeetingEvent(
            id: event.eventIdentifier,
            title: event.title ?? String(localized: "Untitled Meeting"),
            startDate: event.startDate,
            endDate: event.endDate,
            meetingURL: meetingURL,
            meetingApp: meetingApp,
            calendarName: event.calendar.title,
            notes: event.notes,
            source: .apple,
            calendarID: event.calendar.calendarIdentifier,
            defaultColorHex: hexFromCGColor(event.calendar.cgColor),
            organizer: event.organizer?.name,
            attendees: attendees,
            isRecurring: event.hasRecurrenceRules,
            location: event.location,
            occurrenceAnchor: CalendarEventMapping.occurrenceAnchor(
                isRecurring: event.hasRecurrenceRules, startDate: event.startDate),
            availability: CalendarEventMapping.availability(from: event.availability))
    }

    // MARK: - Helpers

    private func hexFromCGColor(_ cgColor: CGColor) -> String {
        let nsColor = NSColor(cgColor: cgColor) ?? .red
        let rgb = nsColor.usingColorSpace(.sRGB) ?? nsColor
        return String(format: "#%02X%02X%02X",
            Int(rgb.redComponent * 255),
            Int(rgb.greenComponent * 255),
            Int(rgb.blueComponent * 255))
    }
}
