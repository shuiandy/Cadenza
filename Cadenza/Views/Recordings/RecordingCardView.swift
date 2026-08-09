import SwiftUI

struct RecordingCardView: View {
    @Environment(\.uiScale) private var uiScale: CGFloat

    let recording: RecordingDTO
    var viewMode: ContentViewMode = .grid

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(recording.title)
                .font(.cadenza(13 + 2, weight: .semibold, scale: uiScale))
                .lineLimit(2)

            HStack(spacing: 6) {
                chip(durationString, icon: "clock", tint: .accentColor)

                Spacer(minLength: 4)

                if recording.hasTranscript {
                    iconBadge("text.bubble")
                }
                if recording.hasSummary {
                    iconBadge("sparkles")
                }
            }

            if let preview = contentPreview {
                Text(preview)
                    .font(.cadenza(13 - 1, scale: uiScale))
                    .foregroundStyle(.secondary)
                    .lineLimit(viewMode == .waterfall ? 6 : 3)
            }

            Divider()

            HStack(spacing: 12) {
                Label(dateString, systemImage: "calendar")
                Label(timeString, systemImage: "clock")
            }
            .font(.cadenza(13 - 2, scale: uiScale))
            .foregroundStyle(.secondary)

            if !recording.tags.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(recording.tags.prefix(5), id: \.self) { tag in
                        chip(tag, icon: "tag", tint: Self.tagColor(for: tag))
                    }
                }
                .lineLimit(2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .appCollectionCard(cornerRadius: AppStyle.Radius.card)
    }

    private func iconBadge(_ icon: String) -> some View {
        let controlSize = CadenzaControlMetrics.squareIconFrame(
            base: 24,
            symbolPointSize: 10,
            scale: uiScale,
            padding: 10
        )
        return Image(systemName: icon)
            .font(.cadenza(13 - 3, weight: .medium, scale: uiScale))
            .foregroundStyle(.secondary)
            .frame(width: controlSize, height: controlSize)
            .background(
                Circle()
                    .fill(AppStyle.ColorToken.mutedCapsuleFill)
            )
            .overlay(
                Circle()
                    .strokeBorder(AppStyle.ColorToken.mutedCapsuleStroke, lineWidth: 0.6)
            )
    }

    private func chip(_ text: String, icon: String, tint: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.cadenza(13 - 3, weight: .medium, scale: uiScale))
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(AppStyle.ColorToken.mutedCapsuleFill)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(AppStyle.ColorToken.mutedCapsuleStroke, lineWidth: 0.6)
            )
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

    private var timeString: String {
        recording.startDate.formatted(Self.timeStyle)
    }

    private var durationString: String {
        let minutes = Int(recording.duration) / 60
        if minutes < 1 { return "<1m" }
        return "\(minutes)m"
    }

    private static let tagColors: [Color] = [
        .blue, .purple, .pink, .orange, .teal, .indigo, .green, .brown, .cyan, .mint
    ]
    private static let dateStyle = Date.FormatStyle.dateTime.month(.abbreviated).day()
    private static let timeStyle = Date.FormatStyle.dateTime.hour(.defaultDigits(amPM: .abbreviated)).minute()

    static func tagColor(for tag: String) -> Color {
        let hash = abs(tag.hashValue)
        return tagColors[hash % tagColors.count]
    }
}

// MARK: - Flow Layout

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    struct CachedData {
        var rows: [Row] = []
    }

    struct Row {
        var sizes: [CGSize] = []
        var maxHeight: CGFloat = 0
    }

    func makeCache(subviews: Subviews) -> CachedData {
        CachedData()
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout CachedData) -> CGSize {
        cache.rows = computeRows(proposal: proposal, subviews: subviews)
        let height = cache.rows.enumerated().reduce(CGFloat.zero) { result, item in
            result + item.element.maxHeight + (item.offset > 0 ? spacing : 0)
        }
        return CGSize(width: proposal.width ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout CachedData) {
        var subviewIndex = 0
        var y = bounds.minY
        for row in cache.rows {
            var x = bounds.minX
            for size in row.sizes {
                guard subviewIndex < subviews.count else { return }
                subviews[subviewIndex].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
                subviewIndex += 1
            }
            y += row.maxHeight + spacing
        }
    }

    private func computeRows(proposal: ProposedViewSize, subviews: Subviews) -> [Row] {
        let maxWidth = proposal.width ?? .infinity
        var rows: [Row] = [Row()]
        var currentWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentWidth + size.width > maxWidth && !rows[rows.count - 1].sizes.isEmpty {
                rows.append(Row())
                currentWidth = 0
            }
            rows[rows.count - 1].sizes.append(size)
            rows[rows.count - 1].maxHeight = max(rows[rows.count - 1].maxHeight, size.height)
            currentWidth += size.width + spacing
        }
        return rows
    }
}
