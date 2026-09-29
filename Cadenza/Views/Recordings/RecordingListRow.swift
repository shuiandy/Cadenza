import SwiftUI

/// A transient library presentation, derived from active work rather than an
/// empty transcript. Failed or idle recordings must remain in the normal list.
enum RecordingLibraryActivity: Equatable {
    case recording, paused, finalizing, waitingForTranscription, transcribing, waitingForSummary, summarizing

    static func resolve(
        isCurrentRecording: Bool,
        isRecording: Bool,
        isPaused: Bool,
        isFinalizing: Bool,
        phase: JobPhase?,
        isRetryingTranscription: Bool = false,
        isGeneratingSummary: Bool = false
    ) -> Self? {
        if isCurrentRecording {
            if isFinalizing { return .finalizing }
            if isPaused { return .paused }
            if isRecording { return .recording }
        }
        if isRetryingTranscription { return .transcribing }
        if isGeneratingSummary { return .summarizing }
        switch phase {
        case .pendingTranscription: return .waitingForTranscription
        case .transcribing: return .transcribing
        case .pendingSummary: return .waitingForSummary
        case .summarizing: return .summarizing
        case nil: return nil
        }
    }

    var title: String {
        switch self {
        case .recording: String(localized: "Recording")
        case .paused: String(localized: "Paused")
        case .finalizing: String(localized: "Finishing recording...")
        case .waitingForTranscription: String(localized: "Waiting to transcribe...")
        case .transcribing: String(localized: "Transcribing...")
        case .waitingForSummary: String(localized: "Waiting for summary...")
        case .summarizing: String(localized: "Generating summary...")
        }
    }

    var symbol: String {
        switch self {
        case .recording: "waveform"
        case .paused: "pause.circle"
        case .finalizing: "tray.and.arrow.down"
        case .waitingForTranscription, .waitingForSummary: "clock"
        case .transcribing: "waveform"
        case .summarizing: "sparkles"
        }
    }

    func durationLabel(_ duration: TimeInterval) -> String? {
        switch self {
        case .recording, .paused, .finalizing: return nil
        default:
            guard duration.isFinite, duration > 0 else { return nil }
            return Duration.seconds(duration).formatted(
                .units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2)
            )
        }
    }
}

/// Activity entries are direct destinations, with native single-click and
/// keyboard activation rather than the library cards' selection gesture.
struct RecordingActivityButton: View {
    let recording: RecordingDTO
    let activity: RecordingLibraryActivity
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            RecordingActivityRow(recording: recording, activity: activity)
        }
        .buttonStyle(.cadenzaPlain)
        .accessibilityLabel(Text(recording.title))
        .accessibilityValue(Text(activity.title))
        .accessibilityHint("Open recording")
    }
}

/// Compact, neutral activity row shared by all library view modes.
struct RecordingActivityRow: View {
    @Environment(\.uiScale) private var uiScale: CGFloat
    let recording: RecordingDTO
    let activity: RecordingLibraryActivity

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: activity.symbol)
                .font(.cadenza(16, scale: uiScale))
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    identity
                    Spacer(minLength: 8)
                    status.fixedSize(horizontal: true, vertical: false)
                }
                VStack(alignment: .leading, spacing: 6) {
                    identity
                    status
                }
            }

            Image(systemName: "chevron.right")
                .font(.cadenza(10, weight: .medium, scale: uiScale))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(RoundedRectangle(cornerRadius: 10).fill(AppStyle.ColorToken.softFill))
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(recording.title)
                .font(.cadenza(13, weight: .medium, scale: uiScale))
                .lineLimit(1)
            Text(metadata)
                .font(.cadenza(11, scale: uiScale))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var status: some View {
        Text(activity.title)
            .font(.cadenza(12, scale: uiScale))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var metadata: String {
        let start = recording.startDate.formatted(date: .abbreviated, time: .shortened)
        guard let duration = activity.durationLabel(recording.duration) else { return start }
        return "\(start) · \(duration)"
    }
}

struct RecordingListRow: View {
    @Environment(\.uiScale) private var uiScale: CGFloat

    let recording: RecordingDTO

    var body: some View {
        let iconFrame = CadenzaControlMetrics.squareIconFrame(
            base: 34,
            symbolPointSize: 16,
            scale: uiScale,
            padding: 0
        )
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(AppStyle.ColorToken.mutedCapsuleFill)
                    .frame(width: iconFrame, height: iconFrame)
                Image(systemName: "waveform")
                    .font(.cadenza(13 + 3, weight: .medium, scale: uiScale))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(typeTint)
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                    Text(recording.title)
                        .font(.cadenza(13, weight: .semibold, scale: uiScale))
                        .lineLimit(1)
                }

                if let preview = contentPreview {
                    Text(preview)
                        .font(.cadenza(13 - 2, scale: uiScale))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if !recording.tags.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(recording.tags.prefix(4), id: \.self) { tag in
                            tagChip(tag)
                        }
                    }
                    .padding(.top, 1)
                }
            }

            Spacer()

            if !recording.hasTranscript {
                statusPill(text: String(localized: "No transcript"))
            }

            VStack(alignment: .trailing, spacing: 2) {
                Text(timeString)
                    .font(.cadenza(13 - 2, scale: uiScale))
                    .foregroundStyle(.secondary)
                statusPill(text: durationString)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .appCollectionCard(cornerRadius: AppStyle.Radius.card)
    }

    private func statusPill(icon: String? = nil, text: String? = nil) -> some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.cadenza(13 - 4, weight: .semibold, scale: uiScale))
            }
            if let text {
                Text(text)
                    .lineLimit(1)
            }
        }
        .font(.cadenza(13 - 3, weight: .medium, scale: uiScale))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(AppStyle.ColorToken.mutedCapsuleFill))
        .overlay(
            Capsule()
                .strokeBorder(AppStyle.ColorToken.mutedCapsuleStroke, lineWidth: 0.6)
        )
    }

    /// Compact tag chip for the list row — mirrors the grid card's neutral
    /// chip (hue survives as a small dot, shared `RecordingCardView.tagColor`)
    /// but a touch smaller to fit the denser row.
    private func tagChip(_ tag: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(RecordingCardView.tagColor(for: tag))
                .frame(width: 5, height: 5)
                .accessibilityHidden(true)
            Text(tag)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .font(.cadenza(13 - 4, weight: .medium, scale: uiScale))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule(style: .continuous).fill(AppStyle.ColorToken.mutedCapsuleFill))
        .overlay(Capsule(style: .continuous).strokeBorder(AppStyle.ColorToken.mutedCapsuleStroke, lineWidth: 0.6))
    }

    private var contentPreview: String? {
        if let preview = recording.summaryPreview, !preview.isEmpty {
            return preview
        }
        if let preview = recording.transcriptPreview, !preview.isEmpty {
            return preview
        }
        return nil
    }

    /// Time, not date: list rows sit under a day header, which already
    /// carries the date.
    private var timeString: String {
        recording.startDate.formatted(Self.timeStyle)
    }

    private var durationString: String {
        let minutes = Int(recording.duration) / 60
        if minutes < 1 { return "<1m" }
        return "\(minutes)m"
    }

    private var typeTint: Color {
        guard let raw = recording.meetingType,
              let type = MeetingType(rawValue: raw) else {
            return Color.secondary.opacity(0.35)
        }
        return RecordingCardView.typeTint(for: type)
    }

    private static let timeStyle = Date.FormatStyle.dateTime.hour(.defaultDigits(amPM: .abbreviated)).minute()
}
