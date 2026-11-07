import AppKit

/// Finds the `NSTableView` backing one pane list, for the `.background` siblings that reach it:
/// `PaneListSelectionStyler` and `PaneBackgroundDeselect`.
///
/// Anchored on the frame, not tree position. Columns are siblings in one `HStack`, so the first
/// ancestor holding any table holds them all, and a tree walk can't tell them apart. A `.background`
/// is laid out to exactly the frame of the view it backs, so the anchor's window rect and its list's
/// scroll-view rect are the same rectangle; that also separates the two panes, which never overlap.
///
/// `@MainActor` because everything here reads live AppKit view geometry (`subviews`, `bounds`,
/// `convert(_:to:)`, `enclosingScrollView`).
@MainActor
enum PaneListResolver {

    /// How far up to look for a subtree containing any pane list at all.
    private static let searchDepth = 6
    /// How much of each rectangle the overlap must cover to count as the same list. The real
    /// rectangles are identical; this is slack for rounding, not for near misses.
    private static let matchFraction: CGFloat = 0.9

    /// Tables in `view`'s subtree, split by column count: pane lists are single-column `List`
    /// tables, the differences list is the one multi-column `Table`. Column count separates them
    /// wherever SwiftUI mounts either, so neither side's stylers touch the other's table.
    static func tables(in view: NSView, multiColumn: Bool) -> [NSTableView] {
        var result: [NSTableView] = []
        func walk(_ v: NSView) {
            if let table = v as? NSTableView,
               (table.tableColumns.count > 1) == multiColumn { result.append(table) }
            for sub in v.subviews { walk(sub) }
        }
        walk(view)
        return result
    }

    /// The list occupying the same frame as `anchor`, or nil while nothing matches. `multiColumn`
    /// selects which kind of list the caller is anchored to (see `tables(in:multiColumn:)`). Nil
    /// for an unlaid-out anchor, so the caller retries once SwiftUI has sized it.
    static func table(matching anchor: NSView, multiColumn: Bool = false) -> NSTableView? {
        let target = anchor.convert(anchor.bounds, to: nil)
        guard !target.isEmpty else { return nil }
        var root: NSView? = anchor.superview
        for _ in 0..<searchDepth {
            guard let candidate = root else { return nil }
            let found = tables(in: candidate, multiColumn: multiColumn)
            if !found.isEmpty { return bestMatch(found, target: target) }
            root = candidate.superview
        }
        return nil
    }

    /// Whether `table`'s list still occupies `target`. Cheap enough for every layout pass, so a
    /// cached answer can be checked after a drill rebuilds the column stack and moves tables.
    static func matches(_ table: NSTableView, target: CGRect) -> Bool {
        guard !target.isEmpty else { return false }
        return overlaps(frame(of: table), target)
    }

    /// The list's own rectangle: the scroll view's, since the table inside it is the scrolling
    /// document and can be taller or shorter than what the user sees.
    private static func frame(of table: NSTableView) -> CGRect {
        let view: NSView = table.enclosingScrollView ?? table
        return view.convert(view.bounds, to: nil)
    }

    private static func overlaps(_ candidate: CGRect, _ target: CGRect) -> Bool {
        let shared = candidate.intersection(target)
        guard !shared.isNull else { return false }
        let area = shared.width * shared.height
        return area >= matchFraction * target.width * target.height
            && area >= matchFraction * candidate.width * candidate.height
    }

    /// Refuses a tie rather than guessing: two lists in the same place mean the frame no longer
    /// identifies one, and picking would be a coin toss between panes.
    private static func bestMatch(_ tables: [NSTableView], target: CGRect) -> NSTableView? {
        let matching = tables.filter { overlaps(frame(of: $0), target) }
        return matching.count == 1 ? matching[0] : nil
    }
}
