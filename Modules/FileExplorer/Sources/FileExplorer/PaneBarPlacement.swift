import CoreGraphics
import Foundation

/// Shared, reference-type scratch space for deciding whether a pane's floating action bar — and the
/// result message stacked beside it (CA) — docks at the top or bottom of its list. Held by the host (one per pane) and handed to `FileTreeView`,
/// which fills `rowBottoms`/`viewportHeight` from live geometry. Because it's a class, those
/// per-frame writes invalidate no view, so scrolling never re-renders the List. The host reads
/// `resolveAtTop(selection:)` straight from its own `body`, so the bar's edge is known synchronously
/// the instant the selection changes — no post-layout round-trip, no show-then-flip.
public final class PaneBarPlacement {
    public init() {}

    /// Height of the list viewport; the coverage test measures down from this edge.
    var viewportHeight: CGFloat = 0
    /// The viewport's top edge in GLOBAL (window) coordinates. Row positions are captured in global
    /// space too, and the resolve subtracts this to get viewport-relative positions. Global on both
    /// sides on purpose: a named coordinate space cannot be resolved from inside a List row (each
    /// row is hosted in its own AppKit view, outside the space's SwiftUI subtree), so `.named`
    /// silently fell back to global there — inflating every row by the list's offset from the
    /// window top and flipping the bar a quarter-viewport early.
    var viewportGlobalMinY: CGFloat = 0
    /// Every visible row's bottom edge in the window content view's top-down space — what SwiftUI
    /// calls `.global` — keyed by node id. Tracks all rows (not just the selected one) so a
    /// freshly-clicked row's position is already known at click time. Interpreted against
    /// `viewportGlobalMinY`.
    ///
    /// Two writers, one presentation at a time. The tree's rows report through `PaneRowBottomsKey`,
    /// measuring each row's CONTENT; each column's `ColumnListProbe` converts its table's row rects,
    /// which are CELLS — 4pt lower at comfortable spacing, 6pt at compact. So the same row flips the
    /// bar a few points sooner in Columns; the cell is the row as its highlight draws it.
    var rowBottoms: [String: CGFloat] = [:]
    /// The measured footprint of the bottom-docked bar — its padded overlay height, written by the
    /// host from the bar's real geometry. This is the coverage zone: the bar only hides a row whose
    /// bottom edge falls inside it, so the flip triggers exactly when covering would happen, not at
    /// a guessed flat band (the old 72pt band flipped a click several points before any overlap —
    /// the "premature flip on the way down"). Holds a bar-at-rest estimate until first measured.
    /// Public: the HOST measures the bar (it renders it) and writes the value here.
    public var coverage: CGFloat = 64
    /// The measured footprint of the result message, written by the host the same way. It docks in
    /// ONE stack with the bar, so the zone a bottom-docked overlay covers is the sum of the two —
    /// the message never draws over the bar, and the pair flips as one. Holds an estimate of a
    /// one-line message until first measured, so the message's first frame already lands at the
    /// right edge rather than showing at the bottom and then flipping.
    public var messageCoverage: CGFloat = 60
    /// Which of the two the overlay carries — set by the host's resolve, read by every re-resolve.
    private(set) var carriesBar = true
    private(set) var carriesMessage = false
    /// Where the row last acted on sat — the lowest visible row of the last guarded selection that
    /// had one, viewport-relative. **The message's anchor when the selection is gone**: a delete
    /// prunes the deleted rows from the selection before its message arrives, so without this the
    /// message would have no row to stay clear of, and would sit at the foot over the deleted row's
    /// neighbours — the rows the next click is aimed at. Kept fresh by every resolve that can still
    /// see the selection, including the geometry callbacks, so a scroll before the act moves it too.
    private(set) var actedSlot: CGFloat?
    /// The last committed edge — the hysteresis anchor. Written ONLY inside `resolveAtTop`, so
    /// every caller reasons from the same anchor. (The old shape had the host resolving WITHOUT
    /// committing while two other paths committed, so consecutive renders could disagree with the
    /// anchor and the bar flip-flopped.)
    private(set) var atTop = false

    /// The selection the bar is actually acting on: whatever the HOST last resolved against.
    ///
    /// One anchor was not enough, because the two callers fed it different selections. The host
    /// resolves against `barSelectionNodes` — empty for the pane that isn't active, and empty for
    /// the pane that was *just* clicked while the other one still holds a selection, since the
    /// exclusivity clear lands a runloop turn later and `activePane` breaks that tie towards the
    /// left. The pane itself re-resolved against its own raw List selection, which is populated
    /// immediately. So for one turn after every click the two answers differed, and each of them
    /// committed: the pane's geometry callback saw a "flip", wrote host state from inside the
    /// layout pass that produced it, and the host's re-render promptly committed the opposite
    /// answer back. In Columns a single click also opens a column and animates a scroll, so fresh
    /// geometry kept re-arming that exchange — and a layout that never settles is not a cosmetic
    /// problem: AppKit raises once a window needs more constraint passes than it has views, which
    /// is a hard crash.
    ///
    /// So geometry-driven re-resolves go through `reresolveAtTop()`, which reasons from this,
    /// never from a caller's own idea of the selection.
    private(set) var barSelection: Set<String> = []

    /// Extra clearance (beyond leaving the coverage zone) a selected row must gain before the bar
    /// drops back to the bottom — about one comfortable row. The old 28pt dead-zone was thinner
    /// than a row step, so arrowing near the boundary bounced the bar.
    private static let exitHysteresis: CGFloat = 44

