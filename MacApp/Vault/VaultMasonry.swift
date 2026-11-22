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

    /// Each card's height and size at the last column width, so a layout pass measures once:
    /// SwiftUI asks for the size and then places, at the same width. Emptied whenever the cards
    /// change; one width only, so a live resize keeps nothing it will not ask for again.
    struct Cache { var measured: (width: CGFloat, heights: [CGFloat], sizes: [CGFloat])? }

    func makeCache(subviews: Subviews) -> Cache { Cache() }
    func updateCache(_ cache: inout Cache, subviews: Subviews) { cache.measured = nil }

    private func measure(_ subviews: Subviews, columnWidth: CGFloat, cache: inout Cache) -> (heights: [CGFloat], sizes: [CGFloat]) {
        if let measured = cache.measured, measured.width == columnWidth { return (measured.heights, measured.sizes) }
        let measured = measure(subviews, columnWidth: columnWidth)
        cache.measured = (columnWidth, measured.heights, measured.sizes)
        return measured
    }

    private func measure(_ subviews: Subviews, columnWidth: CGFloat) -> (heights: [CGFloat], sizes: [CGFloat]) {
        let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height }
        // A card that says its full size is placed by it; one that does not, by its height.
        let sizes = zip(subviews, heights).map { subview, height in subview[VaultMasonrySize.self] ?? height }
        return (heights, sizes)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        // Unspecified or unbounded, the ideal width: one column.
        let width = proposal.width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? minColumnWidth
        let (_, columnWidth) = columns(for: width)
        let (heights, sizes) = measure(subviews, columnWidth: columnWidth, cache: &cache)
        return CGSize(width: width, height: placements(width: width, heights: heights, sizes: sizes).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let (_, columnWidth) = columns(for: bounds.width)
        let (heights, sizes) = measure(subviews, columnWidth: columnWidth, cache: &cache)
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

/// Rows in two columns when each can be `minColumnWidth` wide, else one; never more than two, which
/// would cut a row's title short. Laid out row by row, so reading order is walking order; each
/// line is as tall as its taller cell.
struct VaultTwoUp: Layout {
    var minColumnWidth: CGFloat
    var spacing: CGFloat
    var rowSpacing: CGFloat

    func columns(for width: CGFloat) -> Int { width >= 2 * minColumnWidth + spacing ? 2 : 1 }

    /// Each line's height at the last width, so a layout pass measures once. Emptied whenever the
    /// rows change; one width only.
    struct Cache { var lines: (width: CGFloat, columns: Int, cell: CGFloat, heights: [CGFloat])? }

    func makeCache(subviews: Subviews) -> Cache { Cache() }
    func updateCache(_ cache: inout Cache, subviews: Subviews) { cache.lines = nil }

    private func lines(_ subviews: Subviews, width: CGFloat, cache: inout Cache) -> (columns: Int, cell: CGFloat, heights: [CGFloat]) {
        if let laid = cache.lines, laid.width == width { return (laid.columns, laid.cell, laid.heights) }
        let laid = lines(subviews, width: width)
        cache.lines = (width, laid.columns, laid.cell, laid.heights)
        return laid
    }

    private func lines(_ subviews: Subviews, width: CGFloat) -> (columns: Int, cell: CGFloat, heights: [CGFloat]) {
        let columns = columns(for: width)
        let cell = columns == 2 ? (width - spacing) / 2 : width
        let heights = stride(from: 0, to: subviews.count, by: columns).map { start in
            subviews[start..<min(start + columns, subviews.count)]
                .map { $0.sizeThatFits(ProposedViewSize(width: cell, height: nil)).height }.max() ?? 0
        }
        return (columns, cell, heights)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let width = proposal.width ?? 2 * minColumnWidth + spacing
        let laid = lines(subviews, width: width, cache: &cache)
        let height = laid.heights.reduce(0, +) + rowSpacing * CGFloat(max(laid.heights.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let laid = lines(subviews, width: bounds.width, cache: &cache)
        var y = bounds.minY
        for (line, height) in laid.heights.enumerated() {
            for column in 0..<laid.columns {
                let index = line * laid.columns + column
                guard index < subviews.count else { break }
                let x = bounds.minX + CGFloat(column) * (laid.cell + spacing)
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                                      proposal: ProposedViewSize(width: laid.cell, height: height))
            }
            y += height + rowSpacing
        }
    }
}
