import AppKit

/// Finds the `NSTableView` backing one pane list, on behalf of the `.background` siblings that have
/// to reach it — `PaneListSelectionStyler` and `PaneBackgroundDeselect`.
///
/// **Anchored on the frame, not on tree position.** The previous walk scanned each ancestor's
/// subtree in turn and refused as soon as one held more than one table, on the reasoning that a
/// lower level, closer to the list, would resolve to exactly one. In the tree presentation it does:
/// the two panes are far apart. In Columns it does not — the columns are siblings in one `HStack`,
/// so the first ancestor holding *any* table holds all of them, and the walk refused every time.
///
/// The cost of that was quiet and real. Mounting three columns and reading the tables back showed
/// `selectionHighlightStyle` still at `.regular` on columns 1 and 2: only the first column, which
/// resolved while it was briefly the pane's only list, ever got styled. Every column the user drills
/// into was painting the OS selection highlight underneath the pane's own accent wash.
///
/// A `.background` is laid out to exactly the frame of the view it backs, so the anchor's window
/// rect and its list's scroll view rect are the same rectangle — measured identical, to the point.
/// That makes the frame a precise identifier where tree position is an ambiguous one, and it
/// disambiguates the two panes for free: they are never in the same place.
///
/// `@MainActor` because every function here reads live AppKit view geometry — `subviews`,
/// `bounds`, `convert(_:to:)`, `enclosingScrollView` — which is main-actor state. It was already
/// only ever *called* from the main actor (the callers are `NSView` subclasses and a `@MainActor`
/// suite); the annotation states the requirement the code already had rather than adding one.
@MainActor
enum PaneListResolver {

    /// How far up to look for a subtree containing any pane list at all.
    private static let searchDepth = 6
    /// How much of each rectangle the overlap must cover to count as the same list. The real
    /// rectangles are identical; this is slack for rounding, not for near misses.
    private static let matchFraction: CGFloat = 0.9

    /// Single-column tables in `view`'s subtree. A multi-column table is a `Table` — the differences
    /// list — and never a pane list.
    static func singleColumnTables(in view: NSView) -> [NSTableView] {
        var result: [NSTableView] = []
        func walk(_ v: NSView) {
            if let table = v as? NSTableView, table.tableColumns.count <= 1 { result.append(table) }
            for sub in v.subviews { walk(sub) }
        }
        walk(view)
        return result
    }

    /// The pane list occupying the same frame as `anchor`, or nil while nothing matches.
    ///
    /// Returns nil for an unlaid-out anchor rather than guessing, so a caller can retry once
    /// SwiftUI has given it a size.
    static func table(matching anchor: NSView) -> NSTableView? {
        let target = anchor.convert(anchor.bounds, to: nil)
        guard !target.isEmpty else { return nil }
        var root: NSView? = anchor.superview
        for _ in 0..<searchDepth {
            guard let candidate = root else { return nil }
            let tables = singleColumnTables(in: candidate)
            if !tables.isEmpty { return bestMatch(tables, target: target) }
            root = candidate.superview
        }
        return nil
    }

    /// Whether `table`'s list still occupies `target`. Cheap enough to re-check on every layout
    /// pass, which is what lets a cached answer survive a drill — the column stack is rebuilt
    /// wholesale, and a cached table can end up belonging to a different column than the one the
    /// anchor now sits over.
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

    /// Refuses a tie rather than guessing, exactly as the old walk refused an ambiguous subtree —
    /// two lists in the same place would mean the frame has stopped identifying anything, and
    /// picking one at that point is a coin toss between panes.
    private static func bestMatch(_ tables: [NSTableView], target: CGRect) -> NSTableView? {
        let matching = tables.filter { overlaps(frame(of: $0), target) }
        return matching.count == 1 ? matching[0] : nil
    }
}
