import SwiftUI

/// A single, quiet brand reveal for first launch. The animation never loops,
/// stays in the header as setup advances, and collapses to opacity-only when
/// Reduce Motion is enabled.
struct OnboardingBrandReveal: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.uiScale) private var uiScale

    let variant: AppIconVariant
    @Binding var isRevealed: Bool

    private var brandScale: CGFloat {
        min(uiScale, 1.4)
    }

    var body: some View {
        HStack(spacing: 13) {
            ZStack {
                Circle()
                    .stroke(Color.accentColor.opacity(0.34), lineWidth: 1.5)
                    .frame(width: 48, height: 48)
                    .scaleEffect(isRevealed ? 1.48 : 0.72)
                    .opacity(isRevealed ? 0 : 0.72)

                AppIconArtwork(variant: variant)
                    .frame(width: 52, height: 52)
                    .scaleEffect(reduceMotion || isRevealed ? 1 : 0.88)
                    .rotationEffect(.degrees(reduceMotion || isRevealed ? 0 : -4))
                    .opacity(isRevealed ? 1 : 0)
                    .shadow(color: .black.opacity(0.16), radius: 8, y: 4)
            }
            .frame(width: 56, height: 56)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text("Cadenza")
                    .font(.cadenza(24, weight: .bold, scale: brandScale))
                    .tracking(isRevealed ? 0.2 : 4.5)
                    .offset(x: reduceMotion || isRevealed ? 0 : -8)
                    .opacity(isRevealed ? 1 : 0)

                HStack(alignment: .center, spacing: 3) {
                    ForEach([5.0, 9.0, 13.0, 8.0, 4.0], id: \.self) { height in
                        Capsule()
                            .fill(Color.accentColor.opacity(0.82))
                            .frame(width: 3, height: height)
                            .scaleEffect(y: isRevealed ? 1 : 0.12, anchor: .center)
                    }
                }
                .frame(height: 13)
                .opacity(isRevealed ? 1 : 0)
                .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Cadenza")
        .onAppear {
            guard !isRevealed else { return }
            if reduceMotion {
                isRevealed = true
            } else {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.78)) {
                    isRevealed = true
                }
            }
        }
    }
}
