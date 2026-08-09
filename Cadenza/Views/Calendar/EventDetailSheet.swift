import SwiftUI

enum EventDetailLayoutMetrics {
    static func sheetSize(for effectiveScale: CGFloat) -> CGSize {
        let scale = effectiveScale.isFinite && effectiveScale > 0 ? effectiveScale : 1
        if scale >= CadenzaTextScale.factor(.accessibility1) {
            return CGSize(width: 640, height: 700)
        }
        return CGSize(width: 400, height: 540)
    }

    static func metadataIconColumnWidth(for effectiveScale: CGFloat) -> CGFloat {
        // The 13pt `video` glyph is 59pt wide at Cadenza's 3.105x maximum.
        // A 15pt metric preserves the existing 22pt default column while
        // leaving enough width for that widest real symbol.
        CadenzaControlMetrics.squareIconFrame(
            base: 22,
            symbolPointSize: 15,
            scale: effectiveScale,
            padding: 0
        )
    }
}

enum EventDetailDirectActionBoundary {
    @discardableResult
    static func openTrustedMeetingURL(
        startupPolicy: AppState.StartupPolicy,
        url: URL,
        opener: (URL) -> Bool
    ) -> Bool {
        guard startupPolicy.externalAccessEnabled else { return false }
        return MeetingURLParser.openIfTrusted(url, using: opener)
    }

    @discardableResult
    static func performHardwareCapture(
        startupPolicy: AppState.StartupPolicy,
        action: () -> Void
    ) -> Bool {
        guard startupPolicy.allowsHardwareCapture else { return false }
        action()
        return true
    }
}

/// 事件详情浮层。
///
/// Chrome note: this view draws **no** background of its own. It is presented
/// through `.sheet`, and the sheet window already supplies the rounded, shadowed
/// container — an extra `cadenzaGlass` card inside it read as two stacked layers
/// with a fat gutter between them. Content sits flush against the sheet edges;
/// only the internal 18pt gutter separates text from the window rounding.
///
/// Type note: point sizes are literal rather than semantic styles because
/// `ScaledFontDefaults` collapses `.subheadline`/`.footnote`/`.caption`/
/// `.caption2` onto 10–11pt, which is too small to carry a whole detail panel
/// and gives no usable hierarchy between rows.
struct EventDetailPopover: View {
    @Environment(\.uiScale) private var uiScale: CGFloat
    @Environment(\.locale) private var locale

    @Environment(AppState.self) private var appState
    let event: MeetingEvent
    var onDismiss: () -> Void

    private var trustedMeetingURL: URL? {
        guard let url = event.meetingURL, MeetingURLParser.isMeetingURL(url) else {
            return nil
        }
        return url
    }

    var body: some View {
        let sheetSize = EventDetailLayoutMetrics.sheetSize(for: uiScale)
        let metadataIconColumnWidth = EventDetailLayoutMetrics.metadataIconColumnWidth(for: uiScale)
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(event.title)
                        .font(.cadenza(17, weight: .semibold, scale: uiScale))
                        .lineLimit(4)

                    if let app = event.meetingApp {
                        Text(app.displayName)
                            .font(.cadenza(12, scale: uiScale))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 0)

                Circle()
                    .fill(event.displayColor)
                    .frame(width: 12, height: 12)
                    .padding(.top, 4)

                Button { onDismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.cadenza(16, scale: uiScale))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.cadenzaPlain(in: Circle()))
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // Meeting URL + Join
                    if appState.startupPolicy.externalAccessEnabled,
                       let url = trustedMeetingURL {
                        HStack {
                            Image(systemName: "video")
                                .font(.cadenza(13, scale: uiScale))
                                .foregroundStyle(.secondary)
                                .frame(width: metadataIconColumnWidth)
                            Button {
                                openMeetingURL(url)
                            } label: {
                                Text(url.host ?? url.absoluteString)
                                    .font(.cadenza(13, scale: uiScale))
                                    .lineLimit(1)
                            }
                            .buttonStyle(.link)
                            Spacer()
                            Button("Join") {
                                openMeetingURL(url)
                            }
                            .controlSize(.small)
                            .cadenzaGlass(in: .capsule, tint: .blue, interactive: true)
                        }
                    }

