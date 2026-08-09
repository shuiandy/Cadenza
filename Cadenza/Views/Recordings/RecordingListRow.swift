import SwiftUI

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
                Text(recording.title)
                    .font(.cadenza(13, weight: .semibold, scale: uiScale))
                    .lineLimit(1)

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

            HStack(spacing: 6) {
                if recording.hasTranscript {
                    statusPill(icon: "text.bubble.fill")
                }
                if recording.hasSummary {
                    statusPill(icon: "sparkles")
                }
            }

            VStack(alignment: .trailing, spacing: 2) {
                Text(dateString)
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

    /// Compact tag chip for the list row — mirrors the grid card's style (shared
    /// `RecordingCardView.tagColor`) but a touch smaller to fit the denser row.
    private func tagChip(_ tag: String) -> some View {
        Label(tag, systemImage: "tag")
            .font(.cadenza(13 - 4, weight: .medium, scale: uiScale))
            .foregroundStyle(RecordingCardView.tagColor(for: tag))
            .lineLimit(1)
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

    private var dateString: String {
        recording.startDate.formatted(Self.dateStyle)
    }

    private var durationString: String {
        let minutes = Int(recording.duration) / 60
        if minutes < 1 { return "<1m" }
        return "\(minutes)m"
    }

    private static let dateStyle = Date.FormatStyle.dateTime.month(.abbreviated).day()
}