    /// Resolves — and commits — which edge the bar belongs on for the given selection: top exactly
    /// when a bottom-docked bar would cover the lowest selected visible row. A short or unscrolled
    /// list keeps the bar at the bottom because its rows hug the top of the viewport; a selection
    /// with no visible row does too (there is nothing on screen to cover). Entering the top edge
    /// happens the moment covering would occur; returning to the bottom additionally requires
    /// `exitHysteresis` of clearance, so a row parked at the boundary can't chatter the bar.
    /// Idempotent for unchanged geometry + selection, so the host may call it on every render.
    ///
    /// This is the HOST's entry point, and it is what defines the bar's selection of record. A pane
    /// re-resolving after a scroll or a new column calls `reresolveAtTop()` instead.
    @discardableResult
    public func resolveAtTop(selection: Set<String>) -> Bool {
        resolveAtTop(guarding: selection, bar: true, message: false)
    }

    /// The same resolve for the whole overlay stack: `selection` is the rows it must stay clear of,
    /// `bar` and `message` say what it carries. With no bar and no message the stack covers nothing
    /// and rests at the bottom — but the call still records where the selection sits, which is how
    /// a message raised after a delete knows the deleted row's slot. With a message and no
    /// selection left, that slot stands in for the selection.
    @discardableResult
    public func resolveAtTop(guarding selection: Set<String>, bar: Bool, message: Bool) -> Bool {
        barSelection = selection
        carriesBar = bar
        carriesMessage = message
        return reresolveAtTop()
    }

    /// Re-resolves after geometry moved, and answers whether that moved the committed edge — the one
    /// question both presentations' geometry callbacks ask: the tree's row preference in
    /// `FileTreeView` and each column's `ColumnListProbe`. One method so the two cannot come to
    /// disagree about what counts as a flip.
    func reresolveMovedEdge() -> Bool {
        let wasAtTop = atTop
        return reresolveAtTop() != wasAtTop
    }

    /// Re-resolves after rows moved and, on a genuine flip, tells the host — on the next turn, never
    /// from inside the geometry callback that found it. The path both presentations' callbacks
    /// take, so neither keeps its own copy of it — and the host's, when the result message it
    /// stacks with the bar measures a new height. Without a host to tell there is nothing to commit
    /// for, so nothing is resolved.
    @MainActor public func flipIfEdgeMoved(_ onFlip: (() -> Void)?) {
        guard let onFlip, reresolveMovedEdge() else { return }
        DispatchQueue.main.async { onFlip() }
    }

    /// Re-resolves the edge for the selection the host last committed, after geometry moved.
    ///
    /// Same maths as `resolveAtTop(selection:)` — it is the same function; only the source of the
    /// selection differs, and that is the whole point.
    @discardableResult
    func reresolveAtTop() -> Bool {
        let selection = barSelection
        let lowestVisible = Self.lowestVisibleBottom(of: selection, rowBottoms: rowBottoms,
                                                     viewportGlobalMinY: viewportGlobalMinY,
                                                     viewportHeight: viewportHeight)
        if let lowestVisible { actedSlot = lowestVisible }
        let zone = (carriesBar ? coverage : 0) + (carriesMessage ? messageCoverage : 0)
        // A pane shorter than the stack is covered end to end whichever edge it takes, so there
        // is no placement that reveals anything — stay at the resting bottom rather than pinning to
        // the top for every row (a negative `coveredFrom` made EVERY row read as covered). An empty
        // stack covers nothing, so it has no reason to leave the bottom either.
        guard zone > 0, viewportHeight > zone else {
            atTop = false
            return false
        }
        // The deleted row's slot, when the act took the selection with it.
        let lowest = lowestVisible ?? (selection.isEmpty && carriesMessage ? actedSlot : nil)
        guard let lowest else {
            atTop = false
            return false
        }
        let coveredFrom = viewportHeight - zone
        atTop = atTop ? lowest > coveredFrom - Self.exitHysteresis : lowest > coveredFrom
        return atTop
    }

    /// The bottom of the lowest selected row that is on screen, viewport-relative, or nil when none is.
    ///
    /// Only rows actually ON SCREEN can be covered. `rowBottoms` also carries rows the List has
    /// laid out past the fold, and a multi-selection can span far beyond it; counting those dragged
    /// the bar to the top on behalf of a row nobody can see — where it then covered the rows that
    /// WERE visible. Clamp to the viewport before taking the lowest.
    ///
    /// Vertically only, and on purpose. A column the stack has scrolled out SIDEWAYS keeps its rows
    /// here: re-reporting every column on every frame of a sideways scroll is the cost
    /// `ColumnListProbe` exists to avoid, and a column that dropped its rows while out of view would
    /// have none when it came back, for the first click there.
    static func lowestVisibleBottom(of selection: Set<String>, rowBottoms: [String: CGFloat],
                                    viewportGlobalMinY: CGFloat, viewportHeight: CGFloat) -> CGFloat? {
        var lowest: CGFloat?
        for id in selection {
            guard let maxY = rowBottoms[id] else { continue }
            // Both sides global; the difference is the row's position within the viewport.
            let inViewport = maxY - viewportGlobalMinY
            guard inViewport <= viewportHeight else { continue }
            lowest = max(lowest ?? inViewport, inViewport)
        }
        return lowest
    }
}
