import CoreGraphics

/// Shared, reference-type scratch space for deciding whether a pane's floating action bar docks at
/// the top or bottom of its list. Held by the host (one per pane) and handed to `FileTreeView`,
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
    /// Every visible row's bottom edge in GLOBAL coordinates, keyed by node id. Tracks all rows
    /// (not just the selected one) so a freshly-clicked row's position is already known at click
    /// time. Interpreted against `viewportGlobalMinY`.
    var rowBottoms: [String: CGFloat] = [:]
    /// The measured footprint of the bottom-docked bar — its padded overlay height, written by the
    /// host from the bar's real geometry. This is the coverage zone: the bar only hides a row whose
    /// bottom edge falls inside it, so the flip triggers exactly when covering would happen, not at
    /// a guessed flat band (the old 72pt band flipped a click several points before any overlap —
    /// the "premature flip on the way down"). Holds a bar-at-rest estimate until first measured.
    /// Public: the HOST measures the bar (it renders it) and writes the value here.
    public var coverage: CGFloat = 64
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
        barSelection = selection
        return reresolveAtTop()
    }

    /// Re-resolves the edge for the selection the host last committed, after geometry moved.
    ///
    /// Same maths as `resolveAtTop(selection:)` — it is the same function; only the source of the
    /// selection differs, and that is the whole point.
    @discardableResult
    func reresolveAtTop() -> Bool {
        let selection = barSelection
        // A pane shorter than the bar is covered end to end whichever edge the bar takes, so there
        // is no placement that reveals anything — stay at the resting bottom rather than pinning to
        // the top for every row (a negative `coveredFrom` made EVERY row read as covered).
        guard viewportHeight > coverage else {
            atTop = false
            return false
        }
        // Only rows actually ON SCREEN can be covered. `rowBottoms` also carries rows the List has
        // laid out past the fold, and a multi-selection can span far beyond it; counting those
        // dragged the bar to the top on behalf of a row nobody can see — where it then covered the
        // rows that WERE visible. Clamp to the viewport before taking the lowest.
        var lowest = -CGFloat.greatestFiniteMagnitude
        for id in selection {
            guard let maxY = rowBottoms[id] else { continue }
            // Both sides global; the difference is the row's position within the viewport.
            let inViewport = maxY - viewportGlobalMinY
            guard inViewport <= viewportHeight else { continue }
            lowest = max(lowest, inViewport)
        }
        guard lowest > -.greatestFiniteMagnitude else {
            atTop = false
            return false
        }
        let coveredFrom = viewportHeight - coverage
        atTop = atTop ? lowest > coveredFrom - Self.exitHysteresis : lowest > coveredFrom
        return atTop
    }
}
