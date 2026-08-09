import SwiftUI

struct CurrentTimeIndicator: View {
    var body: some View {
        HStack(spacing: 0) {
            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)

            Rectangle()
                .fill(.red)
                .frame(height: 1)
        }
    }
}