                    // Date / Time
                    HStack(alignment: .top) {
                        Image(systemName: "clock")
                            .font(.cadenza(13, scale: uiScale))
                            .foregroundStyle(.secondary)
                            .frame(width: metadataIconColumnWidth)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(dateString)
                                .font(.cadenza(13, weight: .medium, scale: uiScale))
                            Text(timeRange)
                                .font(.cadenza(13, scale: uiScale))
                                .foregroundStyle(.secondary)
                            if event.isRecurring {
                                HStack(spacing: 4) {
                                    Image(systemName: "repeat")
                                        .font(.cadenza(11, scale: uiScale))
                                    Text("Recurring")
                                        .font(.cadenza(12, scale: uiScale))
                                }
                                .foregroundStyle(.secondary)
                            }
                        }
                    }

                    // Location
                    if let location = event.location, !location.isEmpty {
                        HStack(alignment: .top) {
                            Image(systemName: "mappin.and.ellipse")
                                .font(.cadenza(13, scale: uiScale))
                                .foregroundStyle(.secondary)
                                .frame(width: metadataIconColumnWidth)
                            Text(location)
                                .font(.cadenza(13, scale: uiScale))
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Attendees
                    if !event.attendees.isEmpty {
                        Divider()

                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(event.attendees) { attendee in
                                HStack(spacing: 7) {
                                    Image(systemName: attendee.status.icon)
                                        .font(.cadenza(12, scale: uiScale))
                                        .foregroundStyle(attendeeColor(attendee.status))

                                    Text(attendee.name)
                                        .font(.cadenza(13, scale: uiScale))

                                    if attendee.isOrganizer {
                                        Text("(organizer)")
                                            .font(.cadenza(12, scale: uiScale))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }

                    // Notes — reading-length prose, so `cadenzaBody` (SF Pro Text)
                    // per the project font rule, not the rounded UI face.
                    if let notes = event.notes, !notes.isEmpty {
                        Divider()

                        Text(notes)
                            .font(.cadenzaBody(13, scale: uiScale))
                            .foregroundStyle(.secondary)
                            .lineLimit(8)
                    }

                    // Meeting Prep
                    Divider()
                    MeetingPrepSection(event: event)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            }
            .scrollIndicators(.never)

            Divider()

            // Action bar
            CadenzaGlassContainer {
                HStack {
                    if appState.startupPolicy.externalAccessEnabled,
                       let url = trustedMeetingURL {
                        Button {
                            openMeetingURL(url)
                        } label: {
                            Label("Join", systemImage: "video")
                                .font(.cadenza(13, weight: .medium, scale: uiScale))
                        }
                        .buttonStyle(.borderless)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .cadenzaGlass(in: .capsule, interactive: true)
                    }

                    Spacer()

                    if appState.startupPolicy.allowsHardwareCapture {
                        Button {
                            startRecording()
                        } label: {
                            Label("Record", systemImage: "record.circle")
                                .font(.cadenza(13, weight: .medium, scale: uiScale))
                        }
                        .buttonStyle(.borderless)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .cadenzaGlass(in: .capsule, tint: .red, interactive: true)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .frame(width: sheetSize.width)
        .frame(maxHeight: sheetSize.height)
    }

    private func openMeetingURL(_ url: URL) {
        guard appState.startupPolicy.externalAccessEnabled else { return }
        EventDetailDirectActionBoundary.openTrustedMeetingURL(
            startupPolicy: appState.startupPolicy,
            url: url
        ) {
            NSWorkspace.shared.open($0)
        }
    }

    private func startRecording() {
        guard appState.startupPolicy.allowsHardwareCapture else { return }
        EventDetailDirectActionBoundary.performHardwareCapture(
            startupPolicy: appState.startupPolicy
        ) {
            onDismiss()
            Task {
                do { try await appState.startRecording(meetingName: event.title) }
                catch { appState.presentStartRecordingError(error) }
            }
        }
    }

    private var dateString: String {
        LocalizedDateFormatting.string(
            from: event.startDate,
            style: .dateTime.weekday(.wide).year().month(.wide).day(),
            locale: locale
        )
    }

    private var timeRange: String {
        if event.isAllDay { return LocalizedBundle.string("All Day", locale: locale) }
        return LocalizedDateFormatting.interval(
            from: event.startDate,
            to: event.endDate,
            dateStyle: .none,
            timeStyle: .short,
            locale: locale
        )
    }

    private func attendeeColor(_ status: AttendeeStatus) -> Color {
        switch status {
        case .accepted: .green
        case .declined: .red
        case .tentative: .orange
        case .pending: .secondary
        case .unknown: .secondary
        }
    }
}

/// MeetingPrepSection's .task reads `appState.store`, which is nil on a bare
/// `AppState()` (implicitly-unwrapped `RecordingsStore!`) — give the preview a
/// real in-memory store so it doesn't crash the canvas.
@MainActor
private func eventDetailPreviewState() -> AppState {
    let state = AppState()
    state.store = RecordingsStore(modelContainer: try! RecordingsStore.makeContainer(inMemory: true))
    return state
}

#Preview {
    EventDetailPopover(
        event: MeetingEvent(
            id: "preview",
            title: "Weekly Standup",
            startDate: Date(),
            endDate: Date().addingTimeInterval(3600),
            meetingURL: URL(string: "https://zoom.us/j/123"),
            meetingApp: .zoom,
            calendarName: "Work",
            notes: "Discuss sprint progress",
            attendees: [
                EventAttendee(name: "Alice", email: "alice@example.com", isOrganizer: true, status: .accepted),
                EventAttendee(name: "Bob", email: "bob@example.com", isOrganizer: false, status: .tentative),
            ],
            location: "Conference Room A"
        ),
        onDismiss: {}
    )
    .environment(eventDetailPreviewState())
    .padding(40)
}
