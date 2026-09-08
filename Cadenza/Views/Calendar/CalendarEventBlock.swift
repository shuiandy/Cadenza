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

/// Recording relationship a timeline block visualizes (Concept D): recorded
/// meetings render as filled blocks with a waveform mark, future meetings as
/// dashed outlines, with a sparkle when the meeting-prep brief is ready.
enum CalendarEventRecordingState: Equatable {
    case none
    case recorded(transcribed: Bool)
    case upcoming(prepReady: Bool)

    /// Occurrence-unique map key: recurring events share `id` across every
    /// occurrence, so keying by id alone would paint the whole series with
    /// one occurrence's state.
    static func occurrenceKey(for event: MeetingEvent) -> String {
        "\(event.id)|\(event.startDate.timeIntervalSince1970)"
    }
}

struct CalendarEventBlock: View {
    @Environment(\.uiScale) private var uiScale: CGFloat
    @Environment(\.locale) private var locale

    let event: MeetingEvent
    var recordingState: CalendarEventRecordingState = .none

    var body: some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                .fill(eventColor)
                .frame(width: 3)

            if case .recorded = recordingState {
                Image(systemName: "waveform")
                    .font(.cadenza(10, weight: .semibold, scale: uiScale))
                    .foregroundStyle(eventColor)
                    .accessibilityHidden(true)
            }

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

            if case .upcoming(prepReady: true) = recordingState {
                Image(systemName: "sparkles")
                    .font(.cadenza(10, scale: uiScale))
                    .foregroundStyle(Color.accentColor)
                    .help("Meeting Prep")
                    .accessibilityHidden(true)
            }

            if let app = event.meetingApp {
                Image(systemName: appIcon(app))
                    .font(.cadenza(11, scale: uiScale))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(blockBackground)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(event.title))
        .accessibilityValue(Text(timeString))
        .accessibilityHint("Open event details")
    }

    @ViewBuilder
    private var blockBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 4)
        switch recordingState {
        case .recorded:
            shape.fill(eventColor.opacity(0.22))
                .overlay(shape.strokeBorder(eventColor.opacity(0.45), lineWidth: 1))
        case .upcoming:
            shape.fill(eventColor.opacity(0.07))
                .overlay(
                    shape.strokeBorder(
                        eventColor.opacity(0.55),
                        style: StrokeStyle(lineWidth: 1, dash: [3, 2])
                    )
                )
        case .none:
            shape.fill(eventColor.opacity(0.15))
        }
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
