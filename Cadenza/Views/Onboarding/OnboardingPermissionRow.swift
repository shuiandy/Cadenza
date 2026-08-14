import SwiftUI

enum OnboardingPermissionVisualState {
    case ready
    case pending
    case optional
    case working

    var symbol: String {
        switch self {
        case .ready: "checkmark.circle.fill"
        case .pending: "exclamationmark.circle.fill"
        case .optional: "circle.dashed"
        case .working: "clock.arrow.trianglehead.counterclockwise.rotate.90"
        }
    }

    var color: Color {
        switch self {
        case .ready: .green
        case .pending: .orange
        case .optional: .secondary
        case .working: .accentColor
        }
    }
}

struct OnboardingPermissionRow<Action: View>: View {
    @Environment(\.uiScale) private var uiScale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let symbol: String
    let title: String
    let badge: String?
    let detail: String
    let status: String
    let visualState: OnboardingPermissionVisualState
    let action: Action

    init(
        symbol: String,
        title: String,
        badge: String? = nil,
        detail: String,
        status: String,
        visualState: OnboardingPermissionVisualState,
        @ViewBuilder action: () -> Action
    ) {
        self.symbol = symbol
        self.title = title
        self.badge = badge
        self.detail = detail
        self.status = status
        self.visualState = visualState
        self.action = action()
    }

    var body: some View {
        Group {
            if CadenzaTextScale.isAccessibilitySize(dynamicTypeSize) {
                VStack(alignment: .leading, spacing: 14) {
                    information
                    trailingControls
                }
            } else {
                HStack(alignment: .top, spacing: 14) {
                    information
                    Spacer(minLength: 14)
                    trailingControls
                }
            }
        }
        .padding(15)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private var information: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: symbol)
                .font(.cadenza(21, weight: .medium, scale: uiScale))
                .foregroundStyle(.tint)
                .frame(width: CadenzaControlMetrics.squareIconFrame(
                    base: 32,
                    symbolPointSize: 21,
                    scale: uiScale,
                    padding: 4
                ))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.cadenza(15, weight: .semibold, scale: uiScale))
                        if let badge {
                            badgeView(badge)
                        }
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text(title)
                            .font(.cadenza(15, weight: .semibold, scale: uiScale))
                        if let badge {
                            badgeView(badge)
                        }
                    }
                }

                Text(detail)
                    .font(.cadenza(12, scale: uiScale))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var trailingControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                statusLabel
                action
            }

            VStack(alignment: .leading, spacing: 10) {
                statusLabel
                action
            }
        }
    }

    private var statusLabel: some View {
        Label(status, systemImage: visualState.symbol)
            .font(.cadenza(12, weight: .medium, scale: uiScale))
            .foregroundStyle(visualState.color)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(status)
    }

    private func badgeView(_ value: String) -> some View {
        Text(value)
            .font(.cadenza(10, weight: .semibold, scale: uiScale))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.quaternary, in: Capsule())
    }
}
