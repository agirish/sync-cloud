import CoreGraphics
import Foundation

/// How many cards fit across a lens pane, and how a list of them divides into rows.
///
/// Past some width a card stops getting more readable and becomes one card's content stretched
/// across room for three, so the lenses lay cards out in a grid whose column count follows the pane,
/// down to one column when it is too narrow for two.
///
/// The arithmetic lives here, out of the views, because it can be silently wrong: an off-by-one
/// gives two columns where every card truncates, which neither crashes nor looks wrong in a
/// screenshot.
///
/// `minimumCardWidth` is the caller's, because the cards differ: a renames card holds two columns
/// of names and needs 340pt; a collapsed duplicates tile works at 250.
enum LensCardGrid {

    /// Gap between cards, horizontally and vertically.
    static let gutter: CGFloat = 10

    /// Three, not "as many as fit": cards grow to fill the pane, and a fourth column would trade
    /// legibility for density on screens whose job is reading names.
    static let maximumColumns = 3

    /// What the container's own insets take before the cards see the width.
    ///
    /// The caller's, because the lenses have different chrome. 32 is the renames `List`: an 8pt row
    /// inset either side plus the inset style's margin. The duplicates lens pads its `ScrollView` by
    /// `densityMetrics.cardListPadding`, so 24 or 16; using 32 there would draw a column fewer than
    /// fits.
    static let listHorizontalPadding: CGFloat = 32

    /// The column count for a pane of this width.
    ///
    /// Defends against the width a `GeometryReader` reports on its first pass (0) and against a
    /// proposal of `.infinity`, either of which would otherwise divide into a nonsense count.
    static func columns(forWidth width: CGFloat, minimumCardWidth: CGFloat,
                        horizontalPadding: CGFloat = listHorizontalPadding) -> Int {
        guard width.isFinite, width > 0, minimumCardWidth > 0, horizontalPadding >= 0 else {
            return 1
        }
        let usable = width - horizontalPadding
        guard usable > 0 else { return 1 }
        let fit = Int((usable + gutter) / (minimumCardWidth + gutter))
        return min(maximumColumns, max(1, fit))
    }

    /// What one card gets, once the container's chrome and the gutters are taken.
    ///
    /// The column count alone doesn't say: one column at the window floor is narrower than two on a
    /// wide display. The duplicates card picks its header from this, not the count.
    static func cardWidth(forWidth width: CGFloat, columns: Int,
                          horizontalPadding: CGFloat = listHorizontalPadding) -> CGFloat {
        let perRow = max(1, columns)
        let usable = width - horizontalPadding - gutter * CGFloat(perRow - 1)
        return max(0, usable / CGFloat(perRow))
    }

    /// A grid row with an identity of its own.
    ///
    /// **Never key rows by index in a sectioned list.** Every section numbers its rows from zero,
    /// and a `LazyVStack` identifies children across the whole stack, not per `ForEach`, so
    /// duplicate ids make it reuse cells against the wrong content: blank sections, tiles under
    /// another section's heading, rows that fill in only as scrolling forces a rebuild.
    struct IdentifiedRow<Item: Identifiable>: Identifiable {
        let items: [Item]

        /// The first item's id, which is unique across the list because an item is in exactly one
        /// row (``LensCardGrid/rows(_:columns:spansFullWidth:)`` is a partition).
        ///
        /// Unique, not stable: no row key survives a reflow, since removing a card re-partitions
        /// every row after it. A membership key would be worse (trashing B from `[A,B,C] [D,E,F]`
        /// changes both rows; the first-item key keeps `A`'s). Uniqueness is what a `LazyVStack`
        /// needs.
        ///
        /// Can't trap on an empty row: `rows(_:columns:spansFullWidth:)` never emits one
        /// (`everyCardAppearsOnceInTheOrderGiven`, `fullWidthItemsAtEveryPosition`).
        var id: Item.ID { items[0].id }
    }

    /// The rows, each carrying a unique identity: what a view should use. See ``IdentifiedRow``.
    static func identifiedRows<Item: Identifiable>(
        _ items: [Item], columns: Int,
        spansFullWidth: (Item) -> Bool = { _ in false }
    ) -> [IdentifiedRow<Item>] {
        rows(items, columns: columns, spansFullWidth: spansFullWidth)
            .map { IdentifiedRow(items: $0) }
    }

    /// How many cards a section shows before folding the rest behind "Show N more".
    ///
    /// Four rows' worth at two columns and up (8 and 12), and six items at one column, where four
    /// would fold a list barely long enough to need it.
    ///
    /// It counts items, not rows: an expanded card takes a row to itself, so with one open the fold
    /// can land mid-row. Counting rows instead would re-fold the section as the user opens a card.
    static func itemsBeforeFold(columns: Int) -> Int {
        max(6, max(1, columns) * 4)
    }

    /// The cards divided into rows of at most `columns`, in the order given.
    ///
    /// Left to right, then down: the single-column list's order, so widening the window rearranges
    /// the list without reordering it.
    static func rows<Item>(_ items: [Item], columns: Int) -> [[Item]] {
        rows(items, columns: columns, spansFullWidth: { _ in false })
    }

    /// The same division, except that an item answering `spansFullWidth` takes a row to itself.
    ///
    /// An expanded card is a panel, not a tile: a duplicates card open on its copies needs the whole
    /// pane. Everything around it still tiles, so the buffer flushes at the full-width item and
    /// starts again after it.
    static func rows<Item>(_ items: [Item], columns: Int,
                           spansFullWidth: (Item) -> Bool) -> [[Item]] {
        let perRow = max(1, columns)
        var out: [[Item]] = []
        var buffer: [Item] = []
        for item in items {
            if spansFullWidth(item) {
                if !buffer.isEmpty { out.append(buffer); buffer = [] }
                out.append([item])
                continue
            }
            buffer.append(item)
            if buffer.count == perRow { out.append(buffer); buffer = [] }
        }
        if !buffer.isEmpty { out.append(buffer) }
        return out
    }
}
