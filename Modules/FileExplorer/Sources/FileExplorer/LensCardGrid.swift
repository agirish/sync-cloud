import CoreGraphics
import Foundation

/// How many cards fit across a lens pane, and how a list of them divides into rows.
///
/// **A card is a measure; the pane is not.** Past some width a card stops getting more readable and
/// starts being one card's worth of content stretched across a window that could have held three —
/// which on a list of 88 duplicate groups is a 200pt gap down the middle of every row and twice the
/// scrolling. So the lenses lay their cards out as a grid whose column count follows the pane,
/// collapsing to a single column the moment it is too narrow for two.
///
/// The arithmetic is here, out of the views, because it is the part that can be silently wrong: an
/// off-by-one in the fit gives a two-column layout at a width where every card truncates, which does
/// not crash and does not look wrong in a screenshot.
///
/// **`minimumCardWidth` is the caller's, because the cards differ.** A renames card holds two
/// columns of file names and needs 340pt before a second column is an improvement; a collapsed
/// duplicates tile is a badge, a name and a one-line subtitle and works at 250. One shared rule, two
/// honest minimums — rather than one number that is wrong for one of them.
enum LensCardGrid {

    /// Gap between cards, horizontally and vertically.
    static let gutter: CGFloat = 10

    /// **Three, not "as many as fit".** Cards grow past their minimum to fill the pane, and beyond
    /// three the names get narrower rather than the layout getting better — a fourth column on a
    /// wide display trades legibility for density on screens whose whole job is reading names.
    static let maximumColumns = 3

    /// What the container's own insets take before the cards see the width.
    ///
    /// **The caller's, because the two lenses have different chrome.** 32 is the renames `List` —
    /// an 8pt row inset either side plus the inset style's own margin. The duplicates lens is a
    /// `ScrollView` with `.padding(densityMetrics.cardListPadding)`, which is 12 comfortable and 8
    /// compact, so 24 or 16. One constant for both under-counted the usable width by 8–16pt and
    /// could draw a column fewer than fits — exactly the off-by-one this file's header warns about,
    /// which does not crash and does not look wrong in a screenshot.
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
    /// The column count alone does not answer it — one column at the app's window floor is a
    /// narrower card than two columns on a wide display — and the duplicates card chooses its
    /// header from this rather than from the count.
    static func cardWidth(forWidth width: CGFloat, columns: Int,
                          horizontalPadding: CGFloat = listHorizontalPadding) -> CGFloat {
        let perRow = max(1, columns)
        let usable = width - horizontalPadding - gutter * CGFloat(perRow - 1)
        return max(0, usable / CGFloat(perRow))
    }

    /// A grid row with an identity of its own.
    ///
    /// **A row's index is not an identity, and in a sectioned list it is a bug.** Every section's
    /// rows are numbered from zero, so `ForEach(rows.enumerated(), id: \.offset)` hands a
    /// `LazyVStack` several children claiming to be row 0 — and a lazy stack identifies its
    /// children across the whole stack, not per `ForEach`. It then reuses cells against the wrong
    /// content: sections rendered blank, one section's tiles appeared under another's heading, and
    /// the list only filled in as scrolling forced a rebuild. His report: "tiles only show up when
    /// scrolling down."
    ///
    /// The first item's id is the row's, which is unique across the entire list because an item
    /// appears in exactly one row (``LensCardGrid/rows(_:columns:spansFullWidth:)`` is a
    /// partition).
    struct IdentifiedRow<Item: Identifiable>: Identifiable {
        let items: [Item]

        /// The first item's id, which is unique across the list because an item is in exactly one
        /// row (``LensCardGrid/rows(_:columns:spansFullWidth:)`` is a partition).
        ///
        /// **No row key is STABLE under a reflowing grid, and a previous version of this claimed
        /// one was.** It keyed on the whole membership, arguing that only rows that really changed
        /// would get a new id — which is false, and strictly worse: with three columns and cards
        /// A…H the rows are `[A,B,C] [D,E,F] [G,H]`; trashing B reflows them to `[A,C,D] [E,F,G]
        /// [H]`, where the membership key changes for ALL THREE and the first-item key at least
        /// keeps row `A`. Removing a card re-partitions everything after it either way; that is
        /// what a grid is. Uniqueness is what a `LazyVStack` must have and what this guarantees.
        ///
        /// Cannot trap on an empty row: `rows(_:columns:spansFullWidth:)` never emits one — the
        /// buffer is flushed only under `!buffer.isEmpty` and the full-width branch appends exactly
        /// one element. `everyCardAppearsOnceInTheOrderGiven` and `fullWidthItemsAtEveryPosition`
        /// are the two that assert it.
        var id: Item.ID { items[0].id }
    }

    /// The rows, each carrying a stable identity — what a view should use. See ``IdentifiedRow``.
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
    /// **It counts ITEMS, and the caller's rows are not all one item wide** — an expanded card
    /// takes a row to itself, so a section with one card open among the first twelve shows six
    /// rows, not four, and the last of them can carry a single tile. Whole-row folding holds only
    /// while nothing in the section is expanded, which is the ordinary state; the alternative is
    /// re-folding the section under the user as they open a card.
    static func itemsBeforeFold(columns: Int) -> Int {
        max(6, max(1, columns) * 4)
    }

    /// The cards divided into rows of at most `columns`, in the order given.
    ///
    /// Reading order is left to right, then down — the same order the single-column list has, so
    /// widening the window rearranges the list without reordering it.
    static func rows<Item>(_ items: [Item], columns: Int) -> [[Item]] {
        rows(items, columns: columns, spansFullWidth: { _ in false })
    }

    /// The same division, except that an item answering `spansFullWidth` takes a row to itself.
    ///
    /// **An expanded card is a panel, not a tile.** A duplicates card open on its copies draws
    /// breadcrumbs, a preview and a path per copy, and an action row — content that needs the pane, not a third
    /// of it — so opening one must widen it rather than leave it competing with the tile beside it.
    /// Everything before and after it still tiles, which is why this cannot be a plain chunk: the
    /// buffer has to flush at the full-width item and start again after it, or a row would carry
    /// four cards where the grid is three wide.
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
