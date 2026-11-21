import SwiftUI

/// The Vault's cards packed into columns: each card goes into whichever column is shortest so
/// far, so a short card (two I-94 records) never leaves a gap under it beside a tall one (seven
/// passports). As many columns as fit at `minColumnWidth`, sharing the width; one column when
/// narrow, as the grid it replaces was.
///
/// Columns are chosen from each card's full size (``VaultMasonrySize``): its header and every
/// row, folded or not. So folding a card shrinks it where it stands; only the cards under it in
/// its own column move up, and none changes column. They are chosen again only when which cards
/// there are, or how many rows each holds, changes. Placing uses each card's height as drawn.
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

    /// Which column each card goes in: the shortest so far by full size, the leftmost of a tie,
    /// so the first cards fill the top row left to right. Sizes alone, in whatever unit they
    /// come (rows, or points): the gap between cards is the same in every column.
    func assignments(width: CGFloat, sizes: [CGFloat]) -> [Int] {
        var totals = Array(repeating: CGFloat(0), count: columns(for: width).count)
        return sizes.map { size in
            let column = totals.indices.min { totals[$0] < totals[$1] || (totals[$0] == totals[$1] && $0 < $1) } ?? 0
            totals[column] += size
            return column
        }
    }

    /// Where each card goes, in the columns `assignments` chose, stacked at the heights drawn;
    /// and the height of the whole. `sizes` choose the columns; without them, `heights` do.
    func placements(width: CGFloat, heights: [CGFloat], sizes: [CGFloat]? = nil) -> (origins: [CGPoint], height: CGFloat) {
        let (count, columnWidth) = columns(for: width)
        let chosen = assignments(width: width, sizes: sizes ?? heights)
        var tops = Array(repeating: CGFloat(0), count: count)
        var origins: [CGPoint] = []
        for (height, column) in zip(heights, chosen) {
            origins.append(CGPoint(x: CGFloat(column) * (columnWidth + spacing), y: tops[column]))
            tops[column] += height + spacing
        }
        let tallest = tops.max() ?? 0
        return (origins, heights.isEmpty ? 0 : max(0, tallest - spacing))
    }

    private func measure(_ subviews: Subviews, columnWidth: CGFloat) -> (heights: [CGFloat], sizes: [CGFloat]) {
        let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height }
        // A card that says its full size is placed by it; one that does not, by its height.
        let sizes = zip(subviews, heights).map { subview, height in subview[VaultMasonrySize.self] ?? height }
        return (heights, sizes)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // Unspecified or unbounded, the ideal width: one column.
        let width = proposal.width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? minColumnWidth
        let (_, columnWidth) = columns(for: width)
        let (heights, sizes) = measure(subviews, columnWidth: columnWidth)
        return CGSize(width: width, height: placements(width: width, heights: heights, sizes: sizes).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (_, columnWidth) = columns(for: bounds.width)
        let (heights, sizes) = measure(subviews, columnWidth: columnWidth)
        let (origins, _) = placements(width: bounds.width, heights: heights, sizes: sizes)
        for (subview, origin) in zip(subviews, origins) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), anchor: .topLeading,
                          proposal: ProposedViewSize(width: columnWidth, height: nil))
        }
    }
}

/// A card's full size for choosing its column, folded or not: its header and every row, in
/// rows. Set with `.layoutValue(key: VaultMasonrySize.self, value: …)`.
struct VaultMasonrySize: LayoutValueKey {
    static let defaultValue: CGFloat? = nil
}
