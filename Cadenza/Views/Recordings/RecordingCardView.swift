import SwiftUI

struct RecordingCardView: View {
    @Environment(\.uiScale) private var uiScale: CGFloat

    let recording: RecordingDTO
    var viewMode: ContentViewMode = .grid
    /// Active post-processing phase, threaded in by the collection so each
    /// cell stays a pure value view (no per-cell coordinator observation).
    var processingPhase: JobPhase? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Circle()
                    .fill(typeTint)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(recording.title)
                    .font(.cadenza(13 + 1, weight: .semibold, scale: uiScale))
                    .lineLimit(viewMode == .waterfall ? 2 : 1)
            }

            if let preview = contentPreview {
                Text(preview)
                    .font(.cadenza(13 - 1, scale: uiScale))
                    .foregroundStyle(.secondary)
                    .lineLimit(viewMode == .waterfall ? 6 : 3, reservesSpace: viewMode == .grid)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 6) {
                Text(metaString)
                    .font(.cadenza(13 - 2, scale: uiScale))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                statusChip

                speakerAvatarStack
            }

            if !recording.tags.isEmpty {
                FlowLayout(spacing: 5) {
                    ForEach(recording.tags.prefix(3), id: \.self) { tag in
                        tagChip(tag)
                    }
                    if recording.tags.count > 3 {
                        Text(verbatim: "+\(recording.tags.count - 3)")
                            .font(.cadenza(13 - 3, weight: .medium, scale: uiScale))
                            .foregroundStyle(.tertiary)
                            .padding(.vertical, 3)
                    }
                }
                .lineLimit(1)
            }
        }
        // The day grid breathes more than the waterfall: extra padding plus
        // the reserved three-line preview keeps its rows tall and even.
        .padding(viewMode == .grid ? 16 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .appCollectionCard(cornerRadius: AppStyle.Radius.card)
    }

    /// Status appears only while a job is running or when the transcript is
    /// genuinely missing; the old per-card transcript/summary badges carried
    /// no information once nearly every card had both.
    @ViewBuilder
    private var statusChip: some View {
        switch processingPhase {
        case .pendingTranscription, .transcribing:
            progressChip(String(localized: "Transcribing..."))
        case .pendingSummary, .summarizing:
            progressChip(String(localized: "Generating summary..."))
        case nil:
            if !recording.hasTranscript {
                Text("No transcript")
                    .font(.cadenza(13 - 4, weight: .medium, scale: uiScale))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        Capsule(style: .continuous)
                            .fill(AppStyle.ColorToken.mutedCapsuleFill)
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(AppStyle.ColorToken.mutedCapsuleStroke, lineWidth: 0.6)
                    )
            }
        }
    }

    private func progressChip(_ text: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color.orange)
                .frame(width: 5, height: 5)
                .accessibilityHidden(true)
            Text(verbatim: text)
                .font(.cadenza(13 - 4, weight: .semibold, scale: uiScale))
                .foregroundStyle(.orange)
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(
            Capsule(style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.orange.opacity(0.3), lineWidth: 0.6)
        )
    }

    /// Up to two mapped-speaker initials, overlapped; the tail collapses
    /// into a +N bubble. Hidden entirely when no speakers are mapped.
    @ViewBuilder
    private var speakerAvatarStack: some View {
        if let names = recording.speakerNames, !names.isEmpty {
            HStack(spacing: -5) {
                ForEach(names.prefix(2), id: \.self) { name in
                    speakerAvatar(initial: String(name.prefix(1)).uppercased(), tint: Self.tagColor(for: name))
                }
                if names.count > 2 {
                    speakerAvatar(initial: "+\(names.count - 2)", tint: .secondary)
                }
            }
            .accessibilityLabel(Text(names.joined(separator: ", ")))
        }
    }

    private func speakerAvatar(initial: String, tint: Color) -> some View {
        ZStack {
            Circle()
                .fill(tint.opacity(0.2))
            Text(verbatim: initial)
                .font(.cadenza(13 - 5, weight: .bold, scale: uiScale))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(width: 18, height: 18)
        .overlay(Circle().strokeBorder(AppStyle.ColorToken.stroke, lineWidth: 0.75))
    }

    /// Neutral chip with a small hue dot: the tag hue survives as a marker
    /// without the old full-color chips fighting each other across the grid.
    private func tagChip(_ tag: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Self.tagColor(for: tag))
                .frame(width: 5, height: 5)
                .accessibilityHidden(true)
            Text(tag)
                .font(.cadenza(13 - 3, weight: .medium, scale: uiScale))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
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

    /// Grid and list cells sit under a day header, so the date would be
    /// redundant; the ungrouped waterfall keeps it on the card.
    private var metaString: String {
        if viewMode == .waterfall {
            return "\(dateString) · \(timeString) · \(durationString)"
        }
        return "\(timeString) · \(durationString)"
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

    private var typeTint: Color {
        guard let raw = recording.meetingType,
              let type = MeetingType(rawValue: raw) else {
            return Color.secondary.opacity(0.35)
        }
        return Self.typeTint(for: type)
    }

    static func typeTint(for type: MeetingType) -> Color {
        switch type {
        case .oneOnOne: .purple
        case .clientMeeting: .orange
        case .interview: .pink
        case .general: Color.secondary.opacity(0.35)
        default: .teal
        }
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
