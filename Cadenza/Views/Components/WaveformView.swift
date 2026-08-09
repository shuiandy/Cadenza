import SwiftUI

struct WaveformView: View {
    let level: Float
    var color: Color = .accentColor
    private let barCount = 5

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(color)
                    .frame(width: 3, height: barHeight(for: index))
                    .animation(.easeOut(duration: 0.1), value: level)
            }
        }
    }

    private func barHeight(for index: Int) -> CGFloat {
        let normalizedLevel = CGFloat(min(max(level, 0), 1))
        let centerIndex = CGFloat(barCount) / 2.0
        let distance = abs(CGFloat(index) - centerIndex) / centerIndex
        let height = normalizedLevel * 20 * (1.0 - distance * 0.5)
        return max(height, 3)
    }
}
