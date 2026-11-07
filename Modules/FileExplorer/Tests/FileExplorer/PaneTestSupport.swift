import AppKit

/// What a manual layout pump leaves behind, for the pane layout-loop suites.
@MainActor
enum PaneLayoutSettle {

    /// Views in the subtree asking for layout or a constraints update.
    static func dirtyCount(_ v: NSView) -> Int {
        (v.needsLayout ? 1 : 0) + (v.needsUpdateConstraints ? 1 : 0)
            + v.subviews.reduce(0) { $0 + dirtyCount($1) }
    }

    /// Every view in the subtree: AppKit's runaway-layout budget.
    static func viewCount(_ v: NSView) -> Int {
        1 + v.subviews.reduce(0) { $0 + viewCount($1) }
    }

    /// Rows AppKit actually laid out, one entry per table: the guard against a vacuous pass.
    static func tableRowCounts(_ view: NSView) -> [Int] {
        var counts: [Int] = []
        func walk(_ v: NSView) {
            if let t = v as? NSTableView { counts.append(t.numberOfRows) }
            for sub in v.subviews { walk(sub) }
        }
        walk(view)
        return counts
    }

    /// Layout rounds before nothing in the window is dirty, measured from the moment a change
    /// lands. Not preceded by a pump: pumping first measures the settled state, a vacuous pass.
    ///
    /// This driver can't see AppKit's display-cycle guard. `layoutIfNeeded()` runs constraint
    /// updates with the runaway guards disarmed: a never-settling sibling ping-pong survives
    /// hundreds of rounds of it without raising, while the run loop alone raises on the first
    /// cycle. So a low count says the tree stops dirtying itself under a manual pump, not that the
    /// window stays inside AppKit's pass budget. The run-loop counterpart is
    /// `ColumnsDisplayCycleTests`; see `docs/columns-layout-loop.md`.
    static func roundsToSettle(_ window: NSWindow, cap: Int = 500) -> Int {
        var rounds = 0
        while rounds < cap, dirtyCount(window.contentView!) > 0 {
            window.layoutIfNeeded()
            rounds += 1
        }
        return rounds
    }
}
