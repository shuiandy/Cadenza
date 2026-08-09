import SwiftUI

struct RecordingRow: View {
    @Environment(\.uiScale) private var uiScale: CGFloat
    @Environment(\.locale) private var locale

    let recording: Recording

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(recording.title)
                    .font(.cadenza(.subheadline, weight: .medium, scale: uiScale))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(timeString)
                        .font(.cadenza(.caption, scale: uiScale))
                        .foregroundStyle(.secondary)

                    Text(durationString)
                        .font(.cadenza(.caption, scale: uiScale))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            HStack(spacing: 4) {
                if recording.transcript != nil {
                    Image(systemName: "text.bubble")
                        .font(.cadenza(.caption, scale: uiScale))
                        .foregroundStyle(.blue)
                }
                if recording.summary != nil {
                    Image(systemName: "sparkles")
                        .font(.cadenza(.caption, scale: uiScale))
                        .foregroundStyle(.purple)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var timeString: String {
        LocalizedDateFormatting.string(
            from: recording.startDate,
            style: .dateTime.hour(.defaultDigits(amPM: .abbreviated)).minute(),
            locale: locale
        )
    }

    private var durationString: String {
        let minutes = Int(recording.duration) / 60
        let seconds = Int(recording.duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
