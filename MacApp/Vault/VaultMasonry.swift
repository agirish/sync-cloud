import SwiftUI

/// The Vault's cards packed into columns: each card goes into whichever column is shortest so
/// far, so a short card (two I-94 records) never leaves a gap under it beside a tall one (seven
/// passports). As many columns as fit at `minColumnWidth`, sharing the width; one column when
/// narrow, as the grid it replaces was.
///
/// Cards keep their order: the first ones fill the top row left to right, and each after goes
/// under the shortest. Folding a card can move the ones after it to another column; the panel
/// animates that (``withDesignAnimation``), so the move is followed rather than jumped.
struct VaultMasonry: Layout {
    var minColumnWidth: CGFloat = 270
    var spacing: CGFloat = 12

    /// How many columns fit `width`, and how wide each is. A width without bound, as SwiftUI
    /// proposes when it asks a scroll view's content for its ideal size, is one column at the
    /// minimum: never a count made from infinity, which traps.
    func columns(for width: CGFloat) -> (count: Int, width: CGFloat) {
        guard width.isFinite, width > 0 else { return (1, minColumnWidth) }
        let count = max(1, Int((width + spacing) / (minColumnWidth + spacing)))
        let columnWidth = (width - spacing * CGFloat(count - 1)) / CGFloat(count)
        return (count, max(0, columnWidth))
    }

    /// Where each card goes: its column's left edge and its top, and the height of the whole.
    func placements(width: CGFloat, heights: [CGFloat]) -> (origins: [CGPoint], height: CGFloat) {
        let (count, columnWidth) = columns(for: width)
        var tops = Array(repeating: CGFloat(0), count: count)
        var origins: [CGPoint] = []
        for height in heights {
            // The shortest column, the leftmost of any tie: order reads left to right.
            let column = tops.indices.min { tops[$0] < tops[$1] || (tops[$0] == tops[$1] && $0 < $1) } ?? 0
            origins.append(CGPoint(x: CGFloat(column) * (columnWidth + spacing), y: tops[column]))
            tops[column] += height + spacing
        }
        let tallest = tops.max() ?? 0
        return (origins, heights.isEmpty ? 0 : max(0, tallest - spacing))
    }

    private func heights(_ subviews: Subviews, columnWidth: CGFloat) -> [CGFloat] {
        subviews.map { $0.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // Unspecified or unbounded, the ideal width: one column.
        let width = proposal.width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? minColumnWidth
        let (_, columnWidth) = columns(for: width)
        return CGSize(width: width, height: placements(width: width, heights: heights(subviews, columnWidth: columnWidth)).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (_, columnWidth) = columns(for: bounds.width)
        let (origins, _) = placements(width: bounds.width, heights: heights(subviews, columnWidth: columnWidth))
        for (subview, origin) in zip(subviews, origins) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), anchor: .topLeading,
                          proposal: ProposedViewSize(width: columnWidth, height: nil))
        }
    }
}
