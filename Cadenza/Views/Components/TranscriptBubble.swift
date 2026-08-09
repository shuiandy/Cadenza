import SwiftUI

struct TranscriptBubble: View {
    @Environment(\.uiScale) private var uiScale: CGFloat

    let segment: TranscriptSegmentDTO

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(formatTimestamp(segment.timestamp))
                .font(.cadenza(.caption, scale: uiScale))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 50, alignment: .trailing)

            Text(segment.text)
                .font(.cadenzaBody(.body, scale: uiScale))
                .opacity(segment.isFinal ? 1.0 : 0.6)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    segment.isFinal
                        ? Color.accentColor.opacity(0.1)
                        : Color.secondary.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 8)
                )
        }
    }

    private func formatTimestamp(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
