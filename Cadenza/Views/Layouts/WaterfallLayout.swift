import SwiftUI

struct WaterfallLayout: Layout {
    var minColumnWidth: CGFloat = 220
    var spacing: CGFloat = 12

    private func columnCount(for totalWidth: CGFloat) -> Int {
        max(1, Int((totalWidth + spacing) / (minColumnWidth + spacing)))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 300
        let columns = columnCount(for: width)
        let colWidth = columnWidth(for: width, columns: columns)
        var columnHeights = Array(repeating: CGFloat.zero, count: columns)

        for subview in subviews {
            let shortestIndex = columnHeights.enumerated().min(by: { $0.element < $1.element })!.offset
            let size = subview.sizeThatFits(.init(width: colWidth, height: nil))
            if columnHeights[shortestIndex] > 0 {
                columnHeights[shortestIndex] += spacing
            }
            columnHeights[shortestIndex] += size.height
        }

        let maxHeight = columnHeights.max() ?? 0
        return CGSize(width: width, height: maxHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let columns = columnCount(for: bounds.width)
        let colWidth = columnWidth(for: bounds.width, columns: columns)
        var columnHeights = Array(repeating: CGFloat.zero, count: columns)

        for subview in subviews {
            let shortestIndex = columnHeights.enumerated().min(by: { $0.element < $1.element })!.offset
            let x = bounds.minX + CGFloat(shortestIndex) * (colWidth + spacing)

            if columnHeights[shortestIndex] > 0 {
                columnHeights[shortestIndex] += spacing
            }

            let size = subview.sizeThatFits(.init(width: colWidth, height: nil))
            subview.place(at: CGPoint(x: x, y: bounds.minY + columnHeights[shortestIndex]), proposal: .init(width: colWidth, height: size.height))
            columnHeights[shortestIndex] += size.height
        }
    }

    private func columnWidth(for totalWidth: CGFloat, columns: Int) -> CGFloat {
        let totalSpacing = spacing * CGFloat(columns - 1)
        return max((totalWidth - totalSpacing) / CGFloat(columns), 0)
    }
}
