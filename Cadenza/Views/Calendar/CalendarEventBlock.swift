import SwiftUI

/// Timeline geometry shared by `CalendarDayView`, `CalendarWeekView` and the
/// layout gate in `AccessibilityLayoutPolicyTests`.
///
/// The hour height and the event block's type sizes are one decision, not two:
/// a 30-minute meeting gets `hourHeight / 2`, and `CalendarEventBlock` needs
/// roughly its title line + time line + padding to keep both rows. Keeping the
/// number here means the test asserts against the real slot instead of a
/// hardcoded duplicate that silently drifts.
enum CalendarTimelineMetrics {
    static let hourHeight: CGFloat = 68

    /// Height of the shortest slot the timeline is expected to render in full.
    static var thirtyMinuteSlotHeight: CGFloat { hourHeight / 2 }
}

struct CalendarEventBlock: View {
    @Environment(\.uiScale) private var uiScale: CGFloat
    @Environment(\.locale) private var locale

    let event: MeetingEvent

    var body: some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                .fill(eventColor)
                .frame(width: 3)

            ViewThatFits(in: .vertical) {
                VStack(alignment: .leading, spacing: 1) {
                    title

                    Text(timeString)
                        .font(.cadenza(11, scale: uiScale))
                        .foregroundStyle(.secondary)
                }

                // Events shorter than 30 minutes can be only 24pt tall. Preserve
                // an unclipped title there; VoiceOver still receives the time via
                // the combined accessibility value below.
                title
            }

            Spacer(minLength: 0)

            if let app = event.meetingApp {
                Image(systemName: appIcon(app))
                    .font(.cadenza(11, scale: uiScale))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(eventColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(event.title))
        .accessibilityValue(Text(timeString))
        .accessibilityHint("Open event details")
    }

    private var eventColor: Color {
        event.displayColor
    }

    private var title: some View {
        Text(event.title)
            .font(.cadenza(12, weight: .medium, scale: uiScale))
            .lineLimit(1)
    }

    private var timeString: String {
        LocalizedDateFormatting.string(
            from: event.startDate,
            style: .dateTime.hour(.defaultDigits(amPM: .abbreviated)).minute(),
            locale: locale
        )
    }

    private func appIcon(_ app: MeetingApp) -> String {
        switch app {
        case .zoom: "video"
        case .teams: "person.2"
        case .googleMeet: "video.badge.checkmark"
        case .webex: "video.circle"
        case .facetime: "facetime"
        case .slack: "message"
        }
    }
}

/// Reflowing calendar row used when the system requests an accessibility text
/// size. Timeline blocks intentionally encode duration as height, which cannot
/// also guarantee enough room for large title/time text.
struct CalendarAgendaEventRow: View {
    @Environment(\.uiScale) private var uiScale: CGFloat
    @Environment(\.locale) private var locale

    let event: MeetingEvent

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(event.displayColor)
                .frame(width: 4)

            VStack(alignment: .leading, spacing: 4) {
                Text(event.title)
                    .font(.cadenza(15, weight: .medium, scale: uiScale))
                    .fixedSize(horizontal: false, vertical: true)

                Text(timeString)
                    .font(.cadenza(12, scale: uiScale))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(event.title))
        .accessibilityValue(Text(timeString))
        .accessibilityHint("Open event details")
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
