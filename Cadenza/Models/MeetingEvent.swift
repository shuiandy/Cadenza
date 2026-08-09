import Foundation

enum CalendarSource: String, Sendable, Codable, CaseIterable {
    case apple
    case google
    case zoom

    var displayName: String {
        switch self {
        case .apple: String(localized: "Apple Calendar")
        case .google: String(localized: "Google Calendar")
        case .zoom: "Zoom"
        }
    }

    var icon: String {
        switch self {
        case .apple: "calendar"
        case .google: "g.circle"
        case .zoom: "video"
        }
    }

    var tintColor: String {
        switch self {
        case .apple: "red"
        case .google: "blue"
        case .zoom: "indigo"
        }
    }
}

// MARK: - Attendee

struct EventAttendee: Sendable, Identifiable {
    var id: String { email }
    let name: String
    let email: String
    let isOrganizer: Bool
    let status: AttendeeStatus
    var isCurrentUser: Bool = false
}

enum AttendeeStatus: String, Sendable {
    case accepted
    case declined
    case tentative
    case pending
    case unknown

    var icon: String {
        switch self {
        case .accepted: "checkmark.circle.fill"
        case .declined: "xmark.circle.fill"
        case .tentative: "questionmark.circle.fill"
        case .pending: "circle"
        case .unknown: "circle"
        }
    }

    var tint: String {
        switch self {
        case .accepted: "green"
        case .declined: "red"
        case .tentative: "orange"
        case .pending: "secondary"
        case .unknown: "secondary"
        }
    }
}

enum EventAvailability: String, Sendable, Codable {
    case busy
    case free
    case tentative
    case outOfOffice
    case unavailable
}

// MARK: - Meeting Event

struct MeetingEvent: Identifiable, Sendable {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let meetingURL: URL?
    let meetingApp: MeetingApp?
    let calendarName: String
    let notes: String?
    var source: CalendarSource = .apple
    var calendarID: String = ""
    var defaultColorHex: String = ""
    var organizer: String?
    var attendees: [EventAttendee] = []
    var isRecurring: Bool = false
    var location: String?

    // Phase 2: occurrence-key + eligibility inputs
    var providerEventID: String = ""     // 源原生 event id(周期=series/master);空 → 从 id 剥前缀
    var occurrenceAnchor: Date? = nil    // 周期实例的 original occurrence start
    var availability: EventAvailability = .busy

    /// 当前用户对该会的回应(派生自 attendees)。
    var myResponseStatus: AttendeeStatus? {
        attendees.first(where: \.isCurrentUser)?.status
    }

    /// occurrence key 用的 provider id:显式非空则用之,否则从 id 剥 source 前缀。
    var resolvedProviderEventID: String {
        providerEventID.isEmpty ? Self.stripSourcePrefix(id) : providerEventID
    }

    /// 接 Phase 1 的稳定 occurrence key。
    var artifactTargetKey: String {
        ArtifactTargetKey.make(
            source: source.rawValue, calendarID: calendarID,
            providerEventID: resolvedProviderEventID, occurrenceAnchor: occurrenceAnchor)
    }

    static func stripSourcePrefix(_ id: String) -> String {
        for p in ["google_", "zoom_"] where id.hasPrefix(p) {
            return String(id.dropFirst(p.count))
        }
        return id
    }

    var isAllDay: Bool {
        let calendar = Calendar.current
        let duration = endDate.timeIntervalSince(startDate)
        // All-day if starts at midnight and lasts >= 23 hours
        let comps = calendar.dateComponents([.hour, .minute], from: startDate)
        return comps.hour == 0 && comps.minute == 0 && duration >= 23 * 3600
    }

    var isHappening: Bool {
        let now = Date()
        return now >= startDate && now <= endDate
    }

    func isWithinDetectionContext(at date: Date = Date()) -> Bool {
        MeetingDetectionCalendarContext.contains(
            date,
            startDate: startDate,
            endDate: endDate,
            isAllDay: isAllDay
        )
    }

    var isUpcoming: Bool {
        Date() < startDate
    }

    var minutesUntilStart: Int {
        Int(startDate.timeIntervalSinceNow / 60)
    }
}

enum MeetingApp: String, CaseIterable, Sendable {
    case zoom
    case teams
    case googleMeet
    case webex
    case facetime
    case slack

    var displayName: String {
        switch self {
        case .zoom: "Zoom"
        case .teams: "Microsoft Teams"
        case .googleMeet: "Google Meet"
        case .webex: "Webex"
        case .facetime: "FaceTime"
        case .slack: "Slack"
        }
    }

    var bundleIdentifiers: [String] {
        switch self {
        case .zoom: ["us.zoom.xos"]
        case .teams: ["com.microsoft.teams", "com.microsoft.teams2"]
        case .googleMeet: [] // Browser-based
        case .webex: ["com.cisco.webexmeetingsapp"]
        case .facetime: ["com.apple.FaceTime"]
        case .slack: ["com.tinyspeck.slackmacgap"]
        }
    }

    /// Bundle IDs to check for audio input via Process Audio Object API.
    /// Some apps (e.g. Teams) delegate audio to helper subprocesses whose
    /// bundle IDs differ from the main app. Falls back to `bundleIdentifiers`
    /// for apps that handle audio in-process.
    ///
    /// **Teams caveat**: `com.microsoft.teams2.modulehost` handles Teams' audio
    /// but keeps `isRunningInput=true` even when idle — including it would cause
    /// false triggers whenever Teams runs in the background. The main process
    /// (`com.microsoft.teams2`) can also flap during screen sharing. Teams relies
    /// on system mic + window/calendar signals instead of per-process audio.
    var audioBundleIdentifiers: [String] {
        switch self {
        case .zoom: bundleIdentifiers
        case .teams: []
        case .googleMeet: []
        case .webex: bundleIdentifiers
        case .facetime: bundleIdentifiers
        case .slack: bundleIdentifiers
        }
    }

    /// Bundle IDs used only to keep an already-active meeting alive through UI
    /// transitions where normal window signals disappear, such as Teams screen
    /// sharing. These IDs must not be used for initial meeting detection because
    /// some helper processes can report input outside a real call.
    var continuityAudioBundleIdentifiers: [String] {
        switch self {
        case .teams: ["com.microsoft.teams2", "com.microsoft.teams2.modulehost"]
        default: []
        }
    }

}
